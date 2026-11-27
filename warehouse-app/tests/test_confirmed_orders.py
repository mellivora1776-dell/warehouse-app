"""Customer-confirmed SKUs and opening balances, in an isolated PostgreSQL database."""

import concurrent.futures
import json
import unittest
import uuid

import test_workflow as legacy


class Orders(unittest.TestCase):
    sql = classmethod(legacy.Workflow.sql.__func__)
    call = legacy.Workflow.call
    read = legacy.Workflow.read
    approve = legacy.Workflow.approve

    @classmethod
    def setUpClass(cls):
        legacy.Workflow.setUpClass.__func__(cls)

    def doc(
        self, day, model, spec, n, movement="production_in", kind="finished", **options
    ):
        key = uuid.uuid4().hex
        row = {
            "line_id": "1",
            "raw_name": model,
            "spec": spec,
            "standard_name": model,
            "standard_spec": spec,
            "qty": n,
            "variant": "order",
            "product_kind": kind,
            "order_confirmed": True,
            "match_basis": "사용자가 시험 주문 사양 확인",
            **options,
        }
        return {
            "schema_version": 2,
            "version": 1,
            "document_id": key + "/v1",
            "case_id": key,
            "document_type": "격리 시험",
            "category": movement,
            "work_date": day,
            "customer": "시험 거래처" if movement == "sale" else "",
            "method": "직납" if movement == "sale" else None,
            "lines": [row],
        }

    def preview(self, d):
        return self.call("wm3_preview", d)

    def send(self, d, p=None):
        p = p or self.preview(d)
        self.assertTrue(p["can_submit"], p["blockers"])
        receipt = self.call("wm2_import", {**d, "preview_stamp": p["stamp"]})
        self.assertTrue(receipt["verified"], receipt)
        self.assertFalse(receipt["stock_posted"])
        self.assertEqual(
            [r["item_id"] for r in receipt["stored_lines"]],
            [r["item_id"] for r in p["lines"]],
        )
        return receipt

    def inventory(self):
        return self.sql(
            "set search_path=warehouse_master,pg_catalog; select jsonb_build_array((select count(*) from items),(select count(*) from entries),(select count(*) from work_documents),(select count(*) from work_lines),(select count(*) from work_audit),(select count(*) from order_opening_reviews));"
        )

    def quantity(self, sku):
        return self.call("wm_item", sku)["qty"]

    def test_concurrent_receipt_and_shipment(self):
        day = "2045-04-01"
        incoming = self.doc(
            day, "KJM432-2200", "440/60 · H형 주물 24Φ", 1, opening_before=0
        )
        outgoing = self.doc(day, "KJM432-2200", "440V·60Hz · H형 주물 24Φ", 1, "sale")
        before = self.inventory()
        plans = [self.preview(d) for d in (incoming, outgoing)]
        self.assertEqual(before, self.inventory())
        self.assertEqual(
            [p["lines"][0]["order_action"] for p in plans], ["create", "create"]
        )
        sku = plans[0]["lines"][0]["item_id"]
        self.assertEqual(plans[1]["lines"][0]["item_id"], sku)
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            receipts = list(
                pool.map(
                    lambda args: self.send(*args), zip([incoming, outgoing], plans)
                )
            )
        self.assertEqual(
            {r["stored_lines"][0]["order_action"] for r in receipts},
            {"create", "reuse"},
        )
        self.assertIsNone(self.quantity(sku))
        self.assertEqual(json.loads(self.inventory())[0] - json.loads(before)[0], 1)
        rows = self.read(day)["rows"]
        self.assertEqual(len(rows), 2)
        self.assertEqual({r["opening_balance"] for r in rows}, {0})
        self.assertTrue(all(r["check_reason"] == "" for r in rows))
        self.assertEqual(self.approve(day)["count"], 2)
        self.assertEqual(self.quantity(sku), 0)
        for d in (incoming, outgoing):
            duplicate = self.send(d)
            self.assertTrue(duplicate["duplicate"])
            self.assertTrue(duplicate["already_closed"])
        self.assertEqual(
            [m["signed_qty"] for m in self.call("wm2_log", {"item": sku})["rows"]],
            [-1, 1],
        )

    def test_unknown_outgoing_staged_balance(self):
        day = "2045-04-02"
        d = self.doc(day, "KJ1AB-495", "220/50", 9, "sale")
        receipt = self.send(d)
        sku = receipt["stored_lines"][0]["item_id"]
        stock = lambda: self.quantity(sku)
        state = self.read(day)
        r = state["rows"][0]
        self.assertEqual(r["check_reason"], "출고 전 재고 수량 확인")
        self.assertEqual(
            (r["resolution"], r["pick_qty"], r["stock_qty"]), ("matched", 9, 9)
        )
        self.call("wm2_pick", r["id"], r["rev"], True)
        self.assertIn("WM2_REVIEW_FIRST", self.approve(day, True))
        state = self.read(day)
        self.assertIn(
            "WM_READ_ONLY",
            self.call(
                "wm5_set_opening",
                r["id"],
                state["stamp"],
                12,
                actor=legacy.STAFF,
                fail=True,
            ),
        )
        self.call("wm5_set_opening", r["id"], state["stamp"], 6)
        self.assertIsNone(stock())
        self.assertIn(
            "WM_STALE",
            self.call("wm5_set_opening", r["id"], state["stamp"], 12, fail=True),
        )
        self.assertIn("WM_SHORT", self.approve(day, True))
        self.call("wm5_set_opening", r["id"], self.read(day)["stamp"], 12)
        self.assertIsNone(stock())
        self.assertEqual(self.read(day)["rows"][0]["opening_balance"], 12)
        self.assertEqual(self.call("wm2_log", {"item": sku})["rows"], [])
        state = self.read(day)
        request = str(uuid.uuid4())
        self.assertEqual(
            self.call("wm2_close", day, state["stamp"], request)["count"], 1
        )
        self.assertTrue(
            self.call("wm2_close", day, state["stamp"], request)["duplicate"]
        )
        self.assertEqual(stock(), 3)
        log = self.call("wm2_log", {"item": sku})["rows"]
        self.assertEqual(
            [(m["before_qty"], m["amount"], m["after_qty"]) for m in log], [(12, 9, 3)]
        )

    def test_catalog_boundaries_and_missing_confirmation(self):
        day = "2045-04-03"
        model = "KJB3-3700S"
        dual = self.doc(day, model, "220/380V·50Hz", 1)
        old = self.send(dual)["stored_lines"][0]["item_id"]
        self.assertEqual(
            self.call("wm_item", old)["display_name"], "KJB3-3700S(220/380/50) [주문품]"
        )
        equivalent = self.doc(day, model, "220/380/50", 2)
        plan = self.preview(equivalent)["lines"][0]
        self.assertEqual((plan["order_action"], plan["item_id"]), ("reuse", old))
        for name, spec, kind in [
            (model, "380/50", "finished"),
            (model, "220/380/50", "motor"),
            ("KJB3-3700D", "220/380/50", "finished"),
            (model, "220/380/50 · 고온용", "finished"),
        ]:
            self.assertNotEqual(
                self.preview(self.doc(day, name, spec, 1, kind=kind))["lines"][0][
                    "item_id"
                ],
                old,
            )
        motor = self.doc(day, model, "220/380/50", 2, kind="motor")
        self.assertEqual(
            self.send(motor)["stored_lines"][0]["standard_name"], model + " 모터"
        )
        reuse = self.preview(
            self.doc(day, model + " 모터", "220/380/50", 2, kind="motor")
        )["lines"][0]
        self.assertEqual(reuse["order_action"], "reuse")
        self.assertFalse(
            self.preview(self.doc(day, model, "380/50", 1, item_id=old))["can_submit"]
        )
        self.assertFalse(
            self.preview(self.doc(day, model, "380/50", 1, spec_override="x"))[
                "can_submit"
            ]
        )
        conflicting = self.doc(day, model, "220/380/50", 1)
        conflicting["lines"][0]["spec"] = "380/50"
        self.assertFalse(self.preview(conflicting)["can_submit"])
        unconfirmed = self.doc(day, "판독 후보", "440/60", 1, confidence=1)
        del unconfirmed["lines"][0]["order_confirmed"]
        self.assertEqual(
            self.send(unconfirmed)["stored_lines"][0]["resolution"], "order_candidate"
        )
        for field in ["standard_name", "standard_spec", "match_basis", "product_kind"]:
            bad = self.doc(day, model, "440/60", 1)
            bad["lines"][0].pop(field)
            self.assertIn("WM5_CONFIRM", self.call("wm3_preview", bad, fail=True))

    def test_conflicting_opening_and_cancellation(self):
        day = "2045-04-04"
        args = (day, "별도 모델", "440/60", 1)
        a, b = [self.send(self.doc(*args, opening_before=n)) for n in (0, 4)]
        sku = a["stored_lines"][0]["item_id"]
        rows = self.read(day)["rows"]
        self.assertTrue(all("다릅니다" in r["check_reason"] for r in rows))
        self.assertIn("WM2_REVIEW_FIRST", self.approve(day, True))
        self.call("wm3_cancel", b["id"], "수정 후보 취소")
        self.assertEqual(self.read(day)["rows"][0]["opening_balance"], 0)
        self.assertIsNone(self.quantity(sku))
        self.approve(day)
        self.assertEqual(self.quantity(sku), 1)

    def test_reuses_existing_custom_catalog_and_exact_alias(self):
        day = "2045-04-07"
        original = json.loads(
            self.sql(
                """
            set search_path=warehouse_master,pg_catalog;
            with inserted as (
              insert into items(dataset_id,ordinal,name,racks,opening_qty,qty)
              select d.id,(select max(ordinal) from items i where i.dataset_id=d.id)+k.n,
                     '기존주문-X '||k.suffix,array['외주-1'],11,11
              from datasets d cross join (values (1,'완성품'),(2,'모터')) k(n,suffix)
              where d.active returning id,name
            ), metadata as (
              insert into sku_details(item_id,sku,spec,made_to_order,aliases)
              select id,'기존코드-'||id,'440V·60Hz · H형 주물 24Φ',true,array['기존주문-별칭']
              from inserted returning item_id
            )
            select jsonb_object_agg(name,id) from inserted;
        """
            )
        )
        before = json.loads(self.inventory())
        for kind, suffix in [("finished", "완성품"), ("motor", "모터")]:
            target = original["기존주문-X " + suffix]
            for model in ["기존주문-X", "기존주문-별칭"]:
                d = self.doc(day, model, "440/60 · H형 주물 24Φ", 1, kind=kind)
                plan = self.preview(d)
                self.assertEqual(
                    (plan["lines"][0]["order_action"], plan["lines"][0]["item_id"]),
                    ("reuse", target),
                )
                self.send(d, plan)
            self.assertEqual(self.quantity(target), 11)
            distinct = self.preview(
                self.doc(day, "기존주문-X", "440/60 · V형 주물 24Φ", 1, kind=kind)
            )["lines"][0]
            self.assertEqual(distinct["order_action"], "create")
        self.assertEqual(json.loads(self.inventory())[:2], before[:2])

    def test_revision_after_close_cannot_create_another_sku(self):
        day = "2045-04-08"
        d = self.doc(day, "마감주문-R", "440/60", 2, opening_before=0)
        target = self.send(d)["stored_lines"][0]["item_id"]
        self.approve(day)
        before = json.loads(self.inventory())[:2]
        revised = {
            **d,
            "version": 2,
            "document_id": d["case_id"] + "/v2",
            "change_type": "revision",
            "replaces": d["document_id"],
            "lines": [{**d["lines"][0], "spec": "220/50", "standard_spec": "220/50"}],
        }
        result = self.send(revised)
        self.assertEqual(result["status"], "reconcile")
        self.assertIsNone(result["stored_lines"][0]["item_id"])
        self.assertEqual(json.loads(self.inventory())[:2], before)
        self.assertEqual(self.quantity(target), 2)

    def test_legacy_private_five_row_repair(self):
        day = "2045-04-05"
        definitions = [
            ("LEG-KJ1AB-495", "220/50", 9, "sale"),
            ("LEG-KJM432-2200", "440/60 · H형 주물 24Φ", 1, "sale"),
            ("LEG-KJM432-2200", "440/60 · H형 주물 24Φ", 1, "production_in"),
            ("LEG-CSP-350S", "CSP-350S", 10, "production_in"),
            ("LEG-KJB3-3700S", "220/380/50", 1, "production_in"),
        ]
        docs = []
        for model, spec, n, category in definitions:
            d = self.doc(day, model, spec, n, category)
            del d["lines"][0]["order_confirmed"]
            self.send(d)
            docs.append(d)
        other = self.doc("2045-04-06", *definitions[0])
        del other["lines"][0]["order_confirmed"]
        self.send(other)
        expected = json.loads(
            self.sql(
                "set search_path=warehouse_master,pg_catalog; select jsonb_agg(jsonb_build_object('id',l.id,'document_id',l.document_id,'rev',l.rev,'line_hash',md5((to_jsonb(l)-'item_id'-'rev')::text),'analysis_hash',md5(to_jsonb(p)::text)) order by l.id) from work_lines l join work_documents d on d.id=l.document_id join line_plans p on p.line_id=l.id where d.work_day="
                + legacy.quote(day)
            )
        )

        def repair(rows, fail=False, role=None):
            prefix = "set role " + role + ";" if role else ""
            return self.sql(
                prefix
                + "select warehouse_master.link_confirmed_orders("
                + legacy.quote(day)
                + ","
                + legacy.quote(json.dumps(rows))
                + ",'격리 시험');",
                fail,
            )

        before = self.inventory()
        self.assertIn("permission denied", repair(expected, True, "authenticated"))
        bad = [*expected[:-1], {**expected[-1], "line_hash": "stale"}]
        self.assertIn("WM_STALE", repair(bad, True))
        self.assertEqual(before, self.inventory())
        linked = json.loads(repair(expected))
        self.assertEqual(len({r["item_id"] for r in linked}), 4)
        self.assertEqual(len(linked), 5)
        self.assertTrue(all(self.quantity(r["item_id"]) is None for r in linked))
        after = self.inventory()
        self.assertEqual(json.loads(after)[1:4], json.loads(before)[1:4])
        repair(expected)
        self.assertEqual(after, self.inventory())
        self.assertIsNone(self.read("2045-04-06")["rows"][0]["item_id"])
        for d in docs:
            self.assertTrue(self.send(d)["duplicate"])
        self.assertEqual(self.inventory(), after)


if __name__ == "__main__":
    unittest.main(verbosity=2)
