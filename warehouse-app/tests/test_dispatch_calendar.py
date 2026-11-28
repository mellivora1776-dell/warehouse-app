"""Exercise the current intake, calendar and close against an isolated PostgreSQL instance."""

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
        cls.sql((old.ROOT / "supabase/09_optional_opening.sql").read_text())
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
        self.assertFalse(any(r["awaiting_opening"] for r in day_rows))
        self.assertTrue(
            all(
                r["opening_balance"] is None
                and r["book_qty"] == 0
                and not r["check_reason"]
                for r in day_rows
            )
        )
        for d, sku in self.original:
            if d["category"] == "production_in":
                c = self.confirmation(d, sku, 0)
                self.assertFalse(self.preview(c)["duplicate"])
                self.send(c)
                self.assertTrue(self.send(c)["duplicate"])
        self.assertEqual(self.stock_snapshot(), before)
        rows = self.read(day)["rows"]
        self.assertEqual(
            [r["final_qty"] for r in rows if r["id"] in self.read(day)["shortages"]],
            [9],
        )
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
        doc = self.doc(day, "CSP-350S", "CSP", 10)
        doc["customer"] = "에스엔애프"
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
        self.assertEqual(
            self.sql(
                "select opening_qty is null from warehouse_master.items where id="
                + old.quote(sku)
            ),
            "t",
        )
        self.assertEqual(len(self.call("wm2_log", {"item": sku})["rows"]), 1)
        self.assertTrue(self.send(doc)["already_closed"])
        self.assertFalse(
            self.preview(
                self.doc(day, "CSP-350S", "CSP", 2, first_warehouse_receipt=True)
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
        self.assertTrue(self.preview(unknown)["can_submit"])
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
            self.doc(day, "동시주문", "440/60", 1),
            self.doc(day, "동시주문", "440V·60Hz", 1, "sale"),
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

    def test_confirmed_manifest_matches_live_lines_and_approval_receipts(self):
        day = "2021-11-21"
        motor = self.doc(
            day,
            "시험-조립 모터",
            "440/60",
            2,
            "production_out",
            kind="motor",
            opening_before=2,
        )
        inc = self.doc(day, "KJM432-2200", "440/60 H형 주물 24Φ", 1)
        sale = self.doc(day, "KJM432-2200", "440/60 H형 주물 24Φ", 1, "sale")
        sale["customer"] = "우경풍력"
        # This manifest is the confirmed source, independent of the list successfully transmitted.
        manifest = [
            (motor, "production_out", 2, ""),
            (inc, "production_in", 1, ""),
            (sale, "sale", 1, "우경풍력"),
        ]
        for doc in (inc, sale):
            self.send(doc)
        self.assertEqual(
            [d for d, _, _, _ in manifest if not self.preview(d)["duplicate"]], [motor]
        )
        self.send(motor)
        for doc, category, amount, customer in manifest:
            back = self.preview(doc)["registration"]
            self.assertEqual(back["differences"], [])
            [row] = back["lines"]
            self.assertEqual(
                (row["category"], row["final_qty"], row["customer"], row["method"]),
                (category, amount, customer, doc["method"]),
            )
            self.assertIsNone(row["entry_id"])
            self.assertIsNone(row["batch_id"])
        self.assertEqual(len(self.read(day)["rows"]), 3)
        self.assertEqual(self.read(day)["shortages"], {})
        closed = self.approve(day)
        for doc, category, amount, _ in manifest:
            [actual] = self.preview(doc)["registration"]["lines"]
            self.assertIsNotNone(actual["approved_at"])
            self.assertIsNotNone(actual["entry_id"])
            self.assertEqual(actual["batch_id"], closed["id"])
            self.assertEqual(
                actual["after_qty"] - actual["before_qty"],
                amount if category == "production_in" else -amount,
            )
        self.assertEqual(
            self.quantity(self.preview(sale)["registration"]["lines"][0]["item_id"]), 0
        )
        self.assertTrue(self.send(sale)["duplicate"])
        self.assertEqual(len(self.read(day)["batches"]), 1)

    def test_held_incoming_oversize_line_and_independent_close(self):
        day = "2021-11-24"
        big = self.doc(day, "KJ1AB-495", "220/50", 9, "sale", opening_before=None)
        big["customer"] = "대명특수전기"
        self.send(big)
        sku = self.preview(big)["registration"]["lines"][0]["item_id"]
        inc = self.doc(day, "KJ1AB-495", "220/50", 5)
        self.send(inc)
        small = self.doc(day, "KJ1AB-495", "220/50", 4, "sale")
        self.send(small)
        other = self.doc(day, "에스엔-시험", "신형", 10)
        self.send(other)
        data = self.read(day)
        rows = {r["external_id"]: r for r in data["rows"]}
        a, b, c = (rows[d["document_id"]] for d in (big, inc, small))
        self.assertEqual(
            data["shortages"],
            {a["id"]: dict(book=0, incoming=5, available=5, outgoing=9, short=4)},
        )
        self.assertIn(a["id"], [r["id"] for r in self.call("wm6_picking", day)["rows"]])
        self.call("wm2_pick", a["id"], a["rev"], True)
        self.call(
            "wm3_review",
            b["id"],
            b["rev"],
            sku,
            5,
            None,
            "",
            "hold",
            "승인 대상 입고에서 제외",
            0,
            5,
        )
        state = self.read(day)
        self.assertEqual(
            {k: v["short"] for k, v in state["shortages"].items()},
            {a["id"]: 9, c["id"]: 4},
        )
        self.assertTrue(all(v["incoming"] == 0 for v in state["shortages"].values()))
        self.assertIsNone(self.quantity(sku))
        req = str(uuid.uuid4())
        first = self.call("wm2_close", day, state["stamp"], req)
        self.assertEqual(first["count"], 1)
        self.assertTrue(self.call("wm2_close", day, state["stamp"], req)["duplicate"])
        self.assertIsNone(self.quantity(sku))
        self.assertTrue(
            self.preview(big)["registration"]["lines"][0]["entry_id"] is None
        )
        held = next(r for r in self.read(day)["rows"] if r["id"] == b["id"])
        self.call(
            "wm3_review",
            b["id"],
            held["rev"],
            sku,
            5,
            None,
            "",
            "ready",
            "입고 승인 대상",
            0,
            5,
        )
        self.assertEqual(self.approve(day)["count"], 2)
        self.assertEqual(self.quantity(sku), 1)
        self.assertEqual(self.read(day)["shortages"][a["id"]]["short"], 8)
        self.assertIn(day, self.call("wm2_open_days"))
        self.assertEqual(
            self.sql(
                "select count(*) from warehouse_master.entries where item_id="
                + old.quote(sku)
                + " and kind in ('opening','count')"
            ),
            "0",
        )

    def test_unknown_imported_item_accepts_draft_without_inventing_opening(self):
        day = "2021-11-25"
        sku = self.ids["QA-163"]
        self.sql(
            "update warehouse_master.items set qty=null,opening_qty=null where id="
            + old.quote(sku)
        )
        d = self.doc(day, "QA-163", "", 1, "sale")
        d["lines"] = [
            dict(
                line_id="1", item_id=sku, raw_name="QA-163", qty=1, opening_before=None
            )
        ]
        self.send(d)
        [row] = self.read(day)["rows"]
        self.assertIsNone(row["book_qty"])
        self.assertIn("기존 품목", row["check_reason"])
        self.assertEqual(self.read(day)["shortages"], {})
        self.assertIn(
            row["id"], [r["id"] for r in self.call("wm6_picking", day)["rows"]]
        )
        self.assertIsNone(self.quantity(sku))

    def test_reread_reports_edited_line_even_when_row_count_is_the_same(self):
        day = "2021-11-26"
        doc = self.doc(day, "재조회 주문", "440/60", 3, "sale")
        self.send(doc)
        [r] = self.read(day)["rows"]
        self.call(
            "wm3_review",
            r["id"],
            r["rev"],
            r["item_id"],
            2,
            "화물",
            "변경 거래처",
            "ready",
            "원문 정정",
            2,
            2,
        )
        receipt = self.preview(doc)["registration"]
        [change] = receipt["differences"]
        self.assertEqual(change["line_id"], "1")
        self.assertTrue(
            {"final_qty", "pick_qty", "stock_qty", "customer", "method"}
            <= set(change["fields"])
        )
        self.assertIsNone(receipt["lines"][0]["entry_id"])

    def test_partial_close_is_atomic_and_admin_only(self):
        day = "2021-12-01"
        docs = [self.doc(day, "원자성-" + n, "440/60", 1) for n in ("가", "나")]
        skus = [self.send(d)["stored_lines"][0]["item_id"] for d in docs]
        refused = self.call(
            "wm2_close",
            day,
            self.read(day)["stamp"],
            str(uuid.uuid4()),
            actor=old.STAFF,
            fail=True,
        )
        self.assertIn("WM_READ_ONLY", refused)
        self.sql(
            """create function public.qa_fail_close() returns trigger language plpgsql as $$begin
          if exists(select from warehouse_master.posted_lines where batch_id=new.batch_id and line_id<>new.line_id)
           then raise exception 'QA_ROLLBACK';end if;return new;end$$;
          create trigger fail_close after insert on warehouse_master.posted_lines for each row execute function public.qa_fail_close();"""
        )
        try:
            self.assertIn("QA_ROLLBACK", self.approve(day, True))
            self.assertEqual([self.quantity(s) for s in skus], [None, None])
            self.assertEqual(self.read(day)["batches"], [])
            self.assertTrue(
                all(row["entry_id"] is None for row in self.read(day)["rows"])
            )
        finally:
            self.sql("drop trigger fail_close on warehouse_master.posted_lines")
        self.assertEqual(self.approve(day)["count"], 2)

    def test_samsung_visit_is_one_instruction_on_both_dates(self):
        day = "2022-11-24"
        names = ["KJB3-1500S", "32A 휠터"]
        for i, name in enumerate(names):
            self.sql(
                "update warehouse_master.items set name="
                + old.quote(name)
                + " where id="
                + old.quote(self.ids["QA-" + str(158 + i)])
            )
        doc = self.doc(day, names[0], "", 1, "sale")
        doc.update(
            customer="삼성전기", method="방문", source_time="2022-11-23T13:00:00+09:00"
        )
        doc["lines"] = [
            dict(line_id=str(i), raw_name=name, qty=1, remarks="오전 9시 방문")
            for i, name in enumerate(names)
        ]
        result = self.send(doc)
        self.assertTrue(self.send(doc)["duplicate"])

        def picks(as_of):
            return [
                r
                for r in self.call("wm6_picking", as_of)["rows"]
                if r["document_id"] == result["id"]
            ]

        tomorrow, today = picks("2022-11-23"), picks(day)
        self.assertEqual(tomorrow, today)
        self.assertEqual(
            [
                (r["standard_name"], r["work_day"], r["pick_qty"], r["method"])
                for r in today
            ],
            [(n, day, 1, "방문") for n in names],
        )
        self.assertEqual(self.read("2022-11-23")["rows"], [])
        self.assertTrue(all(self.quantity(r["item_id"]) == 40 for r in today))
        self.assertFalse(self.read(day)["batches"])

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
