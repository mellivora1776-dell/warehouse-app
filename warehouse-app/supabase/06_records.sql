-- Inventory presentation, day approval and append-only amendments to business records.
begin;
set local search_path=warehouse_master,pg_catalog;

create function warehouse_master.product_label(product text, specification text, ordered boolean, kind text default null)
returns text language plpgsql immutable set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare
 base text:=btrim(coalesce(product,'')); extra text:=btrim(coalesce(specification,''));
 electric constant text:='(?<![0-9])([0-9]{3})\s*(?:V\s*)?[/·-]\s*([0-9]{2})\s*(?:Hz)?(?![0-9])|(?<![0-9])([0-9]{3})\s*V\s+([0-9]{2})\s*Hz';
 m text[]; voltage text; hz text; motor boolean; specs text[];
begin
 m:=regexp_match(extra||' '||base,electric,'i');
 voltage:=coalesce(m[1],m[3]); hz:=coalesce(m[2],m[4]);
 base:=regexp_replace(base,'\[\s*주문품\s*\]','','g');
 base:=regexp_replace(base,electric,'','gi');
 base:=btrim(regexp_replace(base,'\(\s*\)','', 'g'));
 motor:=kind='motor' or base ~* '[( ]모터[)]?($|[ (])| 모터$';
 -- A nameplate or a motor accessory is a part in its own right.
 if kind='part' or base ~ '명판' then motor:=false;end if;
 base:=btrim(regexp_replace(base,'\s*[(]?(완성품|완제품)[)]?(?=$|\s)',' ','g'));
 if motor then base:=btrim(regexp_replace(base,'\s*[(]?모터[)]?(?=$|\s)',' ','g'));end if;
 extra:=btrim(regexp_replace(extra,electric,'','gi'),' ()·/,');
 if extra in ('모터','완성품','완제품') or norm(extra)=norm(base) then extra:='';end if;
 if voltage is not null and (voltage<>'380' or hz<>'60') then specs:=array_append(specs,voltage||'/'||hz);end if;
 if extra<>'' and strpos(norm(base),norm(extra))=0 then specs:=array_append(specs,extra);end if;
 return regexp_replace(base,'\s+',' ','g')||case when cardinality(specs)>0 then '('||array_to_string(specs,' · ')||')' else '' end||
  case when motor then ' 모터' else '' end||case when ordered then ' [주문품]' else '' end;
end $$;

create view catalog_items as
 select i.id,i.name,i.qty,i.ordinal,i.revision,i.racks,s.sku,s.spec,coalesce(s.made_to_order,false) made_to_order,
 product_label(i.name,s.spec,coalesce(s.made_to_order,false)) display_name
 from items i join datasets ds on ds.id=i.dataset_id and ds.active left join sku_details s on s.item_id=i.id;

create function public.wm4_catalog(p_query text default '') returns jsonb language plpgsql stable security definer
set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare q text:=norm(coalesce(p_query,''));
begin
 perform member_role();
 -- One snapshot of the matching rows lets all five sorts cover the whole result.
 return (select coalesce(jsonb_agg(to_jsonb(c) order by c.ordinal),'[]') from catalog_items c
 join items i on i.id=c.id left join sku_details s on s.item_id=c.id
 where (q<>'' or not c.made_to_order or c.qty is distinct from 0)
 and (matches(i,q) or strpos(norm(concat_ws(' ',c.display_name,c.sku,c.spec,array_to_string(s.aliases,' '))),q)>0));
end $$;

create or replace function public.wm_item(p_item uuid) returns jsonb language plpgsql stable security definer
set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare result jsonb;
begin
 perform member_role();select to_jsonb(c) into result from catalog_items c where id=p_item;
 if result is null then raise exception 'WM_NOT_FOUND';end if;return result;
end $$;

