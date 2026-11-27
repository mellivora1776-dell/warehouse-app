-- Confirmed-only intake, a picking calendar and daily closing by Korean work date.
begin;
set local search_path=warehouse_master,pg_catalog;

create function warehouse_master.seoul_today() returns date language sql stable set search_path='' as $$
 select (statement_timestamp() at time zone 'Asia/Seoul')::date
$$;

-- A chat confirmation is draft evidence attached to an original line. It never updates inventory.
create table draft_openings (
 line_id uuid not null references work_lines, item_id uuid not null references items,
 work_day date not null, quantity integer not null check(quantity>=0),
 basis text not null, actor text not null, fingerprint text not null unique,
 created_at timestamptz not null default clock_timestamp(), primary key(line_id,item_id)
);
alter table draft_openings enable row level security;
revoke all on draft_openings from public,anon,authenticated,service_role;

create or replace view order_day_balances as
 with eligible as (
  select w.id,w.item_id,w.work_day,w.direction,coalesce(f.quantity,(a.analysis->>'opening_before')::integer) stated
  from work_rows w left join line_plans a on a.line_id=w.id
  left join draft_openings f on f.line_id=w.id and f.item_id=w.item_id and f.work_day=w.work_day
  where w.variant='order' and w.item_id is not null and w.qty is null and w.stock_managed and w.doc_status='current'
  and w.batch_id is null and w.decision in ('ready','pending') and not exists(
   select from work_documents d where d.suspected_case=w.case_id and d.status='unlinked' and d.deferred)
 ), per_day as (
  select item_id,work_day,bool_or(direction=1) has_in,bool_or(direction=-1) has_out,min(stated) low,max(stated) high
  from eligible group by item_id,work_day
 ) select p.item_id,p.work_day,coalesce(last.quantity,case when low=high then low end) quantity,last.id review_id,
 case when last.id is null and low<>high then '자료마다 첫 거래 전 재고 수량이 다릅니다.'
 when has_out and not has_in then '출고 직전 보유량' when has_in and not has_out then '입고 직전 보유량'
 else '당일 첫 거래 직전 보유량' end question
 from per_day p left join lateral(select r.id,r.quantity from order_opening_reviews r join eligible e on e.id=r.line_id and e.item_id=r.item_id
  where r.item_id=p.item_id and r.work_day=p.work_day order by r.id desc limit 1) last on true;

create function warehouse_master.opening_plan(j jsonb) returns jsonb language plpgsql stable
set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare w daily_rows%rowtype; prior draft_openings%rowtype; amount integer; why text; row_plan jsonb;
 errors text[]:='{}'; duplicate boolean:=false; fp text:=fingerprint(j);
