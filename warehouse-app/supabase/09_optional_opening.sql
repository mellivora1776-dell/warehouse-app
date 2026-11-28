-- Optional physical opening evidence and per-instruction daily allocation. No data backfill.
begin;
set local search_path=warehouse_master,pg_catalog;

-- Compare business fields by stable source line ID; join the actual approval and inventory entry separately.
create function warehouse_master.registration_receipt(doc uuid, expected jsonb) returns jsonb
language sql stable set search_path=warehouse_master,pg_catalog,pg_temp as $$
 with actual as materialized (
  select w.line_key as line_id,w.pos,w.raw_name,w.spec as raw_spec,w.read_qty as raw_qty,w.final_qty,
   w.item_id,w.standard_name,w.standard_spec,w.product_kind,w.variant,w.category,w.customer,w.method,w.method_raw,
   w.pick_required,w.pick_qty,w.stock_managed,w.stock_qty,w.decision,
   b.id as batch_id,b.approved_at,e.id as entry_id,e.before_qty,e.after_qty
  from work_rows w left join close_batches b on b.id=w.batch_id
  left join entries e on e.id=w.entry_id and e.item_id=w.item_id and b.id is not null
  where w.document_id=doc
 ), checked as (
  select coalesce(p->>'line_id',a.line_id) line_id,
   case when a.line_id is null then array['missing'] when p is null then array['unexpected']
   else array(select k from unnest(array['raw_name','raw_spec','raw_qty','final_qty','item_id','standard_name','standard_spec',
    'product_kind','variant','category','customer','method','method_raw','pick_required','pick_qty','stock_managed','stock_qty']) k
    where nullif(to_jsonb(a)->>k,'') is distinct from nullif(p->>(case when k='final_qty' then 'raw_qty' else k end),'')) end fields
  from jsonb_array_elements(expected) p full join actual a on a.line_id=p->>'line_id'
 )
 select jsonb_build_object('document_id',d.external_id,'case_id',c.external_key,'work_date',d.work_day,'status',d.status,
  'lines',(select coalesce(jsonb_agg(to_jsonb(a)-'pos' order by pos),'[]') from actual a),
  'differences',(select coalesce(jsonb_agg(to_jsonb(m) order by line_id),'[]') from checked m where cardinality(fields)>0))
 from work_documents d left join work_cases c on c.id=d.case_id where d.id=doc
$$;