-- A correction records the administrator's current account of the transaction.
-- Its target is either a journal entry or a closed non-stock instruction.
create table record_amendments(
 id bigint generated always as identity primary key,
 entry_id bigint references entries, nonstock_line uuid references nonstock_closures(line_id),
 revision integer not null check(revision>0), record_qty integer check(record_qty>=0),
 customer text not null, method text, reason text not null,
 actor uuid not null references members(user_id), actor_name text not null,
 request_id uuid not null unique, fingerprint text not null, created_at timestamptz not null default clock_timestamp(),
 check(num_nonnulls(entry_id,nonstock_line)=1),unique(entry_id,revision),unique(nonstock_line,revision)
);
alter table record_amendments enable row level security;
revoke all on record_amendments from public,anon,authenticated;

create function public.wm4_amend(p_entry bigint,p_line uuid,p_rev integer,p_qty integer,p_customer text,p_method text,p_reason text,p_request uuid)
returns jsonb language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare who text:=require_admin(); total record; old record_amendments%rowtype; signature text;
begin
 perform work_lock();
 if num_nonnulls(p_entry,p_line)<>1 or p_request is null or p_rev is null or nullif(trim(p_reason),'') is null or length(p_reason)>1500 then raise exception 'WM_INVALID';end if;
 signature:=fingerprint(jsonb_build_array(p_entry,p_line,p_rev,p_qty,p_customer,p_method,p_reason,auth.uid()));
 select * into old from record_amendments where request_id=p_request;
 if found then
  if old.fingerprint<>signature then raise exception 'WM_REQUEST_MISMATCH';end if;
  return jsonb_build_object('revision',old.revision,'duplicate',true);
 end if;
 if p_entry is not null then
  select kind,category into total from movement_log where id=p_entry and kind<>'opening';
 else
  select 'nonstock' kind,w.category into total from work_rows w join nonstock_closures n on n.line_id=w.id where w.id=p_line;
 end if;
 if not found then raise exception 'WM_NOT_FOUND';end if;
 if p_qty is not null and p_qty < (case when total.kind='count' then 0 else 1 end) then raise exception 'WM_INVALID';end if;
 select * into old from record_amendments where entry_id=p_entry or nonstock_line=p_line order by revision desc limit 1;
 if coalesce(old.revision,0)<>p_rev then raise exception 'WM_STALE';end if;
 if length(p_customer)>250 or (p_qty is not null and total.category='sale' and
  (nullif(trim(p_customer),'') is null or shipping_method(p_method) is null)) then raise exception 'WM2_INCOMPLETE';end if;
 insert into record_amendments(entry_id,nonstock_line,revision,record_qty,customer,method,reason,actor,actor_name,request_id,fingerprint)
 values(p_entry,p_line,p_rev+1,p_qty,case when total.category='sale' then trim(coalesce(p_customer,'')) else '' end,
 case when total.category='sale' then p_method end,trim(p_reason),auth.uid(),who,p_request,signature);
 return jsonb_build_object('revision',p_rev+1,'duplicate',false);
end $$;

create function public.wm4_amendments(p_entry bigint,p_line uuid) returns jsonb language plpgsql stable security definer
set search_path=warehouse_master,pg_catalog,pg_temp as $$
begin
 perform member_role();
 return (select coalesce(jsonb_agg(jsonb_build_object('revision',revision,'qty',record_qty,'reason',reason,'actor',actor_name,
 'at',created_at,'customer',customer,'method',method) order by revision desc),'[]') from record_amendments
 where entry_id=p_entry or nonstock_line=p_line);
end $$;

create view reported_movements as
 select m.*,c.display_name,coalesce(a.revision,0) record_rev,a.revision is not null and a.record_qty is null record_deleted,
 case when a.revision is not null then a.record_qty when m.kind in ('count','opening') then m.after_qty else m.amount end record_qty,
 case when a.revision is null then m.signed_qty when m.kind='count' then a.record_qty-m.before_qty
 when m.kind='out' then -a.record_qty else a.record_qty end record_signed_qty,
 case when a.revision is not null then a.customer else m.customer end record_customer,
 case when a.revision is not null then shipping_method(a.method) else m.method end record_method,
 case when a.revision is not null then a.method else coalesce(m.method_raw,m.method) end record_method_raw
 from movement_log m join catalog_items c on c.id=m.item_id
 left join lateral(select * from record_amendments where entry_id=m.id order by revision desc limit 1) a on true;

