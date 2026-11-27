"""Exercise the v2.3 intake, calendar and close against an isolated PostgreSQL instance."""

import concurrent.futures
import datetime
import json
import unittest
import uuid
import test_workflow as old
import test_confirmed_orders as confirmed


class Calendar(unittest.TestCase):
    sql = classmethod(old.Workflow.sql.__func__)
    call, read, approve = old.Workflow.call, old.Workflow.read, old.Workflow.approve
    doc, preview, send, quantity = (
        confirmed.Orders.doc,
        confirmed.Orders.preview,
        confirmed.Orders.send,
        confirmed.Orders.quantity,
    )

    @classmethod
    def setUpClass(cls):
        old.Workflow.setUpClass.__func__(cls)
        api = cls(methodName="test_preserve_existing_draft")
        day = "2021-11-23"
        cls.original = []
        for model, spec, n, kind in [
            ("old-CSP", "220/50", 10, "production_in"),
            ("old-KJM", "440/60 H형 주물 24Φ", 1, "production_in"),
            ("old-KJM", "440/60 H형 주물 24Φ", 1, "sale"),
            ("old-KJB", "220/380/50", 1, "production_in"),
            ("old-495", "220/50", 9, "sale"),
        ]:
            doc = api.doc(day, model, spec, n, kind)
            receipt = api.send(doc)
            cls.original.append((doc, receipt["stored_lines"][0]["item_id"]))
        cls.before = api.stock_snapshot()
        cls.sql((old.ROOT / "supabase/08_confirmed_work.sql").read_text())
        assert api.stock_snapshot() == cls.before

    def stock_snapshot(self):
        return self.sql(
            "set search_path=warehouse_master,pg_catalog;select json_build_array((select md5(string_agg(to_jsonb(i)::text,'|' order by id)) from items i),(select md5(string_agg(to_jsonb(e)::text,'|' order by id)) from entries e),(select md5(string_agg(to_jsonb(l)::text,'|' order by id)) from work_lines l),(select md5(string_agg(to_jsonb(d)::text,'|' order by id)) from work_documents d));"
        )

    def confirmation(self, doc, sku, qty):
        return dict(
            schema_version=2,
            record_type="opening_confirmation",
            document_id=doc["document_id"],
            line_id=doc["lines"][0]["line_id"],
            work_date=doc["work_date"],
            item_id=sku,
            opening_before=qty,
            match_basis="격리 시험에서 사용자가 이전 보유량 확인",
        )

    def test_preserve_existing_draft(self):
        day = "2021-11-23"
        before = self.stock_snapshot()
        day_rows = self.read(day)["rows"]
        self.assertEqual(len(day_rows), 5)
        self.assertEqual(len({r["item_id"] for r in day_rows}), 4)
        self.assertTrue(all(r["awaiting_opening"] for r in day_rows))
        for d, sku in self.original:
            if d["category"] == "production_in":
                c = self.confirmation(d, sku, 0)
                self.assertFalse(self.preview(c)["duplicate"])
                self.send(c)
                self.assertTrue(self.send(c)["duplicate"])
        self.assertEqual(self.stock_snapshot(), before)
        rows = self.read(day)["rows"]
        self.assertEqual([r["final_qty"] for r in rows if r["awaiting_opening"]], [9])
        self.assertEqual(self.approve(day)["count"], 4)
        self.assertIn(day, self.call("wm2_open_days"))
        d, sku = self.original[-1]
        c = self.confirmation(d, sku, 12)
        false_target = {**c, "item_id": self.original[0][1]}
        self.assertFalse(self.preview(false_target)["can_submit"])
        self.assertIn(
            "WM_READ_ONLY", self.call("wm2_import", c, actor=old.STAFF, fail=True)
        )
        self.send(c)
        self.assertIsNone(self.quantity(sku))
        self.assertTrue(self.send(c)["duplicate"])
        self.assertFalse(self.preview({**c, "opening_before": 16})["can_submit"])
        self.assertEqual(self.approve(day)["count"], 1)
        self.assertEqual(self.quantity(sku), 3)
        self.assertTrue(self.send(c)["already_closed"])
        self.assertNotIn(day, self.call("wm2_open_days"))

    def test_first_receipt_and_independent_outgoing(self):
        day = "2021-11-11"
        doc = self.doc(day, "신규-CSP-350S", "CSP", 10, first_warehouse_receipt=True)
        spec = self.preview(doc)
        self.assertTrue(spec["can_submit"], spec["blockers"])
        sku = spec["lines"][0]["item_id"]
        self.assertEqual(
            self.sql(
                "select exists(select from warehouse_master.items where id="
                + old.quote(sku)
                + ");"
            ),
            "f",
        )
        self.send(doc, spec)
        self.assertIsNone(self.quantity(sku))
        self.assertTrue(self.send(doc)["duplicate"])
        self.assertEqual(self.read(day)["rows"][0]["check_reason"], "")
        self.assertEqual(self.approve(day)["count"], 1)
        self.assertEqual(self.quantity(sku), 10)
        self.assertEqual(len(self.call("wm2_log", {"item": sku})["rows"]), 1)
        self.assertTrue(self.send(doc)["already_closed"])
        self.assertFalse(
            self.preview(
                self.doc(day, "신규-CSP-350S", "CSP", 2, first_warehouse_receipt=True)
            )["can_submit"]
        )

    def test_strict_intake_reports_each_line_and_rolls_back(self):
        doc = self.doc("2021-11-12", "X", "440/60", 1)
        doc["lines"] = [
            {**doc["lines"][0], "first_warehouse_receipt": True},
            {"line_id": "B", "raw_name": "어떤 품목", "qty": None, "customer": "별건"},
            {"line_id": "C", "raw_name": "손글씨", "qty": -4, "customer": "둘째"},
        ]
        initial = self.stock_snapshot()
        result = self.preview(doc)
        self.assertFalse(result["can_submit"])
        self.assertIn("행 B", str(result["blockers"]))
        self.assertIn("둘째", str(result["blockers"]))
        self.assertIn(
            "WM3_BLOCKED",
            self.call(
                "wm2_import", {**doc, "preview_stamp": result["stamp"]}, fail=True
            ),
        )
        self.assertEqual(self.stock_snapshot(), initial)
        unknown = self.doc("2021-11-12", "X2", "440/60", 9, "sale")
        self.assertFalse(self.preview(unknown)["can_submit"])
        confirmed = {
            **unknown,
            "lines": [{**unknown["lines"][0], "opening_before": 12}],
        }
        self.send(confirmed)
        self.assertEqual(self.approve(confirmed["work_date"])["count"], 1)

    def test_calendar_time_and_roles(self):
        today = datetime.date.fromisoformat(
            self.sql("select warehouse_master.seoul_today()")
        )
        tomorrow = (today + datetime.timedelta(days=1)).isoformat()
        day = today.isoformat()
        doc = self.doc(tomorrow, "일정", "440/60", 1, "sale", opening_before=3)
        doc["lines"][0]["remarks"] = "오전 9시 방문"
        doc["lines"][0]["customer"] = "삼성전기"
        doc["lines"].append(
            {
                "line_id": "2",
                "raw_name": "KTB-012T 날개",
                "standard_name": "KTB-012T 날개",
                "qty": 1,
                "pick_qty": 1,
                "pick_required": True,
                "stock_managed": False,
                "stock_qty": 0,
                "match_basis": "시험 피킹 전용",
            }
        )
        self.send(doc)

        def picks(d):
            return [
                r
                for r in self.call("wm6_picking", d, actor=old.STAFF)["rows"]
                if r["work_day"] == tomorrow
            ]

        a, b = picks(day), picks(tomorrow)
        self.assertEqual([r["id"] for r in a], [r["id"] for r in b])
        self.assertEqual(len(a), 2)
        wing = next(r for r in a if r["resolution"] == "pick_only")
        self.assertFalse(wing["racks"])
        self.assertEqual(wing["pick_qty"], 1)
        self.assertIn(
            "WM_READ_ONLY",
            self.call(
                "wm2_pick", wing["id"], wing["rev"], True, actor=old.STAFF, fail=True
            ),
        )
        self.call("wm2_pick", wing["id"], wing["rev"], True)
        self.assertTrue(
            next(r for r in picks(tomorrow) if r["id"] == wing["id"])["picked"]
        )
        self.assertNotIn(tomorrow, self.call("wm2_open_days"))
        self.assertIn("WM6_FUTURE", self.approve(tomorrow, True))
        self.assertTrue(
            all(self.quantity(r["item_id"]) is None for r in a if r["item_id"])
        )
        self.assertIn(
            "permission denied", self.call("wm6_picking", day, actor=None, fail=True)
        )

    def test_concurrent_in_and_out_one_sku(self):
        day = "2021-11-19"
        docs = [
            self.doc(day, "동시주문", "440/60", 1, first_warehouse_receipt=True),
            self.doc(day, "동시주문", "440V·60Hz", 1, "sale", opening_before=0),
        ]
        plans = [self.preview(d) for d in docs]
        self.assertEqual(len({p["lines"][0]["item_id"] for p in plans}), 1)
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            received = list(pool.map(lambda args: self.send(*args), zip(docs, plans)))
        self.assertEqual(
            {r["stored_lines"][0]["order_action"] for r in received},
            {"create", "reuse"},
        )
        sku = plans[0]["lines"][0]["item_id"]
        self.assertIsNone(self.quantity(sku))
        self.assertEqual(self.approve(day)["count"], 2)
        self.assertEqual(self.quantity(sku), 0)
        self.assertTrue(all(self.send(d)["duplicate"] for d in docs))

    def test_confirmed_revision_updates_the_pick_without_second_review(self):
        day = "2021-11-20"
        doc = self.doc(day, "피킹수정", "440/60", 4, "sale", opening_before=5)
        self.send(doc)
        row = self.read(day)["rows"][0]
        self.call("wm2_pick", row["id"], row["rev"], True)
        changed = {
            **doc,
            "version": 2,
            "replaces": doc["document_id"],
            "document_id": doc["case_id"] + "/v2",
            "change_type": "revision",
            "lines": [{**doc["lines"][0], "qty": 2}],
        }
        self.send(changed)
        rows = self.read(day)["rows"]
        self.assertEqual(len(rows), 1)
        self.assertTrue(rows[0]["pick_changed"])
        self.assertFalse(rows[0]["picked"])
        self.assertEqual(rows[0]["check_reason"], "")
        self.assertTrue(self.send(changed)["duplicate"])
        self.assertEqual(self.approve(day)["count"], 1)
        self.assertEqual(self.quantity(row["item_id"]), 3)

    def test_lost_update_shortage_and_duplicate_close(self):
        day = "2021-11-14"
        doc = self.doc(day, "마감경합", "440/60", 4, "sale", opening_before=3)
        self.send(doc)
        self.assertIn("WM_SHORT", self.approve(day, True))
        r = self.read(day)["rows"][0]
        self.call(
            "wm3_review",
            r["id"],
            r["rev"],
            r["item_id"],
            2,
            r["method"],
            r["customer"],
            "ready",
            "수량 정정",
            2,
            2,
        )
        state = self.read(day)
        req = str(uuid.uuid4())
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            results = list(
                pool.map(
                    lambda _: self.call("wm2_close", day, state["stamp"], req), range(2)
                )
            )
        self.assertEqual(sorted(r["duplicate"] for r in results), [False, True])
        self.assertEqual(self.quantity(r["item_id"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