create or replace function warehouse_master.preflight(j jsonb,origin_name text) returns jsonb
language plpgsql stable set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare ident jsonb; plans jsonb; reasons text[]:='{}'; duplicate_doc uuid; stored jsonb; line jsonb; p jsonb; collected jsonb:='[]'; stamp text; problem text; effective jsonb; opening integer; current_qty integer; valid_seed boolean;
begin
 j:=j-'preview_stamp';
 if j->>'record_type'='opening_confirmation' and origin_name='chatgpt' then return opening_plan(j);end if;
 ident:=document_identity(j,origin_name);
 if j->>'schema_version'='2' then
  if (j-array['schema_version','document_id','case_id','version','is_revision','replaces','document_type','work_date','source_time','category','customer','method','source','lines','change_type','requester','supersedes_cancelled','preview_stamp'])<>'{}'::jsonb or (j ? 'source' and (jsonb_typeof(j->'source')<>'object' or ((j->'source')-array['kind','text','name','sha256','reply_to','message_id','issuer','note'])<>'{}'::jsonb)) then
   reasons:=array_append(reasons,'지원하지 않는 문서 또는 근거 필드입니다. 입력 명세를 확인하세요.');end if;
  if exists(select from jsonb_array_elements(j->'lines') l where (l-array['line_id','raw_name','sku','spec','qty','confidence','review_reason','item_id','standard_name','standard_spec','match_basis','context','product_kind','variant','stock_managed','pick_required','category','customer','method','remarks','packing','requester','pick_qty','stock_qty','order_confirmed','opening_before','first_warehouse_receipt'])<>'{}'::jsonb or
    (l ? 'pick_required' and jsonb_typeof(l->'pick_required')<>'boolean') or (l ? 'stock_managed' and jsonb_typeof(l->'stock_managed')<>'boolean')) then
   reasons:=array_append(reasons,'지원하지 않는 행 필드 또는 처리 여부 값입니다.');end if;
 end if;
 if coalesce(j->>'change_type','new') not in ('new','additional','revision','cancel') then reasons:=array_append(reasons,'지원하지 않는 변경 유형입니다.');end if;
 if j->>'change_type'='cancel' then reasons:=array_append(reasons,'취소는 관리자가 기존 미승인 문서에서 사유를 확인하고 처리하세요.');end if;
 if j->>'schema_version'='2' and (ident->>'status'='unlinked' or (j->>'change_type'='revision' and nullif(j->>'replaces','') is null)) then
  reasons:=array_append(reasons,'출고 건 및 이전 문서와의 관계를 확인하세요.');end if;
 if exists(select from jsonb_array_elements(j->'lines') x group by x->>'line_id' having count(*)>1) then raise exception 'WM2_LINE';end if;
 for line in select value from jsonb_array_elements(j->'lines') loop
  effective:=line;
  if line->'opening_before'='null' and line->>'order_confirmed' is distinct from 'true' then effective:=line-'opening_before';end if;
  begin
   if line ? 'first_warehouse_receipt' then
    if jsonb_typeof(line->'first_warehouse_receipt')<>'boolean' then raise exception 'WM6_FIRST';end if;
    if (line->>'first_warehouse_receipt')::boolean then
     if coalesce(line->>'category',j->>'category')<>'production_in' or line->>'variant' is distinct from 'order'
      or line->>'order_confirmed' is distinct from 'true' or coalesce(line->>'opening_before','0')<>'0' then raise exception 'WM6_FIRST';end if;
     -- Older receipts materialized a zero for this explicit flag. Reproduce only their original saved plan.
     if (ident->>'duplicate')::boolean and line->>'opening_before' is null and exists (
      select from work_lines l join line_plans a on a.line_id=l.id where l.document_id=(ident->>'id')::uuid
       and l.line_key=line->>'line_id' and a.analysis->>'opening_before'='0') then
      effective:=effective||jsonb_build_object('opening_before',0);
     end if;
    end if;
   end if;
   p:=plan_line(j,effective,origin_name);
  exception when data_exception or raise_exception then
   problem:=case sqlerrm when 'WM5_CONFIRM' then '주문품 종류·모델·전체 사양과 채팅 확인 근거가 필요합니다.'
    when 'WM6_FIRST' then '창고 첫 입고는 처음 들어오는 확정 주문품의 생산입고에만 지정할 수 있습니다.'
    when 'WM2_MANUAL_ONLY' then '반품과 AS는 수기로 등록하세요.' else '원문·수량·사양 또는 행 식별자의 입력 형식을 확인하세요.' end;
   p:=jsonb_build_object('line_id',line->>'line_id','raw_name',line->>'raw_name','standard_name',line->>'standard_name','resolution','conflict','reason',problem);
  end;
  if p->>'order_action'='create' and ident->>'status'<>'current' then
   p:=(p-'order_action'-'opening_before')||jsonb_build_object('item_id',null,'resolution','order_candidate','reason','문서 관계를 먼저 확인하세요.');
  end if;
  if p->>'resolution'='conflict' or (j->>'schema_version'='2' and p->>'resolution'='unlinked' and (nullif(line->>'standard_name','') is not null or nullif(line->>'item_id','') is not null)) then reasons:=array_append(reasons,intake_label(j,line)||' · '||(p->>'reason'));end if;
  if origin_name='chatgpt' and ((not (ident->>'duplicate')::boolean and ident->>'status'='current') or
   ((ident->>'duplicate')::boolean and exists(select from work_lines l join line_plans a on a.line_id=l.id
    where l.document_id=(ident->>'id')::uuid and l.line_key=line->>'line_id' and a.analysis->>'chat_checked'='true'))) then
   p:=p||jsonb_build_object('chat_checked',true);
  end if;
  collected:=collected||jsonb_build_array(p);
 end loop;
 plans:=collected;
 if (ident->>'duplicate')::boolean then
  duplicate_doc:=(ident->>'id')::uuid;stored:=saved_plan(duplicate_doc);
  -- Replay the original creation/link disposition when the actual SKU and confirmed plan still agree.
  select coalesce(jsonb_agg(case when l ? 'order_action' and l->>'item_id'=a->>'item_id' and a ? 'order_action' then
   l||jsonb_build_object('order_action',a->>'order_action') else l end order by n),'[]') into plans
  from jsonb_array_elements(plans) with ordinality curr(l,n)
  left join jsonb_array_elements(stored) a on a->>'line_id'=l->>'line_id';
  if (ident->>'same_input')::boolean then
   select jsonb_agg(case when l-'variant_key'=a-'variant_key' and a ? 'variant_key'
    then l||jsonb_build_object('variant_key',a->'variant_key') else l end order by n) into plans
   from jsonb_array_elements(plans) with ordinality curr(l,n)
   left join jsonb_array_elements(stored) a on a->>'line_id'=l->>'line_id';
  end if;
  if (ident->>'same_input')::boolean or
     (j->>'case_id'=(select suggested_key from work_documents where id=duplicate_doc) and plans=stored) then
   ident:=ident||jsonb_build_object('registration',registration_receipt(duplicate_doc,plans));
  end if;
  ident:=ident||jsonb_build_object('already_closed',exists(select from work_rows where document_id=duplicate_doc and batch_id is not null));
  if j->>'schema_version'='2' and exists(select from work_documents d where d.id=duplicate_doc and d.suggested_key is distinct from nullif(j->>'case_id','') and d.status<>'dismissed') then
   reasons:=array_append(reasons,'동일한 원본이 다른 건으로 등록돼 있습니다. 출고 건을 확인하세요.');end if;
  if j->>'schema_version'='2' and (ident->>'same_input')::boolean is not true and
   (select jsonb_agg(x-'racks' order by ord) from jsonb_array_elements(plans) with ordinality t(x,ord)) is distinct from
   (select jsonb_agg(x-'racks' order by ord) from jsonb_array_elements(stored) with ordinality t(x,ord)) then
   reasons:=array_append(reasons,'중복 원본의 저장 결과가 다릅니다. 기존 문서와 수정본 관계를 확인하세요.');end if;
 end if;
 -- Confirm unresolved business facts in chat, before any new movement document is written.
 if origin_name='chatgpt' and not (ident->>'duplicate')::boolean then
  if ident->>'status'='unlinked' then reasons:=array_append(reasons,'출고 건과 원본 관계를 채팅에서 확인하세요.');end if;
  for p,line in select a.v,b.v from jsonb_array_elements(plans) with ordinality a(v,n)
   join jsonb_array_elements(j->'lines') with ordinality b(v,n) using(n) loop
   problem:='';current_qty:=null;opening:=null;
   if p->>'resolution'='conflict' then continue;end if;
   if ident->>'status'='reconcile' and p->>'resolution'='order_candidate' and line->>'order_confirmed'='true' then continue;end if;
   if p->>'resolution' not in ('matched','pick_only','reference') then problem:='표준 품목과 구별 사양을 채팅에서 확정하세요.';
   elsif p->>'raw_qty' is null or (p->>'pick_required')::boolean and coalesce((p->>'pick_qty')::int,0)<=0
     or (p->>'stock_managed')::boolean and coalesce((p->>'stock_qty')::int,0)<=0 then problem:='제품 수량을 채팅에서 확인하세요.';
   elsif p->>'category'='sale' and (nullif(p->>'customer','') is null or nullif(p->>'method','') is null) then problem:='영업출고 거래처와 출고 방식을 확인하세요.';
   elsif nullif(btrim(p->>'reason'),'') is not null then problem:=p->>'reason';
   elsif p->>'resolution'='matched' and (p->>'stock_managed')::boolean and ident->>'status'='current' then
    select i.qty into current_qty from items i where i.id=(p->>'item_id')::uuid;
    if line->>'first_warehouse_receipt'='true' and (current_qty is not null or exists(select from entries e where e.item_id=(p->>'item_id')::uuid)
     or exists(select from work_rows w where w.item_id=(p->>'item_id')::uuid and w.work_day<(j->>'work_date')::date
      and w.doc_status='current' and w.stock_managed and w.decision<>'exclude')) then
     problem:='이 사양에 이전 창고 거래 또는 재고가 있습니다. 첫 입고 여부를 대조하세요.';
    elsif current_qty is null and p->>'opening_before' is not null then
      select min(amount),min(amount)=max(amount) into opening,valid_seed from (
       select (x->>'opening_before')::int amount from jsonb_array_elements(plans) x where x->>'item_id'=p->>'item_id'
       union all
       select coalesce(f.quantity,(a.analysis->>'opening_before')::int) from work_rows w left join line_plans a on a.line_id=w.id
       left join draft_openings f on f.line_id=w.id and f.item_id=w.item_id and f.work_day=w.work_day
       where w.item_id=(p->>'item_id')::uuid and w.work_day=(j->>'work_date')::date and w.doc_status='current' and w.batch_id is null
       and w.stock_managed and w.decision in ('ready','pending') and w.case_id is distinct from (ident->>'case')::uuid
       and not exists(select from work_documents h where h.suspected_case=w.case_id and h.status='unlinked' and h.deferred)
       union all
       select b.quantity from order_day_balances b where b.item_id=(p->>'item_id')::uuid and b.work_day=(j->>'work_date')::date
       and b.review_id is not null and not exists(select from order_opening_reviews rr join work_lines ll on ll.id=rr.line_id
        join work_documents dd on dd.id=ll.document_id where rr.id=b.review_id and dd.case_id=(ident->>'case')::uuid)
      ) amounts;
      if not valid_seed then problem:='같은 품목의 확인된 보유량이 서로 다릅니다.';end if;
    end if;
   end if;
   if problem<>'' then reasons:=array_append(reasons,intake_label(j,line)||' · '||problem);end if;
  end loop;
 end if;
 -- Concurrent documents may change a proposed creation into reuse of the very same SKU.
 stamp:=fingerprint(jsonb_build_array(j,ident,(select jsonb_agg(x-'order_action' order by n)
 from jsonb_array_elements(plans) with ordinality t(x,n))));
 return ident||jsonb_build_object('stamp',stamp,'can_submit',cardinality(reasons)=0,'blockers',to_jsonb(reasons),'lines',plans,'stored_lines',stored);