create view daily_rows as
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
 when w.stock_managed and w.qty is null then '창고 현재고가 미입력입니다. 실사 수량을 확인하세요.'
 when w.pick_changed and w.decision='pending' then '이미 준비한 지시의 내용이 달라졌습니다. 변경된 준비 수량을 확인하세요.'
 when w.decision='pending' and exists(select from work_documents prev join work_lines l on l.document_id=prev.id
   where prev.case_id=w.case_id and prev.edition=w.edition-1 and prev.status='previous' and l.line_key=w.line_key and l.decision in ('exclude','hold'))
 then '이전 지시에서 보류·제외했던 행이 변경됐습니다. 새 수량을 확인하세요.'
 when w.decision='pending' and nullif(w.reason,'') is not null then w.reason
 else '' end check_reason
 from work_rows w left join catalog_items c on c.id=w.item_id
 left join lateral(select * from record_amendments where entry_id=w.entry_id or nonstock_line=w.id order by revision desc limit 1) a on true;

create function public.wm4_pending(p_item uuid) returns jsonb language plpgsql stable security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
begin
 perform member_role();return (select coalesce(jsonb_agg(to_jsonb(w) order by work_day desc,external_id,pos),'[]') from daily_rows w
 where w.item_id=p_item and w.doc_status='current' and w.batch_id is null and w.decision<>'exclude');
end $$;