begin
 if j->>'schema_version' is distinct from '2' or
  (j-array['schema_version','record_type','document_id','line_id','work_date','item_id','opening_before','match_basis'])<>'{}'::jsonb
  or nullif(btrim(j->>'document_id'),'') is null or nullif(btrim(j->>'line_id'),'') is null
  or nullif(btrim(j->>'match_basis'),'') is null or length(j->>'match_basis')>1500
  or jsonb_typeof(j->'opening_before') is distinct from 'number' or j->>'opening_before' !~ '^(0|[1-9][0-9]{0,9})$'
  or (j->>'opening_before')::numeric>2147483647 then raise exception 'WM6_OPEN_FORMAT';end if;
 amount:=(j->>'opening_before')::int;
 select * into w from daily_rows where external_id=j->>'document_id' and line_key=j->>'line_id' and work_day::text=j->>'work_date' and item_id::text=j->>'item_id';
 if not found then why:='문서·행·날짜·연결된 SKU가 기존 거래와 일치하지 않습니다.';
 else
  select * into prior from draft_openings where line_id=w.id and item_id=w.item_id;
  duplicate:=prior.fingerprint is not distinct from fp;
  if not duplicate then
   if w.doc_status<>'current' or w.batch_id is not null or w.variant<>'order' or not w.stock_managed or w.qty is not null
    or w.decision not in ('pending','ready') or w.related_hold then why:='현재 미승인 주문품의 첫 거래만 보완할 수 있습니다.';
   elsif prior.line_id is not null or w.opening_balance is not null and w.opening_balance<>amount
    or exists(select from work_rows other join line_plans p on p.line_id=other.id left join draft_openings f on f.line_id=other.id and f.item_id=other.item_id
      where other.work_day=w.work_day and other.item_id=w.item_id and other.doc_status='current' and other.stock_managed
      and other.decision in ('pending','ready') and other.batch_id is null and coalesce(f.quantity,(p.analysis->>'opening_before')::integer)<>amount
      and not exists(select from work_documents h where h.suspected_case=other.case_id and h.status='unlinked' and h.deferred)) then why:='기존 보유량 확인 기록과 다릅니다. 원거래를 대조하세요.';
   end if;
  end if;
 end if;
 if why is not null then errors:=array_append(errors,concat_ws(' · ',j->>'document_id','행 '||(j->>'line_id'),w.customer,w.display_name,why));end if;
 row_plan:=jsonb_build_object('line_id',j->>'line_id','item_id',w.item_id,'raw_name',w.raw_name,'standard_name',w.display_name,'standard_spec',w.standard_spec,'customer',w.customer,
  'resolution','matched','opening_before',amount,'pick_qty',w.pick_qty,'stock_qty',w.stock_qty,'reason',coalesce(why,''));
 return jsonb_build_object('id',w.document_id,'target_line',w.id,'record_type','opening_confirmation','status',coalesce(w.doc_status,''),
  'duplicate',duplicate,'already_closed',w.batch_id is not null,'stamp',fingerprint(jsonb_build_array(fp,w.rev,w.qty,w.doc_status,w.batch_id,w.opening_balance)),
  'can_submit',cardinality(errors)=0,'blockers',to_jsonb(errors),'lines',jsonb_build_array(row_plan));
end $$;

create function warehouse_master.intake_label(j jsonb,l jsonb) returns text language sql immutable set search_path='' as $$
 select concat_ws(' · ',j->>'document_id','행 '||coalesce(nullif(l->>'line_id',''),'?'),
 nullif(coalesce(l->>'customer',j->>'customer'),''),coalesce(nullif(l->>'standard_name',''),l->>'raw_name'))
$$;

-- Shared document preflight and intake.
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
  begin
   if line ? 'first_warehouse_receipt' then
    if jsonb_typeof(line->'first_warehouse_receipt')<>'boolean' then raise exception 'WM6_FIRST';end if;
    if (line->>'first_warehouse_receipt')::boolean then
     if coalesce(line->>'category',j->>'category')<>'production_in' or line->>'variant' is distinct from 'order'
      or line->>'order_confirmed' is distinct from 'true' or coalesce(line->>'opening_before','0')<>'0' then raise exception 'WM6_FIRST';end if;
     effective:=line||jsonb_build_object('opening_before',0);
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
    elsif current_qty is null then
     if p->>'variant'<>'order' then problem:='기존 품목의 창고 현재고가 미확인입니다.';
     else
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
      if opening is null then problem:=case when p->>'category'='production_in' then '실제 첫 입고이면 첫 입고로 표시하세요. 기존 보유분이 있다면 그 수량을 확인하세요.'
       else '출고 직전 보유량을 채팅에서 확인하세요.' end;
      elsif not valid_seed then problem:='같은 품목의 첫 거래 전 보유량이 서로 다릅니다.';end if;
     end if;
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

create or replace function warehouse_master.intake(j jsonb,origin_name text,actor text,anchor bigint default null,related uuid default null)
returns jsonb language plpgsql set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare stamp text:=j->>'preview_stamp'; plan jsonb; job uuid; doc uuid; new_line uuid; state text; row_plan jsonb; raw jsonb;
 pos int:=0; verify_rows jsonb; fp text; ext text:=btrim(j->>'document_id'); key text:=nullif(btrim(j->>'case_id'),'');
