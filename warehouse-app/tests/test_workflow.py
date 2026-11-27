"""Real PostgreSQL regression tests. Creates and removes its own isolated Docker DB."""

import concurrent.futures
import hashlib
import json
import subprocess
import time
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADMIN = "00000000-0000-4000-8000-000000000001"
STAFF = "00000000-0000-4000-8000-000000000002"


def quote(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, list):
        return "array[" + ",".join(quote(x) for x in value) + "]::text[]"
    if isinstance(value, dict):
        value = json.dumps(value, ensure_ascii=False)
    return "'" + str(value).replace("'", "''") + "'"


class Workflow(unittest.TestCase):
    @classmethod
    def sql(cls, sql, fail=False):
        r = subprocess.run(
            [
                "docker",
                "exec",
                "-i",
                cls.container,
                "psql",
                "-Atq",
                "-U",
                "postgres",
                "-v",
                "ON_ERROR_STOP=1",
            ],
            input=sql,
            text=True,
            capture_output=True,
        )
        if fail:
            if r.returncode == 0:
                raise AssertionError("Expected rejection")
            return r.stderr
        if r.returncode:
            raise AssertionError(r.stderr)
        return r.stdout.strip()

    @classmethod
    def setUpClass(cls):
        cls.container = "wm-v2-test-" + uuid.uuid4().hex[:12]
        subprocess.run(
            [
                "docker",
                "run",
                "--rm",
                "-d",
                "--network",
                "none",
                "--name",
                cls.container,
                "-e",
                "POSTGRES_PASSWORD=" + uuid.uuid4().hex,
                "postgres:16-alpine",
            ],
            check=True,
            capture_output=True,
        )
        cls.addClassCleanup(
            lambda: subprocess.run(
                ["docker", "stop", cls.container], capture_output=True
            )
        )
        for _ in range(60):
            if (
                subprocess.run(
                    [
                        "docker",
                        "exec",
                        cls.container,
                        "pg_isready",
                        "-h",
                        "127.0.0.1",
                        "-U",
                        "postgres",
                    ],
                    capture_output=True,
                ).returncode
                == 0
            ):
                break
            time.sleep(0.25)
        cls.sql(
            """create role anon; create role authenticated; create role service_role bypassrls;
        create schema auth; create function auth.uid() returns uuid language sql stable as
        $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
        create schema storage; create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
        create table storage.objects(bucket_id text,name text,unique(bucket_id,name));"""
        )
        for filename in ["01_schema.sql", "02_import.sql", "03_pin.sql"]:
            cls.sql((ROOT / "supabase" / filename).read_text())
        cls.sql(
            """insert into warehouse_master.datasets(digest,source_file,row_count,verified_at,active)
        values(repeat('0',64),'TEST ONLY',170,now(),true);
        insert into warehouse_master.items(dataset_id,ordinal,name,racks,opening_qty,qty)
        select d.id,n,'QA-'||n,array['R-2','R-11'],40,40 from warehouse_master.datasets d,generate_series(1,170)n;
        insert into warehouse_master.entries(item_id,kind,amount,after_qty,actor_name,source)
        select id,'opening',40,40,'TEST','excel' from warehouse_master.items;"""
        )
        cls.sql(
            f"""insert into warehouse_master.members(user_id,display_name,pin_digest,role) values
        ('{ADMIN}','QA ops',decode('ab','hex'),'admin'),('{STAFF}','QA staff',decode('ba','hex'),'staff');"""
        )
        digest = """select md5(string_agg(to_jsonb(i)::text,'|' order by id)) from warehouse_master.items i;
        select md5(string_agg(to_jsonb(e)::text,'|' order by id)) from warehouse_master.entries e;"""
        before = cls.sql(digest)
        cls.sql((ROOT / "supabase/04_workflow_v2.sql").read_text())
        cls.sql((ROOT / "supabase/05_analysis.sql").read_text())
        cls.sql((ROOT / "supabase/06_records.sql").read_text())
        cls.sql((ROOT / "supabase/07_confirmed_orders.sql").read_text())
        assert before == cls.sql(
            digest
        ), "Migration changed baseline inventory or ledger"
        cls.ids = json.loads(
            cls.sql("select jsonb_object_agg(name,id) from warehouse_master.items")
        )

    def call(self, name, *args, actor=ADMIN, fail=False):
        role = "authenticated" if actor else "anon"
        value = self.sql(
            f"set role {role}; set request.jwt.claim.sub={quote(actor or '')}; select to_jsonb(public.{name}({','.join(quote(a) for a in args)}));",
            fail,
        )
        return value if fail else json.loads(value) if value else None

    def doc(
        self,
        day,
        name="QA-1",
        qty=5,
        key=None,
        cat="sale",
        method="직납",
        version=1,
        **extras,
    ):
        doc = dict(
            schema_version=1,
            document_id=uuid.uuid4().hex,
            case_id=key or uuid.uuid4().hex,
            version=version,
            work_date=day,
            category=cat,
            document_type="시험 문서",
            customer="시험 거래처",
            method=method if cat == "sale" else None,
            lines=[dict(line_id="A", raw_name=name, qty=qty)],
        )
        return {**doc, **extras}

    def read(self, day):
        return self.call("wm2_day", day)

    def review(self, r, state="ready", qty=None, reason="검증", item=None, fail=False):
        return self.call(
            "wm2_review",
            r["id"],
            r["rev"],
            item or r["item_id"],
            qty or r["final_qty"],
            r["method"],
            r["customer"],
            state,
            reason,
            fail=fail,
        )

    def approve(self, day, fail=False):
        return self.call(
            "wm2_close", day, self.read(day)["stamp"], str(uuid.uuid4()), fail=fail
        )

    def qty(self, name):
        return self.call("wm_item", self.ids[name])["qty"]

    def test_versions_files_and_picks(self):
        day = "2031-01-01"
        key = "revision-1"
        name = "QA-1"
        d = self.doc(day, name, 10, key)
        d["source"] = {"sha256": hashlib.sha256(b"image fixture").hexdigest()}
        v1 = self.call("wm2_import", d)
        self.assertTrue(
            self.call("wm2_import", {**d, "document_id": "rescan"})["duplicate"]
        )
        with_file = self.call("wm2_document", v1["id"])
        self.assertFalse(with_file["versions"][0]["has_file"])
        self.sql(
            f"insert into storage.objects values('warehouse-documents-v2',{quote(d['source']['sha256'])});"
        )
        self.assertTrue(self.call("wm2_document", v1["id"])["versions"][0]["has_file"])
        self.assertIn(
            "WM_READ_ONLY", self.call("wm2_file_ref", v1["id"], actor=STAFF, fail=True)
        )
        r = self.read(day)["rows"][0]
        self.call("wm2_pick", r["id"], r["rev"], True)
        v2 = self.call(
            "wm2_import",
            self.doc(day, name, 6, key, version=2, replaces=d["document_id"]),
        )
        rows = self.read(day)["rows"]
        self.assertEqual([r["final_qty"] for r in rows], [6])
        self.assertTrue(rows[0]["pick_changed"])
        self.assertFalse(rows[0]["picked"])
        self.assertEqual(
            [
                v["lines"][0]["read_qty"]
                for v in self.call("wm2_document", v2["id"])["versions"]
            ],
            [10, 6],
        )
        self.assertEqual(self.qty(name), 40)
        self.review(rows[0])
        self.approve(day)
        self.assertEqual(self.qty(name), 34)
        again = self.call("wm2_import", d)
        self.assertTrue(again["duplicate"])
        v3 = self.call("wm2_import", self.doc(day, name, 4, key, version=3))
        self.assertEqual(v3["status"], "reconcile")
        self.assertEqual(self.qty(name), 34)
        self.assertIn("WM2_REVIEW_FIRST", self.approve(day, True))
        original = self.call("wm2_log", {"item": self.ids[name], "category": "sale"})[
            "rows"
        ][0]
        self.call(
            "wm4_amend",
            original["id"],
            None,
            0,
            4,
            "시험 거래처",
            "직납",
            "기록에 실제 출고 4대 표시",
            str(uuid.uuid4()),
        )
        self.call("wm2_resolve", v3["id"], "reconciled", None, "원승인 대조 완료")
        self.assertEqual(self.qty(name), 34)
        self.assertFalse(
            [
                r
                for r in self.call("wm4_pending", self.ids[name])
                if r["work_day"] == day
            ]
        )
        logs = self.call("wm2_log", {"item": self.ids[name], "category": "sale"})[
            "rows"
        ]
        self.assertEqual([(m["amount"], m["record_qty"]) for m in logs], [(6, 4)])

    def test_multiple_transactions_group_and_close(self):
        day = "2031-01-02"
        name = "QA-2"
        for kind, method, n in [
            ("sale", "직납", 5),
            ("sale", "화물", 3),
            ("sale", "방문", 2),
            ("production_out", None, 5),
            ("production_in", None, 10),
        ]:
            self.call("wm2_import", self.doc(day, name, n, cat=kind, method=method))
        rows = self.read(day)["rows"]
        self.assertEqual(len({r["case_id"] for r in rows}), 5)
        self.assertEqual(len({r["item_id"] for r in rows}), 1)
        for r in rows:
            self.review(r, qty=4 if r["method"] == "직납" else r["final_qty"])
        self.assertEqual(self.qty(name), 40)
        stamp = self.read(day)["stamp"]
        key = str(uuid.uuid4())
        with concurrent.futures.ThreadPoolExecutor(2) as ex:
            results = list(
                ex.map(lambda _: self.call("wm2_close", day, stamp, key), range(2))
            )
        self.assertEqual(sorted(x["duplicate"] for x in results), [False, True])
        self.assertEqual(self.qty(name), 36)
        sale = self.call(
            "wm2_log", {"from": day, "to": day, "category": "sale", "customer": "시험"}
        )["rows"]
        self.assertEqual({x["method"] for x in sale}, {"직납", "화물", "방문"})
        self.assertTrue(all(x["signed_qty"] < 0 for x in sale))
        self.assertEqual(
            sum(
                x["signed_qty"]
                for x in self.call(
                    "wm2_log", {"from": day, "to": day, "category": "production_in"}
                )["rows"]
            ),
            10,
        )
        self.assertEqual(
            sum(
                x["signed_qty"]
                for x in self.call(
                    "wm2_log", {"from": day, "to": day, "category": "production_out"}
                )["rows"]
            ),
            -5,
        )

    def test_no_key_and_explicit_decisions(self):
        day = "2031-01-03"
        d = self.doc(day, case_id=None)
        unresolved = self.call("wm2_import", d)
        self.assertEqual(unresolved["status"], "unlinked")
        self.assertFalse(self.read(day)["rows"])
        self.assertIn("WM2_REVIEW_FIRST", self.approve(day, True))
        self.call(
            "wm2_resolve", unresolved["id"], "new", None, "관리자 확인한 별도 출고"
        )
        r = self.read(day)["rows"][0]
        self.assertIn("WM2_REASON", self.review(r, "hold", reason="", fail=True))
        self.review(r, "hold")
        self.approve(day)
        self.assertFalse(self.read(day)["rows"][0]["entry_id"])

    def test_changed_excluded_line_requires_fresh_review(self):
        day = "2031-01-09"
        doc = self.doc(day, "QA-21", 3)
        self.call("wm2_import", doc)
        self.review(self.read(day)["rows"][0], "exclude", reason="원지시 취소")
        same = {**doc, "version": 2, "document_id": uuid.uuid4().hex}
        self.call("wm2_import", same)
        self.assertEqual(self.read(day)["rows"][0]["decision"], "exclude")
        changed = {
            **doc,
            "version": 3,
            "document_id": uuid.uuid4().hex,
            "lines": [{"line_id": "A", "raw_name": "QA-21", "qty": 1}],
        }
        self.call("wm2_import", changed)
        self.assertEqual(self.read(day)["rows"][0]["decision"], "pending")
        self.assertIn("WM2_REVIEW_FIRST", self.approve(day, True))
        self.assertEqual(self.qty("QA-21"), 40)

    def test_order_candidate_and_reorder(self):
        day = "2031-01-04"
        name = "신규 QA 모터"
        d = self.doc(day, name, 10, cat="production_in")
        self.call("wm2_import", d)
        r = self.read(day)["rows"][0]
        self.assertIsNone(r["item_id"])
        self.assertIn(
            "WM2_SKU_EXISTS",
            self.call(
                "wm2_new_sku",
                r["id"],
                r["rev"],
                "QA-1",
                name,
                "440V",
                [],
                True,
                True,
                fail=True,
            ),
        )
        item = self.call(
            "wm2_new_sku",
            r["id"],
            r["rev"],
            "QA-CUSTOM",
            name,
            "440V",
            ["R-9"],
            True,
            True,
        )
        self.assertEqual(self.call("wm_item", item)["qty"], 0)
        self.assertEqual(self.call("wm_items", "")["total"], 170)
        self.review(self.read(day)["rows"][0])
        self.approve(day)
        self.assertEqual(self.call("wm_item", item)["qty"], 10)
        reorder = self.doc(day, name, 10)
        reorder["lines"][0].update(sku="QA-CUSTOM", spec="440V")
        self.call("wm2_import", reorder)
        row = next(r for r in self.read(day)["rows"] if r["entry_id"] is None)
        self.assertEqual(row["item_id"], item)
        self.review(row)
        self.approve(day)
        self.assertEqual(self.call("wm_item", item)["qty"], 0)
        self.assertEqual(self.call("wm_items", "QA-CUSTOM")["total"], 1)

    def test_atomic_errors_stale_and_permissions(self):
        day = "2031-01-05"
        d = self.doc(day, "QA-5", 5)
        d["lines"].append(dict(line_id="B", raw_name="QA-6", qty=43))
        self.call("wm2_import", d)
        for r in self.read(day)["rows"]:
            self.review(r)
        self.assertIn("WM_SHORT", self.approve(day, True))
        self.assertEqual(self.qty("QA-5"), 40)
        rows = self.read(day)["rows"]
        self.review(next(r for r in rows if r["raw_name"] == "QA-6"), qty=3)
        # Inject a failure *after* the first stock movement, in this disposable DB only.
        self.sql(
            """create function public.qa_fail() returns trigger language plpgsql as $$begin
        if exists(select from warehouse_master.posted_lines p where p.batch_id=new.batch_id and p.line_id<>new.line_id) then raise exception 'QA_ROLLBACK';end if;
        return new;end$$;create trigger fail_second after insert on warehouse_master.posted_lines for each row execute function public.qa_fail();"""
        )
        self.assertIn("QA_ROLLBACK", self.approve(day, True))
        self.sql("drop trigger fail_second on warehouse_master.posted_lines;")
        self.assertEqual([self.qty(n) for n in ["QA-5", "QA-6"]], [40, 40])
        self.assertEqual(self.read(day)["batches"], [])
        stamp = self.read(day)["stamp"]
        self.call("wm_change", self.ids["QA-5"], "count", 39, "", 0, str(uuid.uuid4()))
        self.assertIn(
            "WM_STALE", self.call("wm2_close", day, stamp, str(uuid.uuid4()), fail=True)
        )
        self.assertIn(
            "WM2_USE_CLOSE",
            self.call(
                "wm_change",
                self.ids["QA-5"],
                "out",
                1,
                "",
                1,
                str(uuid.uuid4()),
                fail=True,
            ),
        )
        self.assertIn(
            "WM_READ_ONLY",
            self.call(
                "wm2_close", day, stamp, str(uuid.uuid4()), actor=STAFF, fail=True
            ),
        )
        self.assertIn(
            "permission denied", self.call("wm2_day", day, actor=None, fail=True)
        )
        self.approve(day)

    def test_ingest_key_returns_and_as(self):
        day = "2031-01-06"
        token = self.call("wm2_key", "rotate")["token"]
        self.assertEqual(len(token), 64)
        for cat in ["return", "as"]:
            self.assertIn(
                "WM2_MANUAL_ONLY",
                self.call(
                    "wm2_submit", token, self.doc(day, cat=cat), actor=None, fail=True
                ),
            )
        self.assertEqual(
            self.call("wm2_submit", token, self.doc(day, "QA-7", 2), actor=None)[
                "status"
            ],
            "current",
        )
        self.call("wm2_key", "revoke")
        self.assertIn(
            "WM2_TOKEN",
            self.call("wm2_submit", token, self.doc(day), actor=None, fail=True),
        )
        for cat, direction in [("return", "in"), ("as", "out")]:
            self.call(
                "wm2_manual",
                self.ids["QA-7"],
                day,
                cat,
                3,
                str(uuid.uuid4()),
                "",
                None,
                direction,
                "수기",
            )
        for r in self.read(day)["rows"]:
            self.review(r)
        self.assertEqual(self.qty("QA-7"), 40)
        self.approve(day)
        self.assertEqual(self.qty("QA-7"), 38)

    def test_missing_method_exclusion_private_files_and_connector(self):
        import base64

        day = "2031-01-07"
        d = self.doc(day, "QA-17", 2, method=None)
        d["source"] = {"text": "QA private evidence"}
        encoded = base64.b64encode(json.dumps(d).encode()).decode()
        result = json.loads(
            self.sql("select warehouse_master.import_chatgpt(" + quote(encoded) + ");")
        )
        self.assertEqual(result["status"], "current")
        original = result["id"]
        self.assertEqual(self.qty("QA-17"), 40)
        self.assertIn(
            "permission denied",
            self.sql(
                "set role authenticated;select warehouse_master.import_chatgpt("
                + quote(encoded)
                + ");",
                True,
            ),
        )
        self.assertTrue(
            self.call("wm2_import", {**d, "document_id": uuid.uuid4().hex})["duplicate"]
        )
        l = self.read(day)["rows"][0]
        self.assertIn("WM2_INCOMPLETE", self.review(l, fail=True))
        self.call(
            "wm2_review",
            l["id"],
            l["rev"],
            l["item_id"],
            2,
            "방문",
            l["customer"],
            "ready",
            "거래처 확인",
        )
        self.assertIn(
            "WM_READ_ONLY",
            self.call("wm2_pick", l["id"], l["rev"], True, actor=STAFF, fail=True),
        )
        self.assertIsNone(
            self.call("wm2_document", original, actor=STAFF)["versions"][0]["source"]
        )
        self.assertFalse(self.call("wm2_document", original)["versions"][0]["has_file"])
        sha = hashlib.sha256(b"actual test file bytes").hexdigest()
        self.assertIn(
            "WM_NOT_FOUND",
            self.call("wm2_attach_file", original, sha, "qa.pdf", fail=True),
        )
        self.sql(
            "insert into storage.objects values ('warehouse-documents-v2',"
            + quote(sha)
            + ");"
        )
        self.call("wm2_attach_file", original, sha, "qa.pdf")
        self.assertEqual(self.call("wm2_file_ref", original), sha)
        self.assertIn(
            "WM_READ_ONLY", self.call("wm2_file_ref", original, actor=STAFF, fail=True)
        )
        x = self.call("wm2_import", self.doc(day, "QA-17", 35))
        r = next(w for w in self.read(day)["rows"] if w["document_id"] == x["id"])
        self.review(r, "exclude", reason="취소 확인")
        self.approve(day)
        self.assertEqual(self.qty("QA-17"), 38)
        self.assertTrue(
            self.call(
                "wm2_import",
                {**d, "document_id": uuid.uuid4().hex, "source": {"sha256": sha}},
            )["duplicate"]
        )
        self.assertIn(
            "permission denied",
            self.sql(
                "set role authenticated;update warehouse_master.items set qty=0 where false;",
                True,
            ),
        )

    def test_changed_sku_after_approval_and_paid_api_free_intake(self):
        day = "2031-01-08"
        d = self.doc(day, "QA-18", 4)
        v1 = self.call("wm2_import", d)
        self.review(self.read(day)["rows"][0])
        self.approve(day)
        original = self.call(
            "wm2_log", {"item": self.ids["QA-18"], "category": "sale"}
        )["rows"][0]
        v2 = self.call(
            "wm2_import",
            {
                **d,
                "document_id": uuid.uuid4().hex,
                "version": 2,
                "replaces": d["document_id"],
                "lines": [
                    dict(line_id="A", raw_name="QA-18", qty=3),
                    dict(line_id="B", raw_name="QA-19", qty=2),
                ],
            },
        )
        facts = self.call("wm2_document", v2["id"])
        self.assertEqual([m["id"] for m in facts["settled"]], [original["id"]])
        self.assertIn(
            "WM4_RECORD_ONLY",
            self.call(
                "wm2_manual",
                self.ids["QA-19"],
                day,
                "sale",
                2,
                str(uuid.uuid4()),
                "",
                None,
                "out",
                "별도 SKU",
                original["id"],
                v2["id"],
                fail=True,
            ),
        )
        self.call("wm2_resolve", v2["id"], "reconciled", None, "실제 수량은 별도 실사")
        self.assertEqual(self.qty("QA-19"), 40)
        self.assertEqual(len(self.call("wm2_document", v1["id"])["settled"]), 1)

    def test_record_edits_holds_and_stocktakes(self):
        day = "2031-01-10"
        name = "QA-22"
        sku = self.ids[name]
        for key, n, reason in [
            ("ready", 5, ""),
            ("delete", 2, ""),
            ("verify", 3, "최종 출고 수량이 3대인지 5대인지 확인 필요"),
        ]:
            self.call(
                "wm2_import",
                self.doc(
                    day,
                    name,
                    n,
                    key="records-" + key,
                    lines=[
                        dict(line_id="1", raw_name=name, qty=n, review_reason=reason)
                    ],
                ),
            )
        rows = {r["case_key"]: r for r in self.read(day)["rows"]}
        self.review(rows["records-ready"], qty=3)
        self.assertIn("WM2_REVIEW_FIRST", self.approve(day, True))
        for key, decision in [("delete", "exclude"), ("verify", "hold")]:
            r = rows["records-" + key]
            self.call("wm4_dispose", r["id"], r["rev"], decision, "관리자 확인")
        self.assertEqual(
            sorted(r["final_qty"] for r in self.call("wm4_pending", sku)), [3, 3]
        )
        self.assertEqual(self.qty(name), 40)
        self.assertEqual(self.approve(day)["count"], 1)
        self.assertEqual(self.qty(name), 37)
        logs = lambda: self.call("wm2_log", {"from": day, "to": day, "item": sku})[
            "rows"
        ]
        entry = logs()[0]["id"]
        args = [
            entry,
            None,
            0,
            1,
            "변경 거래처",
            "방문",
            "문서에 수량 정정",
            str(uuid.uuid4()),
        ]
        self.assertIn(
            "WM_READ_ONLY", self.call("wm4_amend", *args, actor=STAFF, fail=True)
        )
        self.assertFalse(self.call("wm4_amend", *args)["duplicate"])
        self.assertTrue(self.call("wm4_amend", *args)["duplicate"])
        self.assertEqual(
            (
                logs()[0]["amount"],
                logs()[0]["record_qty"],
                logs()[0]["record_signed_qty"],
            ),
            (3, 1, -1),
        )
        self.assertEqual(
            len(
                self.call(
                    "wm2_log",
                    {
                        "sales": True,
                        "from": day,
                        "to": day,
                        "method": "방문",
                        "customer": "변경",
                    },
                )["rows"]
            ),
            1,
        )
        self.assertIn(
            "WM_STALE", self.call("wm4_amend", *args[:-1], str(uuid.uuid4()), fail=True)
        )
        self.call(
            "wm4_amend",
            entry,
            None,
            1,
            None,
            "",
            "방문",
            "기록 삭제",
            str(uuid.uuid4()),
        )
        self.assertTrue(logs()[0]["record_deleted"])
        self.assertFalse(
            self.call("wm2_log", {"sales": True, "from": day, "to": day})["rows"]
        )
        self.assertEqual(self.qty(name), 37)
        self.assertEqual(len(self.call("wm4_amendments", entry, None, actor=STAFF)), 2)
        held = self.call("wm4_pending", sku)[0]
        self.review(held, qty=2)
        self.assertEqual(self.approve(day)["sequence"], 2)
        self.assertEqual(self.qty(name), 35)
        count = self.call(
            "wm_change",
            sku,
            "count",
            28,
            "직접 센 수량",
            self.call("wm_item", sku)["revision"],
            str(uuid.uuid4()),
        )
        self.call("wm2_import", self.doc(day, name, 1, key="after-count"))
        self.assertEqual(self.approve(day)["count"], 1)
        self.call(
            "wm4_amend",
            count["entry"],
            None,
            0,
            24,
            "",
            None,
            "과거 실사 메모 정정",
            str(uuid.uuid4()),
        )
        self.assertEqual(self.qty(name), 27)
        self.call(
            "wm4_amend",
            count["entry"],
            None,
            1,
            None,
            "",
            None,
            "과거 표시 삭제",
            str(uuid.uuid4()),
        )
        self.assertEqual(self.qty(name), 27)


if __name__ == "__main__":
    unittest.main(verbosity=2)