-- Day approval and reporting RPCs.
create or replace function warehouse_master.document_identity(j jsonb,origin_name text) returns jsonb
language plpgsql stable set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare ext text:=nullif(btrim(j->>'document_id'),''); key text:=nullif(btrim(j->>'case_id'),'');
 v int; day date; cat text:=j->>'category'; mode text:=nullif(j->>'method',''); sign smallint;
 customer text:=btrim(coalesce(j->>'customer','')); file_sha text:=lower(nullif(j#>>'{source,sha256}',''));
 fp text; same work_documents%rowtype; prior work_documents%rowtype; job uuid; doc uuid; issue_text text:='';
 n integer;
 previous_ext text:=nullif(j->>'replaces',''); kind text:=nullif(btrim(j->>'document_type'),''); result_status text;
begin
 if j ? 'supersedes_cancelled' and (jsonb_typeof(j->'supersedes_cancelled')<>'array' or exists(
   select from jsonb_array_elements_text(j->'supersedes_cancelled') x where not exists(
    select from work_documents d where d.external_id=x and d.status='dismissed'))) then raise exception 'WM3_CANCEL_FIRST';end if;
 if jsonb_typeof(j) is distinct from 'object' or coalesce(j->>'schema_version','') not in ('1','2') or
   jsonb_typeof(j->'lines') is distinct from 'array' or length(j::text)>250000 or ext is null or length(ext)>160
   or length(key)>200 or kind is null or length(kind)>120 or length(customer)>250 then raise exception 'WM2_FORMAT'; end if;
 n:=jsonb_array_length(j->'lines');
 if n not between 1 and 200 or coalesce(j->>'version','') !~ '^[1-9][0-9]{0,5}$' or
    coalesce(j->>'work_date','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or cat is null or
    cat not in ('sale','production_out','production_in','return','as') then raise exception 'WM2_FORMAT'; end if;
 v:=(j->>'version')::int; day:=(j->>'work_date')::date;
 if nullif(j->>'source_time','') is not null then perform (j->>'source_time')::timestamptz; end if;
 if origin_name='chatgpt' and cat in ('return','as') then raise exception 'WM2_MANUAL_ONLY'; end if;
 if mode is not null and (cat<>'sale' or shipping_method(mode) is null) then raise exception 'WM2_METHOD'; end if;
 if file_sha is not null and file_sha !~ '^[0-9a-f]{64}$' then raise exception 'WM2_FORMAT'; end if;
 sign:=case when origin_name='correction' or cat='as' then
   case j->>'direction' when 'in' then 1 when 'out' then -1 else null end
   when cat in ('production_in','return') then 1 else -1 end;
 if sign is null then raise exception 'WM2_DIRECTION'; end if;
 if origin_name='chatgpt' and (ext like 'wm-manual/%' or key like 'wm-manual/%') then raise exception 'WM2_FORMAT'; end if;
 fp:=fingerprint(j);
 select * into same from work_documents where external_id=ext;
 if found then
  if same.fingerprint<>fp then raise exception 'WM2_DOCUMENT_CONFLICT'; end if;
  return jsonb_build_object('id',same.id,'status',same.status,'duplicate',true,'same_input',same.fingerprint=fp);
 end if;
 -- A second case may claim a cancelled document only for demonstrably disjoint source lines.
 -- Follow replacements through intermediate editions, including after the first case was closed.
 if exists(with recursive ancestry(ext_id) as (
   select value from jsonb_array_elements_text(coalesce(j->'supersedes_cancelled','[]')) value
   union select old.external_id from ancestry root join work_documents child on child.external_id=root.ext_id
   join work_documents old on old.external_id=child.payload->>'replaces' or coalesce(child.payload->'supersedes_cancelled','[]') ? old.external_id
 ) select from ancestry root join work_documents old on old.external_id=root.ext_id
 join work_documents first on first.payload->>'replaces'=root.ext_id or coalesce(first.payload->'supersedes_cancelled','[]') ? root.ext_id
 join work_documents live on live.id=first.id or (live.case_id=first.case_id and live.edition>=first.edition)
 left join work_cases c on c.id=live.case_id
 where live.status not in ('dismissed','previous') and c.external_key is distinct from key and
  (exists(select from jsonb_array_elements(j->'lines') incoming
     where not exists(select from work_lines src where src.document_id=old.id and src.line_key=incoming->>'line_id')
     or exists(select from work_lines claimed where claimed.document_id in (first.id,live.id) and claimed.line_key=incoming->>'line_id'))
   or exists(select from work_lines claimed where claimed.document_id=first.id and not exists(
      select from work_lines src where src.document_id=old.id and src.line_key=claimed.line_key))))
 then raise exception 'WM4_REPLACED';end if;
 if file_sha is not null then
  select * into same from work_documents w where w.file_hash=file_sha
   and not (previous_ext is not null and w.external_id=previous_ext and w.version+1=v and
    exists(select from work_cases c where c.id=w.case_id and c.external_key=key))
   and not (w.status='dismissed' and (w.external_id is not distinct from previous_ext or coalesce(j->'supersedes_cancelled','[]') ? w.external_id))
   order by (w.status='current') desc,w.created_at desc limit 1;
  if found then return jsonb_build_object('id',same.id,'status',same.status,'duplicate',true,'same_input',same.fingerprint=fp); end if;
 end if;
 if key is not null then select id into job from work_cases where external_key=key; end if;
 if job is not null then
  select * into same from work_documents d where d.case_id=job and d.version=v and
    (d.payload-'document_id')=(j-'document_id') limit 1;
  if found then return jsonb_build_object('id',same.id,'status',same.status,'duplicate',true,'same_input',same.fingerprint=fp); end if;
 end if;
 if previous_ext is not null then
  select * into prior from work_documents where external_id=previous_ext and case_id is not null;
  if prior.id is null or (job is not null and job<>prior.case_id)
   or (key is not null and job is null and exists(select from work_cases where id=prior.case_id and external_key is distinct from key))
   then issue_text:='이전 문서 식별자를 확인해 주세요.';
  else job:=prior.case_id; end if;
 end if;
 if job is not null then
  select * into prior from work_documents where case_id=job and edition is not null order by edition desc limit 1;
  if (not (prior.status='dismissed' and coalesce(j->'supersedes_cancelled','[]') ? prior.external_id and v=1) and v<>prior.version+1) or prior.category<>cat or (previous_ext is not null and prior.external_id<>previous_ext) or
     (prior.customer<>customer and prior.customer<>'' and customer<>'') then issue_text:='기존 건의 문서 버전·거래처·유형을 확인해 주세요.'; end if;
 elsif key is null or v<>1 or previous_ext is not null or coalesce((j->>'is_revision')::boolean,false) then
  issue_text:='새 건인지, 기존 건의 수정본인지 확인해 주세요.';
 elsif issue_text='' then null;
 end if;

 return jsonb_build_object('duplicate',false,'case',job,'issue',issue_text,'status',case when issue_text<>'' then 'unlinked'
 when exists(select from work_rows w where w.case_id=job and w.batch_id is not null) then 'reconcile' else 'current' end,'direction',sign);
end $$;

create or replace function public.wm2_manual(p_item uuid,p_day date,p_category text,p_qty integer,p_request uuid,
 p_customer text default '',p_method text default null,p_direction text default null,p_note text default '',
 p_corrects bigint default null,p_related uuid default null)
returns jsonb language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); name text; result jsonb; j jsonb;
begin
 perform work_lock();
 if p_request is null or p_day is null or p_qty is null or p_qty<1 or length(p_note)>1500 then raise exception 'WM_INVALID'; end if;
 select i.name into strict name from items i join datasets d on d.id=i.dataset_id and d.active where i.id=p_item;
 if p_corrects is not null or p_related is not null then raise exception 'WM4_RECORD_ONLY';end if;
 j:=jsonb_build_object('schema_version',1,'document_id','wm-manual/'||p_request,'case_id','wm-manual/'||p_request,'version',1,
  'work_date',p_day,'document_type','수기 전표','category',p_category,'direction',p_direction,
  'customer',coalesce(p_customer,''),'method',p_method,'source',jsonb_build_object('text',coalesce(p_note,'')),
  'corrects',p_corrects,'related',p_related,'lines',jsonb_build_array(jsonb_build_object('line_id','1','raw_name',name,'sku',p_item,'qty',p_qty)));
 result:=intake(j,'manual',actor,null,null);
 return result;
end $$;

create or replace function warehouse_master.day_view(day_to_read date) returns jsonb language plpgsql stable set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare r jsonb; issues jsonb; batches jsonb; removed jsonb; mark text;
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
 mark:=fingerprint(jsonb_build_array(r,issues));
 return jsonb_build_object('rows',r,'issues',issues,'batches',batches,'removed',removed,'stamp',mark);
end $$;

create or replace function public.wm2_close(p_day date,p_stamp text,p_request uuid) returns jsonb
language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); state jsonb; b close_batches%rowtype; last_batch close_batches%rowtype; r record;
 posted jsonb; result_id bigint; tally int:=0; reviews jsonb; item_revision bigint;
begin
 perform work_lock();
 if p_request is null or p_day is null or p_stamp is null then raise exception 'WM_INVALID'; end if;
 select * into b from close_batches where id=p_request;
 if found then
  if b.work_day<>p_day or b.snapshot<>p_stamp then raise exception 'WM_REQUEST_MISMATCH'; end if;
  return jsonb_build_object('id',b.id,'sequence',b.sequence,'duplicate',true);
 end if;
 -- Lock every affected item in UUID order, also against a simultaneous v1 physical count.
 perform i.id from items i where exists(select from daily_rows w where w.work_day=p_day and w.doc_status='current' and
  w.batch_id is null and w.decision in ('ready','pending') and not w.related_hold and w.stock_managed and w.item_id=i.id) order by i.id for update of i;
 state:=day_view(p_day);
 if state->>'stamp'<>p_stamp then raise exception 'WM_STALE'; end if;
 if exists(select from jsonb_array_elements(state->'issues') x where not (x->>'deferred')::boolean)
  or exists(select from daily_rows w where w.work_day=p_day and w.doc_status='current' and w.batch_id is null
   and w.decision in ('pending','ready') and not w.related_hold and w.check_reason<>'') then raise exception 'WM2_REVIEW_FIRST'; end if;
 for r in select item_id,name,qty,sum(direction::bigint*stock_qty) delta from daily_rows
  where work_day=p_day and doc_status='current' and batch_id is null and decision in ('pending','ready') and not related_hold and check_reason='' and stock_managed group by item_id,name,qty loop
  if r.qty is null then raise exception 'WM_UNKNOWN'; end if;
  if r.qty+r.delta<0 then raise exception 'WM_SHORT' using detail=jsonb_build_object('current',r.qty,'short',-(r.qty+r.delta),'name',r.name)::text; end if;
 end loop;
 select * into last_batch from close_batches where work_day=p_day order by sequence desc limit 1;
 reviews:=jsonb_build_object('rows',state->'rows','issues',state->'issues');
 if jsonb_array_length(state->'rows')=0 and jsonb_array_length(state->'issues')=0 then raise exception 'WM2_EMPTY'; end if;
 if not exists(select from daily_rows where work_day=p_day and doc_status='current' and batch_id is null and decision in ('pending','ready') and not related_hold and check_reason='') and
  last_batch.id is not null and not exists(
   select 1 from jsonb_array_elements(state->'rows') x where x->>'batch_id' is null and not exists(
    select from jsonb_array_elements(last_batch.reviewed->'rows') y where y->>'id'=x->>'id' and y->>'rev'=x->>'rev'))
  and state->'issues'=last_batch.reviewed->'issues' then raise exception 'WM2_EMPTY'; end if;
 insert into close_batches(id,work_day,sequence,snapshot,previous_id,approver,reviewed)
  values(p_request,p_day,coalesce(last_batch.sequence,0)+1,p_stamp,last_batch.id,auth.uid(),reviews) returning * into b;
 for r in select * from daily_rows where work_day=p_day and doc_status='current' and batch_id is null and decision in ('pending','ready') and not related_hold and check_reason=''
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

create or replace function public.wm2_log(p_filters jsonb default '{}',p_after bigint default null) returns jsonb
language plpgsql stable security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare oldest boolean:=coalesce(p_filters->>'sort','desc')='asc'; result jsonb;
begin
 perform member_role();
 with filtered as (
  select m.* from reported_movements m where
  (nullif(p_filters->>'item','') is null or m.item_id=(p_filters->>'item')::uuid)
  and (coalesce(p_filters->>'sales','false')<>'true' or not m.record_deleted)
  and (nullif(p_filters->>'from','') is null or m.work_day>=nullif(p_filters->>'from','')::date)
  and (nullif(p_filters->>'to','') is null or m.work_day<=nullif(p_filters->>'to','')::date)
  and (nullif(p_filters->>'category','') is null or m.category=p_filters->>'category')
  and (nullif(p_filters->>'method','') is null or m.record_method=p_filters->>'method')
  and strpos(lower(coalesce(m.record_customer,'')),lower(coalesce(p_filters->>'customer','')))>0
  and strpos(norm(concat_ws(' ',m.name,m.sku,m.spec,m.display_name)),norm(coalesce(p_filters->>'query','')))>0
 ), boundary as (select work_day,id from reported_movements where id=p_after),
 win as (select f.* from filtered f where p_after is null or exists(select from boundary a where
  (oldest and (f.work_day,f.id)>(a.work_day,a.id)) or (not oldest and (f.work_day,f.id)<(a.work_day,a.id)))
  order by case when oldest then f.work_day end,case when oldest then f.id end,
   case when not oldest then f.work_day end desc,case when not oldest then f.id end desc limit 51),
 page as (select * from win order by case when oldest then work_day end,case when oldest then id end,
   case when not oldest then work_day end desc,case when not oldest then id end desc limit 50)
 select jsonb_build_object('rows',coalesce(jsonb_agg(to_jsonb(page) order by case when oldest then work_day end,case when oldest then id end,
  case when not oldest then work_day end desc,case when not oldest then id end desc),'[]'),'more',(select count(*)>50 from win)) into result from page;
 return result;
end $$;

create or replace function public.wm2_documents(p_day date) returns jsonb language plpgsql stable security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
begin
 perform require_admin();
 return (select coalesce(jsonb_agg(jsonb_build_object('id',id,'external_id',external_id,'customer',customer,'version',version,'status',status,
 'work_day',work_day,'origin',origin,'document_type',document_type,'issue',issue,'deferred',deferred,'closed_lines',(select count(*) from work_rows w where w.document_id=d.id and w.batch_id is not null)) order by created_at desc),'[]') from work_documents d where work_day=p_day);
end $$;

create or replace function public.wm2_document(p_doc uuid) returns jsonb language plpgsql stable security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare d work_documents%rowtype; admin boolean:=member_role()='admin'; versions jsonb; audit jsonb; suggestions jsonb; settled jsonb;
begin
 select * into strict d from work_documents where id=p_doc;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'external_id',x.external_id,'version',x.version,'edition',x.edition,
 'status',x.status,'work_day',x.work_day,'origin',x.origin,'document_type',x.document_type,'created_at',x.created_at,
 'submitted_by',x.submitted_by,'customer',x.customer,'corrects_entry',x.corrects_entry,'related_document',x.related_document,
 'source',case when admin then x.payload->'source' end,'source_time',x.payload->'source_time',
 'has_file',admin and exists(select from storage.objects o where o.bucket_id='warehouse-documents-v2' and o.name=x.file_hash),
 'lines',(select coalesce(jsonb_agg(to_jsonb(w)||jsonb_build_object('confidence',x.payload->'lines'->(w.pos-1)->'confidence',
 'read_reason',x.payload->'lines'->(w.pos-1)->'review_reason') order by w.pos),'[]') from daily_rows w where w.document_id=x.id))
 order by x.edition nulls last,x.created_at),'[]') into versions from work_documents x
 where x.id=d.id or x.case_id=coalesce(d.case_id,d.suspected_case);
 select coalesce(jsonb_agg(to_jsonb(a) order by a.id),'[]') into audit from work_audit a where a.document_id=d.id;
 select coalesce(jsonb_agg(to_jsonb(t)),'[]') into suggestions from (
  select x.id,x.external_id,x.case_id,x.customer,x.work_day,x.edition,c.external_key from work_documents x join work_cases c on c.id=x.case_id
  where d.status='unlinked' and x.edition=(select max(y.edition) from work_documents y where y.case_id=x.case_id) and
   (x.case_id=d.suspected_case or (x.customer=d.customer and x.work_day=d.work_day and exists(select from work_lines a join work_lines b
     on a.raw_name=b.raw_name where a.document_id=d.id and b.document_id=x.id)))
  order by x.created_at desc limit 12) t;
 with recursive trail as (
  select m.* from reported_movements m join work_documents x on x.id=m.document_id
  where x.case_id=coalesce(d.case_id,d.suspected_case) or exists(select from work_documents a where a.id=x.related_document and a.case_id=coalesce(d.case_id,d.suspected_case))
  union select next.* from reported_movements next join trail prev on next.corrects_entry=prev.id
 ) select coalesce(jsonb_agg(to_jsonb(trail) order by id),'[]') into settled from trail;
 return jsonb_build_object('selected',d.id,'versions',versions,'audit',audit,'suggestions',suggestions,'settled',settled);