end $$;

create or replace view daily_rows as
 select w.*,coalesce(c.display_name,product_label(w.standard_name,w.standard_spec,w.variant='order',w.product_kind)) display_name,
 a.revision is not null and a.record_qty is null record_deleted,coalesce(a.revision,0) record_rev,
 case when a.revision is not null then a.record_qty when w.stock_managed then w.stock_qty else w.final_qty end record_qty,
 case when a.revision is not null then a.customer else w.customer end record_customer,
 case when a.revision is not null then a.method else coalesce(w.method_raw,w.method) end record_method_raw,
 exists(select from work_documents d where d.suspected_case=w.case_id and d.status='unlinked' and d.deferred) related_hold,
 case
 when w.batch_id is not null or w.decision in ('hold','exclude') then ''
 when w.origin='correction' then '과거 수불의 정정 후보입니다. 원거래의 기록을 수정한 뒤 이 후보를 제외하세요.'
 when w.stock_managed and w.item_id is null then case when w.resolution='order_candidate' then '주문 사양에 맞는 SKU를 확인하세요.' else '이 원문에 해당하는 창고 품목을 선택하세요.' end
 when w.final_qty is null or w.pick_required and coalesce(w.pick_qty,0)<=0 or w.stock_managed and coalesce(w.stock_qty,0)<=0
 then coalesce(nullif(w.reason,''),'원본에서 실제로 이동한 수량을 확인하세요.')
 when w.category='sale' and (nullif(w.customer,'') is null or w.method is null) then
  case when nullif(w.customer,'') is null then '영업출고 거래처를 확인하세요.' else '거래처에 전달한 출고 방식을 확인하세요.' end
 when w.stock_managed and w.qty is null and bal.question='자료마다 첫 거래 전 재고 수량이 다릅니다.' then bal.question
 when w.stock_managed and w.item_id is not null and book.qty is null then '기존 품목의 장부 재고가 미확인입니다. 실사하거나 이 거래를 보류하세요.'
 when w.pick_changed and w.decision='pending' and not exists(select from line_plans a where a.line_id=w.id and a.analysis->>'chat_checked'='true') then '이미 준비한 지시의 내용이 달라졌습니다. 변경된 준비 수량을 확인하세요.'
 when w.decision='pending' and exists(select from work_documents prev join work_lines l on l.document_id=prev.id
   where prev.case_id=w.case_id and prev.edition=w.edition-1 and prev.status='previous' and l.line_key=w.line_key and l.decision in ('exclude','hold'))
 then '이전 지시에서 보류·제외했던 행이 변경됐습니다. 새 수량을 확인하세요.'
 when w.decision='pending' and nullif(w.reason,'') is not null then w.reason
 else '' end check_reason,bal.quantity opening_balance,bal.question opening_question,bal.review_id opening_review,
 false awaiting_opening,book.qty book_qty,doc.created_at registered_at
 from work_rows w left join order_day_balances bal on bal.item_id=w.item_id and bal.work_day=w.work_day
 left join catalog_items c on c.id=w.item_id
 join work_documents doc on doc.id=w.document_id
 cross join lateral(select coalesce(w.qty,bal.quantity,
  case when c.made_to_order and not exists(select from entries e where e.item_id=w.item_id) then 0 end) qty) book
 left join lateral(select * from record_amendments where entry_id=w.entry_id or nonstock_line=w.id order by revision desc limit 1) a on true;

