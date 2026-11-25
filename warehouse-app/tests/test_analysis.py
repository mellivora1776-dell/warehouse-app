"""Analysis contract exercised against PostgreSQL in a disposable, network-isolated database."""

import concurrent.futures
import hashlib
import json
import unittest
import uuid
from pathlib import Path

import test_workflow as legacy

ROOT = Path(__file__).resolve().parents[1]


class Analysis(unittest.TestCase):
    sql = classmethod(legacy.Workflow.sql.__func__)
    call = legacy.Workflow.call
    review = legacy.Workflow.review
    read = legacy.Workflow.read
    approve = legacy.Workflow.approve

    @classmethod
    def setUpClass(cls):
        legacy.Workflow.setUpClass.__func__(cls)
        names = [
            "KJ3AB-750 모터",
            "KJ3AB-750 완성품",
            "KTB-032T",
            "KJB3-2600",
            "KJB3-8600",
            "KJB3-8600D",
            "65A 휠터",
            "50A 휠터",
            "32A 휠터",
            "KTB-022T",
            "KB-750T",
            "KJ3AB-490",
            "KP-300S",
            "KJB3-1500",
            "KJB1-400",
            "KJ1AB-750",
            "KJB1-1100",
            "KJB3-5500",
        ]
        for i, name in enumerate(names, 1):
            cls.sql(
                "update warehouse_master.items set name="
                + legacy.quote(name)
                + ",racks="
                + legacy.quote(["2F-D-11", "2F-D-12"] if i == 1 else ["2F-B-10"])
                + " where ordinal="
                + str(i)
            )
        cls.master = json.loads(
            cls.sql("select jsonb_object_agg(name,id) from warehouse_master.items")
        )

    def doc(self, day, case, lines, cat="sale", **options):
        return dict(
            schema_version=2,
            document_id=case + "/v1",
            case_id=case,
            document_type="출고지시서" if cat == "sale" else "생산 작업",
            category=cat,
            work_date=day,
            version=1,
            lines=lines,
            **options
        )

    def line(self, raw, n, **options):
        return dict(line_id="1", raw_name=raw, qty=n, **options)

    def preview(self, doc):
        return self.call("wm3_preview", doc)

    def submit(self, doc):
        plan = self.preview(doc)
        self.assertTrue(plan["can_submit"], plan["blockers"])
        result = self.call("wm2_import", {**doc, "preview_stamp": plan["stamp"]})
        self.assertTrue(result["verified"], result)
        self.assertEqual(result["stored_lines"], plan["lines"])
        self.assertFalse(result["stock_posted"])
        return result

    def close(self, day):
        for r in self.read(day)["rows"]:
            if not r["batch_id"]:
                self.review(r)
        return self.approve(day)

    def quantity(self, id):
        return self.call("wm_item", id)["qty"]

    def snapshot(self):
        return self.sql(
            "set search_path=warehouse_master,pg_catalog; select jsonb_build_array((select count(*) from items),(select count(*) from work_cases),(select count(*) from work_documents),(select count(*) from work_lines),(select count(*) from entries),(select count(*) from work_audit),(select count(*) from line_plans),(select count(*) from analysis_rules));"
        )

    def test_01_contextual_motor_two_independent_picks(self):
        day = "2041-01-01"
        motor = self.master["KJ3AB-750 모터"]
        docs = [
            self.doc(
                day,
                "instruction-" + str(i),
                [
                    self.line(
                        raw,
                        n,
                        item_id=motor,
                        context="blower_motor",
                        product_kind="motor",
                        requester=person,
                        match_basis="송풍기 조립 지시",
                    )
                ],
                "production_out",
            )
            for i, (raw, n, person) in enumerate(
                [("3-1", 9, "유환열"), ("A3-750-M", 7, "최병호")]
            )
        ]
        before = self.snapshot()
        for doc in docs:
            p = self.preview(doc)["lines"][0]
            self.assertEqual(
                (p["item_id"], p["standard_name"], p["resolution"], p["racks"][0]),
                (motor, "KJ3AB-750 모터", "matched", "2F-D-11"),
            )
        self.assertEqual(before, self.snapshot())
        for doc in docs:
            self.submit(doc)
        rows = self.read(day)["rows"]
        self.assertEqual({r["raw_name"] for r in rows}, {"3-1", "A3-750-M"})
        self.assertEqual({r["pick_qty"] for r in rows}, {9, 7})
        self.assertEqual(sum(r["pick_qty"] for r in rows), 16)
        self.assertEqual(len({r["document_id"] for r in rows}), 2)
        self.call("wm2_pick", rows[0]["id"], rows[0]["rev"], True)
        self.assertEqual(sum(r["picked"] for r in self.read(day)["rows"]), 1)
        unscoped = self.doc(day, "unscoped", [self.line("3-1", 1)], "production_out")
        self.assertEqual(self.preview(unscoped)["lines"][0]["resolution"], "unlinked")

    def test_02_pick_only_and_receipt_reference(self):
        day = "2041-01-02"
        finished = self.master["KTB-032T"]
        starting = self.quantity(finished)
        for raw, n, cat in [
            ("KTB-032T 모터", 3, "sale"),
            ("T3-032T-M", 100, "production_in"),
            ("KTB-032T", 1, "sale"),
        ]:
            opts = dict(customer="송전사", method="화물") if cat == "sale" else {}
            self.submit(
                self.doc(day, "turbo-" + str(n), [self.line(raw, n)], cat, **opts)
            )
        rows = self.read(day)["rows"]
        byname = {r["raw_name"]: r for r in rows}
        outbound = byname["KTB-032T 모터"]
        self.assertEqual(
            (
                outbound["item_id"],
                outbound["resolution"],
                outbound["pick_qty"],
                outbound["stock_qty"],
            ),
            (None, "pick_only", 3, 0),
        )
        self.assertEqual(
            (
                byname["T3-032T-M"]["resolution"],
                byname["T3-032T-M"]["pick_qty"],
                byname["T3-032T-M"]["stock_qty"],
            ),
            ("reference", 0, 0),
        )
        self.assertIn(
            "WM_READ_ONLY",
            self.call(
                "wm2_pick",
                outbound["id"],
                outbound["rev"],
                True,
                actor=legacy.STAFF,
                fail=True,
            ),
        )
        self.call("wm2_pick", outbound["id"], outbound["rev"], True)
        self.assertEqual(self.quantity(finished), starting)
        self.close(day)
        self.assertEqual(self.quantity(finished), starting - 1)
        closed = self.read(day)["rows"]
        self.assertEqual(sum(bool(r["entry_id"]) for r in closed), 1)
        self.assertEqual(sum(bool(r["batch_id"]) for r in closed), 3)
        self.assertTrue(
            next(r for r in closed if r["resolution"] == "pick_only")["picked"]
        )

    def test_03_freight_final_twelve_lines_and_duplicate(self):
        day = "2041-01-03"
        case = "freight-final"
        lines = [
            self.line(
                raw,
                n,
                method="화물",
                customer=("송전사" if i == 7 else "시험 거래처 " + str(i % 5)),
            )
            for i, (raw, n) in enumerate(
                [
                    ("KTB-032T", 1),
                    ("KTB-022T", 1),
                    ("KTB-022T", 1),
                    ("KB-750T", 3),
                    ("KJB3-2600", 1),
                    ("KJ3AB-490", 1),
                    ("KP-300S", 3),
                    ("KTB-032T 모터", 3),
                    ("KJB3-1500", 1),
                    ("KJB1-400", 1),
                    ("KJ1AB-750", 1),
                    ("KJB1-1100", 1),
                ]
            )
        ]
        for i, line in enumerate(lines):
            line["line_id"] = str(i + 1)
        initial = self.doc(day, case, [{**line, "qty": 1} for line in lines])
        self.submit(initial)
        corrected = {
            **initial,
            "document_id": case + "/v2",
            "replaces": initial["document_id"],
            "version": 2,
            "change_type": "revision",
            "lines": lines,
            "source": {"sha256": hashlib.sha256(b"isolated final freight").hexdigest()},
        }
        self.submit(corrected)
        self.assertTrue(self.submit(corrected)["duplicate"])
        self.assertTrue(
            self.submit({**corrected, "document_id": "resized-same-file"})["duplicate"]
        )
        rows = self.read(day)["rows"]
        self.assertEqual(
            (
                len(rows),
                sum(r["pick_qty"] for r in rows),
                sum(r["stock_qty"] for r in rows),
            ),
            (12, 18, 15),
        )
        self.assertEqual(len({r["document_id"] for r in rows}), 1)
        self.close(day)
        result = self.call("wm2_log", {"from": day, "to": day})["rows"]
        self.assertEqual(sum(m["signed_qty"] for m in result), -15)

    def test_04_orders_quick_methods_and_master_reuse(self):
        day = "2041-01-04"
        specs = [
            ("KJ3AB-750 모터", "motor", 25, "태성FAN", "퀵(용차 배송)"),
            ("KJ3AB-750 완성품", "finished", 25, None, None),
            ("KJB3-5500", "finished", 12, "동원모터", "퀵"),
        ]
        items = {}
        for i, (name, kind, n, customer, method) in enumerate(specs):
            raw = "KJ3AB-750 440-60" if i < 2 else "KJB3-5500 440/60"
            line = self.line(
                raw,
                n,
                standard_name=name,
                standard_spec="440V·60Hz",
                product_kind=kind,
                variant="order",
                match_basis="개별 주문 원본과 사용자 확인",
            )
            inbound = self.doc(day, "custom-in-" + str(i), [line], "production_in")
            self.assertEqual(
                self.preview(inbound)["lines"][0]["resolution"], "order_candidate"
            )
            self.submit(inbound)
            if customer:
                out = self.doc(
                    day,
                    "custom-sale-" + str(i),
                    [{**line, "customer": customer, "method": method}],
                )
                self.submit(out)
            r = next(
                r
                for r in self.read(day)["rows"]
                if r["external_id"] == inbound["document_id"]
            )
            self.assertIsNone(r["item_id"])
            item = self.call(
                "wm2_new_sku",
                r["id"],
                r["rev"],
                "QA-CUSTOM-" + str(i),
                name,
                "440V·60Hz",
                [],
                True,
                True,
            )
            items[name] = item
            fresh = self.preview(
                self.doc(day, "reorder-" + str(i), [line], "production_in")
            )["lines"][0]
            self.assertEqual(fresh["item_id"], item)
        rows = self.read(day)["rows"]
        self.assertEqual({r["item_id"] for r in rows}, set(items.values()))
        self.assertEqual(len(items), 3)
        for name, kind, n, customer, method in specs:
            subset = [r for r in rows if r["item_id"] == items[name]]
            self.assertEqual(
                sum(r["direction"] * r["stock_qty"] for r in subset),
                0 if customer else 25,
            )
            self.assertEqual(self.quantity(items[name]), 0)
        self.close(day)
        self.assertEqual([self.quantity(v) for v in items.values()], [0, 25, 0])
        moves = self.call("wm2_log", {"from": day, "to": day, "category": "sale"})[
            "rows"
        ]
        self.assertEqual(
            {(m["customer"], m["method"], m["method_raw"]) for m in moves},
            {("태성FAN", "퀵·용차", "퀵(용차 배송)"), ("동원모터", "퀵", "퀵")},
        )

    def test_05_final_visiting_filters_and_original_text(self):
        day = "2041-01-05"
        ls = [
            self.line("KJB3-8600S", 1),
            self.line("KJB3-2600", 1),
            self.line("65A 휠터", 1),
            self.line(
                "RO-50A",
                2,
                standard_name="50A 휠터",
                item_id=self.master["50A 휠터"],
                match_basis="이번 방문 지시 원본과 확인",
            ),
        ]
        for i, l in enumerate(ls):
            l["line_id"] = str(i)
        old = self.doc(
            day,
            "visiting",
            [{**l, "qty": l["qty"] + 2} for l in ls],
            customer="현대FAN",
            method="방문",
        )
        self.submit(old)
        doc = {
            **old,
            "document_id": "visiting/v2",
            "version": 2,
            "change_type": "revision",
            "replaces": old["document_id"],
            "lines": ls,
        }
        self.submit(doc)
        self.submit(doc)
        rows = self.read(day)["rows"]
        self.assertEqual(
            {r["standard_name"]: r["stock_qty"] for r in rows},
            {"KJB3-8600": 1, "KJB3-2600": 1, "65A 휠터": 1, "50A 휠터": 2},
        )
        self.assertEqual({r["raw_name"] for r in rows}, {l["raw_name"] for l in ls})
        self.assertEqual({r["method"] for r in rows}, {"방문"})
        self.assertEqual(
            self.preview(self.doc(day, "unknown-filter", [self.line("RO-50A", 2)]))[
                "lines"
            ][0]["resolution"],
            "unlinked",
        )
        conflict = self.preview(
            self.doc(
                day,
                "different-type",
                [
                    self.line(
                        "KJB3-8600D",
                        1,
                        item_id=self.master["KJB3-8600"],
                        match_basis="test",
                    )
                ],
            )
        )
        self.assertFalse(conflict["can_submit"])

    def test_06_zero_forecast_and_atomic_close(self):
        day = "2041-01-06"
        item = self.master["KJB3-2600"]
        self.sql(
            "update warehouse_master.items set qty=0 where id=" + legacy.quote(item)
        )
        for i, (cat, n, customer, method) in enumerate(
            [
                ("production_in", 3, "", None),
                ("sale", 1, "대신화물", "화물"),
                ("sale", 1, "현대FAN", "방문"),
            ]
        ):
            self.submit(
                self.doc(
                    day,
                    "forecast-" + str(i),
                    [self.line("KJB3-2600", n)],
                    cat,
                    customer=customer,
                    method=method,
                )
            )
        rows = self.read(day)["rows"]
        self.assertEqual({r["qty"] for r in rows}, {0})
        self.assertEqual(sum(r["stock_qty"] * r["direction"] for r in rows), 1)
        for r in rows:
            self.review(r)
        self.assertEqual(self.quantity(item), 0)
        stamp = self.read(day)["stamp"]
        req = str(uuid.uuid4())
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            completed = list(
                pool.map(lambda _: self.call("wm2_close", day, stamp, req), range(2))
            )
        self.assertEqual(sum(not r["duplicate"] for r in completed), 1)
        self.assertEqual(self.quantity(item), 1)

    def test_07_cancellation_replay_and_posted_reconciliation(self):
        day = "2041-01-07"
        file_hash = hashlib.sha256(b"same QA image").hexdigest()
        doc = self.doc(
            day,
            "resend",
            [self.line("KTB-032T", 2)],
            customer="QA",
            method="방문",
            source={"sha256": file_hash},
        )
        r = self.submit(doc)
        self.submit(doc)
        replace = {
            **doc,
            "document_id": "replacement-v1",
            "case_id": "replacement",
            "supersedes_cancelled": [doc["document_id"]],
        }
        self.assertIn("WM3_CANCEL_FIRST", self.call("wm3_preview", replace, fail=True))
        self.call("wm3_cancel", r["id"], "관리자 검토 후 자료 재접수")
        self.assertEqual(self.read(day)["rows"], [])
        self.assertEqual(self.submit(doc)["status"], "dismissed")
        accidental = self.preview(
            {**doc, "document_id": "without-cancellation-link", "case_id": "unrelated"}
        )
        self.assertTrue(accidental["duplicate"])
        self.assertEqual(accidental["status"], "dismissed")
        self.assertTrue(
            self.preview({**replace, "case_id": doc["case_id"]})["can_submit"]
        )
        self.submit(replace)
        self.assertEqual(len(self.read(day)["rows"]), 1)
        self.close(day)
        balance = self.quantity(self.master["KTB-032T"])
        self.assertTrue(self.submit(replace)["duplicate"])
        revised = {
            **replace,
            "version": 2,
            "document_id": "replacement-v2",
            "replaces": replace["document_id"],
            "change_type": "revision",
            "lines": [self.line("KTB-032T", 1)],
        }
        self.assertEqual(self.submit(revised)["status"], "reconcile")
        self.assertEqual(self.quantity(self.master["KTB-032T"]), balance)
        self.assertEqual(len(self.call("wm2_log", {"from": day, "to": day})["rows"]), 1)
        self.assertTrue(self.read(day)["issues"])

    def test_08_scope_validation_and_credentials(self):
        day = "2041-01-08"
        item = self.master["KJ3AB-750 모터"]
        doc = self.doc(
            day,
            "identity-check",
            [
                self.line(
                    "잘린 원문",
                    2,
                    item_id=item,
                    product_kind="motor",
                    standard_name="KJ3AB-750 모터",
                    match_basis="이번 원본 명판 대조",
                )
            ],
            "production_out",
        )
        self.assertIn("WM3_PREFLIGHT_CHANGED", self.call("wm2_import", doc, fail=True))
        remembered = self.submit(doc)
        row = self.read(day)["rows"][0]
        self.call("wm3_remember_alias", row["id"], "verified_blower")
        future = self.doc(
            day,
            "next",
            [self.line("잘린 원문", 1, context="verified_blower")],
            "production_out",
        )
        self.assertEqual(self.preview(future)["lines"][0]["item_id"], item)
        future["lines"][0]["context"] = "other"
        self.assertEqual(self.preview(future)["lines"][0]["resolution"], "unlinked")
        self.assertIn(
            "WM_READ_ONLY", self.call("wm3_preview", doc, actor=legacy.STAFF, fail=True)
        )
        unlinked = self.submit(future)
        missing = next(
            r for r in self.read(day)["rows"] if r["document_id"] == unlinked["id"]
        )
        self.assertIn(
            "WM2_INCOMPLETE",
            self.call("wm2_pick", missing["id"], missing["rev"], True, fail=True),
        )
        comp = self.doc(
            day,
            "rotation",
            [
                self.line(
                    "KJ3AB-750",
                    1,
                    spec="삼상 1HP 0.75kw 시계방향",
                    item_id=self.master["KJ3AB-750 완성품"],
                    match_basis="사용자 확인 완성품",
                )
            ],
            "production_out",
        )
        self.assertEqual(self.preview(comp)["lines"][0]["resolution"], "matched")
        self.assertFalse(
            self.call("wm2_document", remembered["id"])["versions"][0]["has_file"]
        )
        for change in [
            dict(spec="440/60"),
            dict(product_kind="finished"),
            dict(spec="고온용"),
            dict(spec="특수 도장"),
            dict(spec="축경 22"),
            dict(unsupported_stock_flag=True),
        ]:
            altered = {
                **doc,
                "document_id": str(uuid.uuid4()),
                "case_id": str(uuid.uuid4()),
                "lines": [{**doc["lines"][0], **change}],
            }
            self.assertFalse(self.preview(altered)["can_submit"], change)
        direct = self.doc(
            day,
            "direct",
            [
                self.line("KTB-032T", 1),
                self.line(
                    "KTB-032T",
                    1,
                    remarks="방문 · 개별 포장",
                    customer="행 거래처",
                    packing="개별 포장",
                ),
                self.line("KTB-032T", 1, remarks="퀵(용차 배송)"),
            ],
            customer="기본 거래처",
        )
        for i, l in enumerate(direct["lines"]):
            l["line_id"] = str(i)
        direct["document_type"] = "직납출고지시서"
        p = self.preview(direct)["lines"]
        self.assertEqual(
            [(l["customer"], l["method"]) for l in p],
            [
                ("기본 거래처", "직납"),
                ("행 거래처", "방문"),
                ("기본 거래처", "퀵·용차"),
            ],
        )
        direct["document_type"] = "일반 지시서"
        self.assertIsNone(self.preview(direct)["lines"][0]["method"])

    def test_09_skill_and_site_contract(self):
        guide = (
            (ROOT.parent / ".agents/skills/warehouse-analysis/SKILL.md")
            .read_text()
            .split("---\n", 2)[2]
            .lstrip()
        )
        self.assertEqual(
            guide, (ROOT / "public/warehouse-instructions.txt").read_text()
        )
        contract = json.loads((ROOT / "public/warehouse-action.json").read_text())
        self.assertEqual(set(contract["paths"]), {"/api/preflight", "/api/intake"})
        props = contract["components"]["schemas"]["Document"]["properties"]
        self.assertTrue(
            {
                "item_id",
                "match_basis",
                "pick_qty",
                "stock_qty",
                "product_kind",
                "method",
                "packing",
                "context",
            }.issubset(props["lines"]["items"]["properties"])
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