end $$;

create function public.wm4_dispose(p_line uuid,p_rev integer,p_decision text,p_reason text) returns void
language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare who text:=require_admin(); old work_lines%rowtype;
begin
 perform work_lock();old:=editable(p_line,p_rev);
 if p_decision is null or p_decision not in ('hold','exclude') or nullif(btrim(p_reason),'') is null or length(p_reason)>1500 then raise exception 'WM2_REASON';end if;
 update work_lines set decision=p_decision,reason=btrim(p_reason),rev=rev+1 where id=p_line;
 perform event(old.document_id,p_line,'review',who,to_jsonb(old),jsonb_build_object('decision',p_decision,'reason',btrim(p_reason)));
end $$;

revoke all on catalog_items,daily_rows,reported_movements from public,anon,authenticated;
revoke all on function warehouse_master.product_label(text,text,boolean,text) from public,anon,authenticated,service_role;
do $$ declare f regprocedure;
begin
 for f in select p.oid::regprocedure from pg_proc p where p.pronamespace='public'::regnamespace
 and p.proname in ('wm4_dispose','wm4_catalog','wm4_amend','wm4_amendments','wm4_pending') loop
  execute format('revoke all on function %s from public,anon,authenticated',f);
  execute format('grant execute on function %s to authenticated',f);
 end loop;
end $$;
notify pgrst,'reload schema';
commit;