-- Only eligible receipts fund shipments. An unaffordable instruction consumes no stock.
-- Within each SKU, process receipts first, then whole outgoing lines in intake order.
create function warehouse_master.close_shortages(lines jsonb) returns jsonb
language plpgsql immutable set search_path=pg_catalog,pg_temp as $$
declare r record; last_item uuid; available bigint; incoming bigint; shortages jsonb:='{}';
begin
 for r in select * from jsonb_to_recordset(lines) as w(id uuid,item_id uuid,book_qty int,
  direction integer,stock_qty integer,stock_managed boolean,decision text,doc_status text,batch_id uuid,
  related_hold boolean,check_reason text,registered_at text,document_id uuid,pos int)
  where doc_status='current' and batch_id is null and decision in ('ready','pending')
   and not related_hold and check_reason='' and stock_managed
  order by item_id,direction desc,registered_at,document_id,pos,id loop
  if r.item_id is distinct from last_item then
   last_item:=r.item_id; available:=r.book_qty; incoming:=0;
  end if;
  if r.direction=1 then
   available:=available+r.stock_qty; incoming:=incoming+r.stock_qty;
  elsif r.stock_qty>available then
   shortages:=shortages||jsonb_build_object(r.id,jsonb_build_object('book',r.book_qty,'incoming',incoming,
    'available',available,'outgoing',r.stock_qty,'short',r.stock_qty-available));
  else available:=available-r.stock_qty;
  end if;
 end loop;
 return shortages;