begin
 perform work_lock();j:=j-'preview_stamp';fp:=fingerprint(j);plan:=preflight(j,origin_name);
 if not (plan->>'can_submit')::boolean then raise exception 'WM3_BLOCKED' using detail=(plan->'blockers')::text;end if;
 if plan->>'record_type'='opening_confirmation' then
  row_plan:=plan->'lines'->0;
  if not (plan->>'duplicate')::boolean then
   if stamp is distinct from plan->>'stamp' then raise exception 'WM3_PREFLIGHT_CHANGED';end if;
   insert into draft_openings(line_id,item_id,work_day,quantity,basis,actor,fingerprint)
    values((plan->>'target_line')::uuid,(row_plan->>'item_id')::uuid,(j->>'work_date')::date,(j->>'opening_before')::int,j->>'match_basis',actor,fp);
   perform event((plan->>'id')::uuid,(plan->>'target_line')::uuid,'chat_opening',actor,null,
    jsonb_build_object('item_id',row_plan->'item_id','before_first',j->'opening_before','basis',j->'match_basis'));
  end if;
  verify_rows:=opening_plan(j);
  if not (verify_rows->>'duplicate')::boolean or verify_rows->'lines' is distinct from plan->'lines' then raise exception 'WM3_RECEIPT_MISMATCH';end if;
  return plan||jsonb_build_object('verified',true,'stock_posted',false,'stored_lines',verify_rows->'lines');
 end if;
 if (plan->>'duplicate')::boolean then
  return plan||jsonb_build_object('verified',plan->'stored_lines'=plan->'lines','stock_posted',false);
 end if;
 if j->>'schema_version'='2' and stamp is distinct from plan->>'stamp' then raise exception 'WM3_PREFLIGHT_CHANGED';end if;
 job:=(plan->>'case')::uuid;
 if job is null and plan->>'status'='current' then insert into work_cases(external_key) values(key) returning id into job;end if;
 insert into work_documents(external_id,suggested_key,version,status,issue,work_day,category,direction,customer,method,origin,
 document_type,payload,fingerprint,file_hash,submitted_by,corrects_entry,related_document,suspected_case)
 values(ext,key,(j->>'version')::int,'unlinked',coalesce(plan->>'issue',''),(j->>'work_date')::date,j->>'category',(plan->>'direction')::int,
 btrim(coalesce(j->>'customer','')),shipping_method(j->>'method'),origin_name,btrim(j->>'document_type'),j,fp,lower(nullif(j#>>'{source,sha256}','')),actor,anchor,related,job) returning id into doc;
 for row_plan in select value from jsonb_array_elements(plan->'lines') loop
  raw:=j->'lines'->pos;pos:=pos+1;
  begin
  if row_plan ? 'order_action' then perform ensure_order(row_plan);end if;
  insert into work_lines(document_id,pos,line_key,raw_sku,raw_name,spec,read_qty,final_qty,item_id,customer,method,reason)
  values(doc,pos,row_plan->>'line_id',coalesce(raw->>'sku',''),row_plan->>'raw_name',row_plan->>'raw_spec',(row_plan->>'raw_qty')::int,
   (row_plan->>'raw_qty')::int,(row_plan->>'item_id')::uuid,row_plan->>'customer',row_plan->>'method',coalesce(raw->>'review_reason','')) returning id into new_line;
  insert into line_plans(line_id,analysis,pick_qty,stock_qty) values(new_line,row_plan,(row_plan->>'pick_qty')::int,(row_plan->>'stock_qty')::int);
  if row_plan ? 'order_action' then
   perform event(doc,new_line,'order_link',actor,null,jsonb_build_object('item_id',row_plan->'item_id','identity',row_plan->'variant_key',
    'confirmation',row_plan->'match_basis','action',row_plan->'order_action'));
  end if;
  exception when others then
   raise exception 'WM6_STORE_LINE' using detail=jsonb_build_array(intake_label(j,raw)||' · '||
    case when sqlerrm in ('WM5_IDENTITY','WM3_PREFLIGHT_CHANGED') then '연결할 주문품 정보가 바뀌었습니다. 다시 사전 검증하세요.'
     else '이 행의 품목 연결 또는 저장에 실패해 문서 전체를 되돌렸습니다.' end)::text;
  end;
 end loop;
 state:='unlinked';if plan->>'status'<>'unlinked' then state:=attach_document(doc,job,actor);end if;
 verify_rows:=saved_plan(doc);
 if verify_rows is distinct from plan->'lines' then
  raise exception 'WM3_RECEIPT_MISMATCH' using detail=(select coalesce(jsonb_agg(intake_label(j,x)||' · 저장값이 사전 검증과 달라 등록을 되돌렸습니다.'),'[]')::text
   from jsonb_array_elements(plan->'lines') x where not exists(select from jsonb_array_elements(verify_rows) actual where actual=x));
 elsif state is distinct from plan->>'status' then raise exception 'WM3_RECEIPT_MISMATCH' using detail=jsonb_build_array(ext||' · 문서 버전 상태가 달라 등록을 되돌렸습니다.')::text;end if;
 return jsonb_build_object('id',doc,'status',state,'duplicate',false,'verified',true,'stock_posted',false,'stored_lines',verify_rows);
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
 when w.stock_managed and w.qty is null and w.variant='order' and bal.quantity is null then coalesce(bal.question,'첫 거래 전 재고 수량 확인')
 when w.stock_managed and w.qty is null and w.variant<>'order' then '창고 현재고가 미입력입니다. 실사 수량을 확인하세요.'
 when w.pick_changed and w.decision='pending' and not exists(select from line_plans a where a.line_id=w.id and a.analysis->>'chat_checked'='true') then '이미 준비한 지시의 내용이 달라졌습니다. 변경된 준비 수량을 확인하세요.'
 when w.decision='pending' and exists(select from work_documents prev join work_lines l on l.document_id=prev.id
   where prev.case_id=w.case_id and prev.edition=w.edition-1 and prev.status='previous' and l.line_key=w.line_key and l.decision in ('exclude','hold'))
 then '이전 지시에서 보류·제외했던 행이 변경됐습니다. 새 수량을 확인하세요.'
 when w.decision='pending' and nullif(w.reason,'') is not null then w.reason
 else '' end check_reason,bal.quantity opening_balance,bal.question opening_question,bal.review_id opening_review,
 coalesce(w.variant='order' and w.stock_managed and w.item_id is not null and w.qty is null and bal.quantity is null
  and w.batch_id is null and w.doc_status='current' and w.decision in ('pending','ready'),false) awaiting_opening
 from work_rows w left join order_day_balances bal on bal.item_id=w.item_id and bal.work_day=w.work_day
 left join catalog_items c on c.id=w.item_id
 left join lateral(select * from record_amendments where entry_id=w.entry_id or nonstock_line=w.id order by revision desc limit 1) a on true;

create or replace function public.wm2_close(p_day date,p_stamp text,p_request uuid) returns jsonb
language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); state jsonb; b close_batches%rowtype; last_batch close_batches%rowtype; r record;
 posted jsonb; result_id bigint; tally int:=0; reviews jsonb; item_revision bigint;
begin
 perform work_lock();
 if p_day>seoul_today() then raise exception 'WM6_FUTURE';end if;
 if p_request is null or p_day is null or p_stamp is null then raise exception 'WM_INVALID'; end if;
 select * into b from close_batches where id=p_request;
 if found then
  if b.work_day<>p_day or b.snapshot<>p_stamp then raise exception 'WM_REQUEST_MISMATCH'; end if;
  return jsonb_build_object('id',b.id,'sequence',b.sequence,'duplicate',true);
 end if;
 -- Lock every affected item in UUID order, also against a simultaneous v1 physical count.
 perform i.id from items i where exists(select from daily_rows w where w.work_day=p_day and w.doc_status='current' and
  w.batch_id is null and w.decision in ('ready','pending') and not w.related_hold and not w.awaiting_opening and w.stock_managed and w.item_id=i.id) order by i.id for update of i;
 state:=day_view(p_day);
 if state->>'stamp'<>p_stamp then raise exception 'WM_STALE'; end if;
 if exists(select from jsonb_array_elements(state->'issues') x where not (x->>'deferred')::boolean)
  or exists(select from daily_rows w where w.work_day=p_day and w.doc_status='current' and w.batch_id is null
   and w.decision in ('pending','ready') and not w.related_hold and not w.awaiting_opening and w.check_reason<>'') then raise exception 'WM2_REVIEW_FIRST'; end if;
 for r in select item_id,name,coalesce(qty,opening_balance) qty,sum(direction::bigint*stock_qty) delta from daily_rows
  where work_day=p_day and doc_status='current' and batch_id is null and decision in ('pending','ready') and not related_hold and not awaiting_opening and check_reason='' and stock_managed group by item_id,name,qty,opening_balance loop
  if r.qty is null then raise exception 'WM_UNKNOWN'; end if;
  if r.qty+r.delta<0 then raise exception 'WM_SHORT' using detail=jsonb_build_object('current',r.qty,'short',-(r.qty+r.delta),'name',r.name)::text; end if;
 end loop;
 select * into last_batch from close_batches where work_day=p_day order by sequence desc limit 1;
 reviews:=jsonb_build_object('rows',state->'rows','issues',state->'issues');
 if not exists(select from daily_rows where work_day=p_day and doc_status='current' and batch_id is null and decision in ('pending','ready')
  and not related_hold and not awaiting_opening and check_reason='') then raise exception 'WM2_EMPTY';end if;
 if jsonb_array_length(state->'rows')=0 and jsonb_array_length(state->'issues')=0 then raise exception 'WM2_EMPTY'; end if;
 if not exists(select from daily_rows where work_day=p_day and doc_status='current' and batch_id is null and decision in ('pending','ready') and not related_hold and not awaiting_opening and check_reason='') and
  last_batch.id is not null and not exists(
   select 1 from jsonb_array_elements(state->'rows') x where x->>'batch_id' is null and not exists(
    select from jsonb_array_elements(last_batch.reviewed->'rows') y where y->>'id'=x->>'id' and y->>'rev'=x->>'rev'))
  and state->'issues'=last_batch.reviewed->'issues' then raise exception 'WM2_EMPTY'; end if;
 insert into close_batches(id,work_day,sequence,snapshot,previous_id,approver,reviewed)
  values(p_request,p_day,coalesce(last_batch.sequence,0)+1,p_stamp,last_batch.id,auth.uid(),reviews) returning * into b;
 -- Establish only explicitly confirmed new-order balances in this same transaction.
 for r in select distinct w.item_id,w.opening_balance from daily_rows w
  where w.work_day=p_day and w.doc_status='current' and w.batch_id is null and w.decision in ('pending','ready')
  and not w.related_hold and not w.awaiting_opening and w.check_reason='' and w.stock_managed and w.qty is null and w.opening_balance is not null loop
  update items set qty=r.opening_balance,opening_qty=r.opening_balance,revision=revision+1 where id=r.item_id and qty is null;
 end loop;
 for r in select * from daily_rows where work_day=p_day and doc_status='current' and batch_id is null and decision in ('pending','ready') and not related_hold and not awaiting_opening and check_reason=''
  order by item_id,direction desc,document_id,pos loop
  if not r.stock_managed then
   insert into nonstock_closures(line_id,batch_id) values(r.id,b.id);continue;
  end if;
  select revision into strict item_revision from items where id=r.item_id;
  posted:=apply_stock_change(r.item_id,case when r.direction=1 then 'in' else 'out' end,r.stock_qty,
    left(concat_ws(' · ',r.external_id,r.customer,r.method,nullif(r.reason,'')),1000),item_revision,r.id);
  result_id:=(posted->>'entry')::bigint;
  insert into posted_lines(line_id,entry_id,batch_id) values(r.id,result_id,b.id);tally:=tally+1;
 end loop;
 return jsonb_build_object('id',b.id,'sequence',b.sequence,'count',tally,'duplicate',false);
end $$;

create or replace function public.wm2_open_days() returns jsonb language plpgsql stable security definer
set search_path=warehouse_master,pg_catalog,pg_temp as $$
begin
 perform require_admin();
 return (select coalesce(jsonb_agg(day order by day),'[]') from (
  select work_day as day from work_rows where work_day<=seoul_today() and doc_status='current' and batch_id is null and decision in ('ready','pending','hold')
  union select work_day from work_documents where work_day<=seoul_today() and status in ('unlinked','reconcile')) dates);
end $$;

create function public.wm6_picking(p_day date) returns jsonb language plpgsql stable security definer
set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare rows jsonb; removed jsonb;
begin
 perform member_role();
 if p_day is null then raise exception 'WM_INVALID';end if;
 select coalesce(jsonb_agg(jsonb_build_object(
  'id',w.id,'document_id',w.document_id,'case_id',w.case_id,'work_day',w.work_day,'category',w.category,
  'item_id',w.item_id,'display_name',coalesce(c.display_name,product_label(w.standard_name,w.standard_spec,w.variant='order',w.product_kind)),
  'standard_name',w.standard_name,'standard_spec',w.standard_spec,'variant_key',w.variant_key,'racks',w.racks,
  'pick_qty',w.pick_qty,'pick_required',w.pick_required,'picked',w.picked,'pick_changed',w.pick_changed,'rev',w.rev,
  'stock_managed',w.stock_managed,'resolution',w.resolution,'customer',w.customer,'method',w.method,'method_raw',w.method_raw,
  'packing',w.packing,'remarks',w.remarks,'edition',w.edition) order by w.work_day,w.case_id,w.pos,w.id),'[]') into rows
 from work_rows w left join catalog_items c on c.id=w.item_id
 where w.work_day>=p_day and w.doc_status='current' and w.batch_id is null and w.pick_required and w.decision in ('ready','pending')
 and not exists(select from work_documents h where h.suspected_case=w.case_id and h.status='unlinked' and h.deferred);
 select coalesce(jsonb_agg(jsonb_build_object('work_day',n.work_day,'name',l.raw_name,'qty',l.final_qty) order by n.work_day,n.id,l.pos),'[]') into removed
 from work_documents n join work_documents prev on prev.case_id=n.case_id and prev.edition=n.edition-1 join work_lines l on l.document_id=prev.id
 where n.work_day>=p_day and n.status='current' and prev.status<>'dismissed' and l.picked and
 not exists(select from work_lines x where x.document_id=n.id and x.line_key=l.line_key) and
 exists(select from work_rows active where active.document_id=n.id and active.doc_status='current' and active.batch_id is null and active.decision in ('ready','pending'));
 return jsonb_build_object('rows',rows,'removed',removed);
end $$;
revoke all on function warehouse_master.intake_label(jsonb,jsonb),warehouse_master.opening_plan(jsonb),warehouse_master.seoul_today()
 from public,anon,authenticated,service_role;
revoke all on function public.wm6_picking(date) from public,anon,authenticated,service_role;
grant execute on function public.wm6_picking(date) to authenticated;
notify pgrst,'reload schema';
commit;