end $$;

create or replace function warehouse_master.day_view(day_to_read date) returns jsonb language plpgsql stable set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare r jsonb; issues jsonb; batches jsonb; removed jsonb; mark text; shortages jsonb;
begin
 select coalesce(jsonb_agg(to_jsonb(w) order by w.name,w.external_id,w.pos),'[]') into r from daily_rows w
 where w.work_day=day_to_read and (w.doc_status='current' or w.batch_id is not null);
 select coalesce(jsonb_agg(jsonb_build_object('id',d.id,'external_id',d.external_id,'case_id',d.case_id,'suspected_case',d.suspected_case,
  'status',d.status,'issue',d.issue,'deferred',d.deferred,'customer',d.customer,'version',d.version,'work_day',d.work_day)
  order by d.created_at,d.id),'[]') into issues from work_documents d where d.status in ('unlinked','reconcile') and
   (d.work_day=day_to_read or exists(select from work_documents x where x.case_id=d.suspected_case and x.status='current' and x.work_day=day_to_read));
 select coalesce(jsonb_agg(jsonb_build_object('id',b.id,'sequence',b.sequence,'approved_at',b.approved_at,'actor',m.display_name,
  'lines',(select count(*) from posted_lines p where p.batch_id=b.id)) order by b.sequence desc),'[]') into batches
 from close_batches b join members m on m.user_id=b.approver where b.work_day=day_to_read;
 select coalesce(jsonb_agg(jsonb_build_object('doc',n.id,'external_id',n.external_id,'name',old.raw_name,'qty',old.final_qty)
  order by n.id,old.pos),'[]') into removed
 from work_documents n join work_documents prev on prev.case_id=n.case_id and prev.edition=n.edition-1
 join work_lines old on old.document_id=prev.id and old.picked
 where n.status='current' and prev.status<>'dismissed' and n.work_day=day_to_read and not exists(select from work_lines x where x.document_id=n.id and x.line_key=old.line_key);
 shortages:=close_shortages(r);
 mark:=fingerprint(jsonb_build_array(r,issues,shortages));
 return jsonb_build_object('rows',r,'issues',issues,'batches',batches,'removed',removed,'stamp',mark,'shortages',shortages);
end $$;

create or replace function public.wm2_close(p_day date,p_stamp text,p_request uuid) returns jsonb
language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); state jsonb; b close_batches%rowtype; previous close_batches%rowtype;
 row_data jsonb; eligible jsonb; shortage jsonb; r record; item_revision bigint; posted jsonb; tally int:=0;
begin
 perform work_lock();
 if p_day is null or p_stamp is null or p_request is null then raise exception 'WM_INVALID';end if;
 if p_day>seoul_today() then raise exception 'WM6_FUTURE';end if;
 select * into b from close_batches where id=p_request;
 if found then
  if b.work_day<>p_day or b.snapshot<>p_stamp then raise exception 'WM_REQUEST_MISMATCH';end if;
  return jsonb_build_object('id',b.id,'sequence',b.sequence,'duplicate',true);
 end if;
 -- Lock against both another close and a physical count, then re-read the entire approved date.
 perform i.id from items i where i.id in (
  select w.item_id from work_rows w where w.work_day=p_day and w.doc_status='current'
  and w.batch_id is null and w.stock_managed and w.decision in ('pending','ready')) order by i.id for update of i;
 state:=day_view(p_day);
 if state->>'stamp' is distinct from p_stamp then raise exception 'WM_STALE';end if;
 if exists(select from jsonb_array_elements(state->'issues') x where not (x->>'deferred')::boolean) then
  raise exception 'WM2_REVIEW_FIRST';end if;
 select coalesce(jsonb_agg(x order by x->>'item_id',(x->>'direction')::int desc,x->>'registered_at',x->>'document_id',(x->>'pos')::int),'[]')
 into row_data from jsonb_array_elements(state->'rows') x where x->>'doc_status'='current' and x->>'batch_id' is null
 and x->>'decision' in ('pending','ready') and not (x->>'related_hold')::boolean;
 if exists(select from jsonb_array_elements(row_data) x where x->>'check_reason'<>'') then raise exception 'WM2_REVIEW_FIRST';end if;
 select coalesce(jsonb_agg(x order by n),'[]') into eligible from jsonb_array_elements(row_data) with ordinality a(x,n)
 where not ((state->'shortages') ? (x->>'id'));
 if eligible='[]' then
  select value into shortage from jsonb_each(state->'shortages') order by key limit 1;
  if shortage is not null then raise exception 'WM_SHORT' using detail=(shortage||jsonb_build_object('current',shortage->'book'))::text;end if;
  raise exception 'WM2_EMPTY';
 end if;
 select * into previous from close_batches where work_day=p_day order by sequence desc limit 1;
 insert into close_batches(id,work_day,sequence,snapshot,previous_id,approver,reviewed)
 values(p_request,p_day,coalesce(previous.sequence,0)+1,p_stamp,previous.id,auth.uid(),
  jsonb_build_object('rows',state->'rows','issues',state->'issues','shortages',state->'shortages')) returning * into b;
 for r in select x.* from jsonb_array_elements(eligible) with ordinality a(v,n)
  cross join lateral jsonb_to_record(a.v) as x(id uuid, item_id uuid, stock_managed boolean, stock_qty int, direction int,
   qty int,book_qty int,opening_balance int,external_id text,customer text,method text,reason text) order by a.n loop
  if not r.stock_managed then insert into nonstock_closures(line_id,batch_id) values(r.id,b.id);continue;end if;
  -- A new order SKU has an empty ledger. Physical opening stays NULL unless explicitly supplied.
  if r.qty is null then
   if r.book_qty is null then raise exception 'WM_UNKNOWN';end if;
   update items set qty=r.book_qty,opening_qty=coalesce(opening_qty,r.opening_balance) where id=r.item_id and qty is null;
  end if;
  select revision into strict item_revision from items where id=r.item_id;
  posted:=apply_stock_change(r.item_id,case when r.direction=1 then 'in' else 'out' end,r.stock_qty,
   left(concat_ws(' · ',r.external_id,r.customer,r.method,nullif(r.reason,'')),1000),item_revision,r.id);
  insert into posted_lines(line_id,entry_id,batch_id) values(r.id,(posted->>'entry')::bigint,b.id);
  tally:=tally+1;
 end loop;
 return jsonb_build_object('id',b.id,'sequence',b.sequence,'count',tally,'duplicate',false);
end $$;

revoke all on function warehouse_master.registration_receipt(uuid,jsonb), warehouse_master.close_shortages(jsonb)
 from public,anon,authenticated,service_role;
notify pgrst,'reload schema';
commit;
