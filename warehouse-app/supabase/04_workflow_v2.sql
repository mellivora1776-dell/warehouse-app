-- Apply once as one transaction on top of v1. No inventory rows are seeded or updated.
begin;
set local search_path=warehouse_master,pg_catalog;
create table sku_details (
 item_id uuid primary key references items, sku text not null unique, spec text not null,
 made_to_order boolean not null, aliases text[] not null default '{}'
);
create table work_cases (
 id uuid primary key default gen_random_uuid(), external_key text unique,
 created_at timestamptz not null default clock_timestamp()
);
create table work_documents (
 id uuid primary key default gen_random_uuid(), external_id text not null unique,
 case_id uuid references work_cases, suggested_key text, version integer not null check(version>0),
 status text not null check(status in ('unlinked','current','previous','reconcile','dismissed','reconciled')),
 issue text not null default '', work_day date not null, category text not null
   check(category in ('production_in','production_out','sale','return','as')),
 direction smallint not null check(direction in (-1,1)), customer text not null default '',
 method text check(method in ('직납','화물','방문')), origin text not null check(origin in ('chatgpt','manual','correction')),
 document_type text not null, payload jsonb not null, fingerprint text not null,
 file_hash text unique check(file_hash ~ '^[a-f0-9]{64}$'),
 created_at timestamptz not null default clock_timestamp(), submitted_by text not null,
 corrects_entry bigint references entries, related_document uuid references work_documents
);
create unique index wm2_current_case on work_documents(case_id) where status='current';
create index wm2_documents_day on work_documents(work_day,status);
create index wm2_documents_case on work_documents(case_id,version);
create table work_lines (
 id uuid primary key default gen_random_uuid(), document_id uuid not null references work_documents,
 pos integer not null, line_key text not null, raw_sku text not null, raw_name text not null, spec text not null,
 read_qty integer check(read_qty>0), final_qty integer check(final_qty>0), item_id uuid references items,
 method text check(method in ('직납','화물','방문')), customer text not null,
 decision text not null default 'pending' check(decision in ('pending','ready','hold','exclude')),
 reason text not null default '', picked boolean not null default false, pick_changed boolean not null default false,
 rev integer not null default 0, unique(document_id,line_key), unique(document_id,pos)
);
create index wm2_lines_item on work_lines(item_id);
create table close_batches (
 id uuid primary key, work_day date not null, sequence integer not null, snapshot text not null,
 previous_id uuid references close_batches, approver uuid not null references members(user_id),
 approved_at timestamptz not null default clock_timestamp(), unique(work_day,sequence)
);
create table posted_lines (
 line_id uuid primary key references work_lines, entry_id bigint not null unique references entries,
 batch_id uuid not null references close_batches
);
create index wm2_post_batch on posted_lines(batch_id);
create table work_audit (
 id bigint generated always as identity primary key, document_id uuid not null references work_documents,
 line_id uuid references work_lines, action text not null, actor text not null,
 happened_at timestamptz not null default clock_timestamp(), before_value jsonb, after_value jsonb
);
create index wm2_audit_doc on work_audit(document_id,id);
create table intake_keys (
 id uuid primary key default gen_random_uuid(), digest bytea not null unique, issued_by uuid not null references members(user_id),
 issued_at timestamptz not null default now(), enabled boolean not null default true
);
-- The original file is private in Storage. Only actual objects can produce a link.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('warehouse-documents-v2','warehouse-documents-v2',false,4194304,array['image/jpeg','image/png','image/webp','application/pdf']);

do $$ declare t text;
begin
 foreach t in array array['sku_details','work_cases','work_documents','work_lines','close_batches','posted_lines','work_audit','intake_keys'] loop
  execute format('alter table warehouse_master.%I enable row level security',t);
  execute format('revoke all on table warehouse_master.%I from public,anon,authenticated',t);
 end loop;
end $$;

-- Keep the original row lock, idempotency check, validation and audit implementation.
-- Only the count form remains a public direct mutation. All other movements need a close.
alter function public.wm_change(uuid,text,integer,text,bigint,uuid) set schema warehouse_master;
alter function warehouse_master.wm_change(uuid,text,integer,text,bigint,uuid) rename to apply_stock_change;
revoke all on function warehouse_master.apply_stock_change(uuid,text,integer,text,bigint,uuid) from public,anon,authenticated;
create function public.wm_change(p_item uuid,p_kind text,p_amount integer,p_memo text,p_revision bigint,p_request uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if warehouse_master.member_role()<>'admin' then raise exception 'WM_READ_ONLY' using errcode='42501'; end if;
 if p_kind is distinct from 'count' then raise exception 'WM2_USE_CLOSE'; end if;
 return warehouse_master.apply_stock_change(p_item,p_kind,p_amount,p_memo,p_revision,p_request);
end $$;

-- Serialize edits to this single warehouse workflow. Inventory counts still use row locks.
create function warehouse_master.work_lock() returns void language sql volatile set search_path='' as $$
 select pg_advisory_xact_lock(214601,2)
$$;
create function warehouse_master.require_admin() returns text language plpgsql stable set search_path='' as $$
begin
 if warehouse_master.member_role()<>'admin' then raise exception 'WM_READ_ONLY' using errcode='42501'; end if;
 return (select display_name from warehouse_master.members where user_id=auth.uid());
end $$;
create function warehouse_master.event(doc uuid,line uuid, action text,actor text, before_value jsonb, after_value jsonb)
returns void language sql set search_path='' as $$
 insert into warehouse_master.work_audit(document_id,line_id,action,actor,before_value,after_value)
 values(doc,line,action,actor,before_value,after_value)
$$;
create function warehouse_master.fingerprint(j jsonb) returns text language sql immutable set search_path='' as $$
 select encode(extensions.digest(convert_to(j::text,'UTF8'),'sha256'),'hex')
$$;
create function warehouse_master.match_sku(sku text,raw_name text,spec text) returns uuid
language sql stable set search_path='' as $$
 select case when count(*)=1 then (array_agg(i.id))[1] end
 from warehouse_master.items i join warehouse_master.datasets d on d.id=i.dataset_id and d.active
 left join warehouse_master.sku_details s on s.item_id=i.id
 where ($1='' or $1=i.id::text or $1=i.name or $1=s.sku or $1=any(s.aliases))
   and ($2=i.name or $2=any(s.aliases))
   and ($3=coalesce(s.spec,'') or ($3='' and ($1=i.id::text or $1=s.sku)))
$$;
create function public.wm2_catalog(p_search text default '') returns jsonb
language plpgsql stable security definer set search_path='' as $$
begin
 perform warehouse_master.member_role();
 return (select coalesce(jsonb_agg(to_jsonb(t) order by t.ordinal),'[]'::jsonb) from (
  select i.id,i.name,i.qty,i.racks,i.ordinal,coalesce(s.sku,i.name) sku,coalesce(s.spec,'') spec,
         coalesce(s.made_to_order,false) made_to_order
  from warehouse_master.items i join warehouse_master.datasets d on d.id=i.dataset_id and d.active
  left join warehouse_master.sku_details s on s.item_id=i.id
  where warehouse_master.matches(i,warehouse_master.norm(coalesce(p_search,''))) or
  strpos(warehouse_master.norm(concat_ws(' ',s.sku,s.spec,array_to_string(s.aliases,' '))),warehouse_master.norm(p_search))>0
  order by i.ordinal limit 100) t);
end $$;
create or replace function public.wm_items(p_query text default '',p_after integer default 0) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare q text:=warehouse_master.norm(coalesce(p_query,'')); result jsonb;
begin
 perform warehouse_master.member_role();
 with found as materialized (
  select i.id,i.name,i.qty,i.ordinal,s.sku,s.spec from warehouse_master.items i
  join warehouse_master.datasets d on d.id=i.dataset_id and d.active
  left join warehouse_master.sku_details s on s.item_id=i.id
  where (q<>'' or not coalesce(s.made_to_order,false) or i.qty is distinct from 0)
  and (warehouse_master.matches(i,q) or strpos(warehouse_master.norm(concat_ws(' ',s.sku,s.spec,array_to_string(s.aliases,' '))),q)>0)
 ), page as (select * from found where ordinal>p_after order by ordinal limit 100)
 select jsonb_build_object('total',(select count(*) from found),'rows',coalesce(jsonb_agg(to_jsonb(page) order by ordinal),'[]'::jsonb),
 'more',exists(select from found where ordinal>(select max(ordinal) from page))) into result from page;
 return result;
end $$;

create or replace function public.wm_item(p_item uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
 perform warehouse_master.member_role();
 select jsonb_build_object('id',i.id,'name',i.name,'qty',i.qty,'revision',i.revision,'racks',i.racks,'sku',s.sku,'spec',s.spec)
 into result from warehouse_master.items i join warehouse_master.datasets d on d.id=i.dataset_id and d.active
 left join warehouse_master.sku_details s on s.item_id=i.id where i.id=p_item;
 if result is null then raise exception 'WM_NOT_FOUND'; end if;
 return result;
end $$;

alter table work_documents add column edition integer, add column deferred boolean not null default false,
 add column suspected_case uuid references work_cases;
create unique index wm2_case_edition on work_documents(case_id,edition);
create function warehouse_master.attach_document(doc_id uuid,job_id uuid,actor text) returns text
language plpgsql set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare new_doc work_documents%rowtype; prior work_documents%rowtype; new_status text; seq integer;
begin
 select * into strict new_doc from work_documents where id=doc_id and status='unlinked';
 select * into prior from work_documents where case_id=job_id and edition is not null order by edition desc limit 1;
 seq:=coalesce(prior.edition,0)+1;
 new_status:=case when exists(select from posted_lines p join work_lines l on l.id=p.line_id
      join work_documents d on d.id=l.document_id where d.case_id=job_id) then 'reconcile' else 'current' end;
 if prior.id is not null then
  -- Only carry a completed pick when the line identity AND its physical requirements agree.
  update work_lines n set picked=o.picked and n.read_qty is not distinct from o.final_qty and
    n.item_id is not distinct from o.item_id and n.raw_name=o.raw_name and n.spec=o.spec and n.raw_sku=o.raw_sku,
    pick_changed=o.picked and (n.read_qty,n.item_id,n.raw_name,n.spec,n.raw_sku) is distinct from
                              (o.final_qty,o.item_id,o.raw_name,o.spec,o.raw_sku),
    decision=case when o.decision in ('hold','exclude') then o.decision else 'pending' end,
    reason=case when o.decision in ('hold','exclude') then o.reason else n.reason end
  from work_lines o where n.document_id=doc_id and o.document_id=prior.id and n.line_key=o.line_key;
  update work_documents set status='previous' where case_id=job_id and status in ('current','reconcile');
 end if;
 update work_documents set case_id=job_id,edition=seq,status=new_status,deferred=false,suspected_case=null,
 issue=case when new_status='reconcile' then '승인된 건의 수정본입니다. 반출 실적과 대조해 주세요.' else '' end where id=doc_id;
 perform event(doc_id,null,'version',actor,to_jsonb(prior.id),jsonb_build_object('edition',seq,'status',new_status));
 return new_status;
end $$;

create function warehouse_master.intake(j jsonb,origin_name text,actor text,anchor bigint default null,related uuid default null)
returns jsonb language plpgsql set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare ext text:=nullif(btrim(j->>'document_id'),''); key text:=nullif(btrim(j->>'case_id'),'');
 v int; day date; cat text:=j->>'category'; mode text:=nullif(j->>'method',''); sign smallint;
 customer text:=btrim(coalesce(j->>'customer','')); file_sha text:=lower(nullif(j#>>'{source,sha256}',''));
 fp text; same work_documents%rowtype; prior work_documents%rowtype; job uuid; doc uuid; issue_text text:='';
 raw jsonb; sku text; product text; spec text; n integer; pos integer:=0; qty integer; item uuid;
 previous_ext text:=nullif(j->>'replaces',''); kind text:=nullif(btrim(j->>'document_type'),''); result_status text;
begin
 perform work_lock();
 if jsonb_typeof(j) is distinct from 'object' or j->>'schema_version' is distinct from '1' or
   jsonb_typeof(j->'lines') is distinct from 'array' or length(j::text)>250000 or ext is null or length(ext)>160
   or length(key)>200 or kind is null or length(kind)>120 or length(customer)>250 then raise exception 'WM2_FORMAT'; end if;
 n:=jsonb_array_length(j->'lines');
 if n not between 1 and 200 or coalesce(j->>'version','') !~ '^[1-9][0-9]{0,5}$' or
    coalesce(j->>'work_date','') !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' or cat is null or
    cat not in ('sale','production_out','production_in','return','as') then raise exception 'WM2_FORMAT'; end if;
 v:=(j->>'version')::int; day:=(j->>'work_date')::date;
 if nullif(j->>'source_time','') is not null then perform (j->>'source_time')::timestamptz; end if;
 if origin_name='chatgpt' and cat in ('return','as') then raise exception 'WM2_MANUAL_ONLY'; end if;
 if mode is not null and (cat<>'sale' or mode not in ('직납','화물','방문')) then raise exception 'WM2_METHOD'; end if;
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
  return jsonb_build_object('id',same.id,'status',same.status,'duplicate',true);
 end if;
 if file_sha is not null then
  select * into same from work_documents where file_hash=file_sha;
  if found then return jsonb_build_object('id',same.id,'status',same.status,'duplicate',true); end if;
 end if;
 if key is not null then select id into job from work_cases where external_key=key; end if;
 if job is not null then
  select * into same from work_documents d where d.case_id=job and d.version=v and
    (d.payload-'document_id')=(j-'document_id') limit 1;
  if found then return jsonb_build_object('id',same.id,'status',same.status,'duplicate',true); end if;
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
  if v<>prior.version+1 or prior.category<>cat or (previous_ext is not null and prior.external_id<>previous_ext) or
     (prior.customer<>customer and prior.customer<>'' and customer<>'') then issue_text:='기존 건의 문서 버전·거래처·유형을 확인해 주세요.'; end if;
 elsif key is null or v<>1 or previous_ext is not null or coalesce((j->>'is_revision')::boolean,false) then
  issue_text:='새 건인지, 기존 건의 수정본인지 확인해 주세요.';
 elsif issue_text='' then insert into work_cases(external_key) values(key) returning id into job;
 end if;
 insert into work_documents(external_id,suggested_key,version,status,issue,work_day,category,direction,customer,method,origin,
  document_type,payload,fingerprint,file_hash,submitted_by,corrects_entry,related_document,suspected_case)
 values(ext,key,v,'unlinked',issue_text,day,cat,sign,customer,mode,origin_name,kind,j,fp,file_sha,actor,anchor,related,job) returning id into doc;
 for raw in select value from jsonb_array_elements(j->'lines') loop
  pos:=pos+1; sku:=btrim(coalesce(raw->>'sku','')); product:=btrim(coalesce(raw->>'raw_name','')); spec:=btrim(coalesce(raw->>'spec',''));
  if jsonb_typeof(raw)<>'object' or product='' or length(product)>600 or length(spec)>1500 or length(sku)>220
    or nullif(btrim(raw->>'line_id'),'') is null or length(raw->>'line_id')>160
    or (raw->>'qty' is not null and (jsonb_typeof(raw->'qty')<>'number' or (raw->>'qty') !~ '^[1-9][0-9]{0,9}$'))
    then raise exception 'WM2_LINE'; end if;
  qty:=(raw->>'qty')::integer;
  if raw->>'confidence' is not null and (jsonb_typeof(raw->'confidence')<>'number' or (raw->>'confidence')::numeric not between 0 and 1) then raise exception 'WM2_LINE'; end if;
  item:=match_sku(sku,product,spec);
  insert into work_lines(document_id,pos,line_key,raw_sku,raw_name,spec,read_qty,final_qty,item_id,customer,method,reason)
  values(doc,pos,raw->>'line_id',sku,product,spec,qty,qty,item,customer,mode,coalesce(raw->>'review_reason',''));
 end loop;
 result_status:='unlinked';
 if issue_text='' and job is not null then result_status:=attach_document(doc,job,actor); end if;
 return jsonb_build_object('id',doc,'status',result_status,'duplicate',false);
end $$;
create function public.wm2_import(p_doc jsonb) returns jsonb language plpgsql security definer set search_path='' as $$
declare actor text:=warehouse_master.require_admin();
begin return warehouse_master.intake(p_doc,'chatgpt',actor); end $$;
-- For an already connected, write-enabled management SQL tool. Never exposed by PostgREST.
-- Passing base64 lets a SQL-only client safely transmit quotes and document text as data.
create function warehouse_master.import_chatgpt(p_utf8_base64 text) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare data jsonb;
begin
 if p_utf8_base64 is null or length(p_utf8_base64)>340000 or p_utf8_base64 !~ '^[A-Za-z0-9+/]+={0,2}$'
 then raise exception 'WM2_FORMAT'; end if;
 data:=convert_from(decode(p_utf8_base64,'base64'),'UTF8')::jsonb;
 return warehouse_master.intake(data,'chatgpt','ChatGPT · Supabase 연결');
end $$;
revoke all on function warehouse_master.import_chatgpt(text) from public,anon,authenticated,service_role;

create function public.wm2_key(p_action text) returns jsonb language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); token text;
begin
 perform work_lock();
 if p_action='rotate' then
  update intake_keys set enabled=false where enabled;
  token:=encode(extensions.gen_random_bytes(32),'hex');
  insert into intake_keys(digest,issued_by) values(extensions.digest(token,'sha256'),auth.uid());
 elsif p_action='revoke' then update intake_keys set enabled=false where enabled;
 elsif p_action is distinct from 'status' then raise exception 'WM_INVALID'; end if;
 return jsonb_build_object('enabled',exists(select from intake_keys where enabled),'token',token);
end $$;
create function public.wm2_submit(p_token text,p_doc jsonb) returns jsonb language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare k uuid;
begin
 if p_token is null or length(p_token)<>64 then raise exception 'WM2_TOKEN' using errcode='42501'; end if;
 if not exists(select from intake_keys where enabled and digest=extensions.digest(p_token,'sha256')) then raise exception 'WM2_TOKEN' using errcode='42501'; end if;
 perform work_lock();
 select id into k from intake_keys where enabled and digest=extensions.digest(p_token,'sha256');
 if k is null then raise exception 'WM2_TOKEN' using errcode='42501'; end if;
 return intake(p_doc,'chatgpt','ChatGPT · '||left(k::text,8));
end $$;

create function public.wm2_cases(p_query text) returns jsonb language plpgsql stable security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
begin
 perform require_admin();
 return (select coalesce(jsonb_agg(to_jsonb(t)),'[]') from (
  select distinct on (c.id) d.id,c.id case_id,c.external_key,d.customer,d.external_id,d.work_day,d.edition
  from work_cases c join work_documents d on d.case_id=c.id
  where d.edition is not null and strpos(lower(concat_ws(' ',c.external_key,d.customer,d.external_id)),lower(coalesce(p_query,'')))>0
  order by c.id,d.edition desc limit 40) t);
end $$;
create function public.wm2_resolve(p_doc uuid,p_action text,p_target uuid default null,p_reason text default '') returns void
language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); d work_documents%rowtype; target work_documents%rowtype; job uuid; label text;
begin
 perform work_lock();
 select * into strict d from work_documents where id=p_doc;
 if d.status not in ('unlinked','reconcile') then raise exception 'WM_STALE'; end if;
 if nullif(btrim(p_reason),'') is null or length(p_reason)>1500 then raise exception 'WM2_REASON'; end if;
 if p_action='defer' then update work_documents set deferred=true,issue=p_reason where id=p_doc;
 elsif p_action='dismiss' and d.status='unlinked' then update work_documents set status='dismissed',issue=p_reason where id=p_doc;
 elsif p_action='reconciled' and d.status='reconcile' then update work_documents set status='reconciled',issue=p_reason,deferred=false where id=p_doc;
 elsif p_action='new' and d.status='unlinked' then
  label:=coalesce(d.suggested_key,'local/'||d.id::text);
  if exists(select from work_cases where external_key=label) then label:='local/'||d.id::text; end if;
  insert into work_cases(external_key) values(label) returning id into job;
  perform attach_document(p_doc,job,actor);
 elsif p_action='replace' and d.status='unlinked' then
  select * into target from work_documents where id=p_target;
  if target.case_id is null or target.category<>d.category or exists(select from work_documents where case_id=target.case_id and edition>target.edition)
    then raise exception 'WM_STALE'; end if;
  perform attach_document(p_doc,target.case_id,actor);
 else raise exception 'WM_INVALID'; end if;
 perform event(p_doc,null,p_action,actor,jsonb_build_object('status',d.status,'issue',d.issue),jsonb_build_object('reason',p_reason,'target',p_target));
end $$;
create function warehouse_master.editable(id_to_check uuid,expected integer,allow_reconcile boolean default false) returns work_lines
language plpgsql set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare l work_lines%rowtype;
begin
 select x.* into l from work_lines x join work_documents d on d.id=x.document_id and (d.status='current' or (allow_reconcile and d.status='reconcile'))
 where x.id=id_to_check and not exists(select from posted_lines p where p.line_id=x.id) for update of x;
 if not found or l.rev is distinct from expected then raise exception 'WM_STALE'; end if;
 return l;
end $$;
create function public.wm2_review(p_line uuid,p_rev integer,p_item uuid,p_qty integer,p_method text,p_customer text,p_decision text,p_reason text)
returns void language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); l work_lines%rowtype; cat text; edited work_lines%rowtype;
begin
 perform work_lock(); l:=editable(p_line,p_rev);
 select category into cat from work_documents where id=l.document_id;
 if p_decision is null or p_decision not in ('ready','hold','exclude','pending') or p_qty<=0 or length(p_reason)>1500 or length(p_customer)>250 then raise exception 'WM_INVALID'; end if;
 if p_item is not null and not exists(select from items i join datasets d on d.id=i.dataset_id and d.active where i.id=p_item) then raise exception 'WM_NOT_FOUND'; end if;
 if nullif(p_method,'') is not null and (cat<>'sale' or p_method not in ('직납','화물','방문')) then raise exception 'WM2_METHOD'; end if;
 if p_decision='ready' and (p_qty is null or p_item is null or (cat='sale' and (nullif(p_method,'') is null or nullif(btrim(p_customer),'') is null))) then raise exception 'WM2_INCOMPLETE'; end if;
 if p_decision in ('hold','exclude') and nullif(btrim(p_reason),'') is null then raise exception 'WM2_REASON'; end if;
 update work_lines set item_id=p_item,final_qty=p_qty,method=nullif(p_method,''),customer=btrim(coalesce(p_customer,'')),decision=p_decision,
 reason=btrim(coalesce(p_reason,'')),rev=rev+1,picked=picked and (item_id,final_qty) is not distinct from (p_item,p_qty),
 pick_changed=pick_changed or (picked and (item_id,final_qty) is distinct from (p_item,p_qty)) where id=p_line returning * into edited;
 perform event(l.document_id,p_line,'review',actor,to_jsonb(l),to_jsonb(edited));
end $$;
create function public.wm2_pick(p_line uuid,p_rev integer,p_done boolean) returns void
language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); l work_lines%rowtype;
begin
 perform work_lock(); l:=editable(p_line,p_rev);
 if p_done is null or l.decision in ('exclude','hold') or l.item_id is null or l.final_qty is null or not exists(
   select from work_documents where id=l.document_id and direction=-1 and category in ('sale','production_out')
  ) then raise exception 'WM2_INCOMPLETE'; end if;
 update work_lines set picked=p_done,pick_changed=false,rev=rev+1 where id=p_line;
 perform event(l.document_id,p_line,'pick',actor,to_jsonb(l.picked),to_jsonb(p_done));
end $$;
create function public.wm2_new_sku(p_line uuid,p_rev integer,p_sku text,p_name text,p_spec text,p_racks text[],p_ordered boolean,p_first_receipt boolean)
returns uuid language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); l work_lines%rowtype; ds uuid; result uuid; opening integer; seq integer;
begin
 perform work_lock(); l:=editable(p_line,p_rev,true);
 if p_name is null or p_sku is null or length(btrim(p_name)) not between 1 and 600 or length(btrim(p_sku)) not between 1 and 200 or
  length(p_spec)>1500 or cardinality(p_racks)>50 or exists(select from unnest(p_racks) r where length(r)>100 or nullif(btrim(r),'') is null)
  or p_first_receipt is null or p_ordered is null then raise exception 'WM_INVALID'; end if;
 select id into strict ds from datasets where active for update;
 if exists(select from items i left join sku_details s on i.id=s.item_id where i.dataset_id=ds and
    (lower(btrim(p_sku))=lower(coalesce(s.sku,i.name)) or (i.name=btrim(p_name) and coalesce(s.spec,'')=btrim(coalesce(p_spec,''))))) then raise exception 'WM2_SKU_EXISTS'; end if;
 opening:=case when p_first_receipt then 0 else null end;
 select coalesce(max(ordinal),0)+1 into seq from items where dataset_id=ds;
 insert into items(dataset_id,ordinal,name,racks,opening_qty,qty) values(ds,seq,btrim(p_name),coalesce(p_racks,'{}'),opening,opening) returning id into result;
 insert into sku_details(item_id,sku,spec,made_to_order) values(result,btrim(p_sku),btrim(coalesce(p_spec,'')),p_ordered);
 update work_lines set item_id=result,rev=rev+1,decision='pending',picked=false,pick_changed=picked or pick_changed where id=p_line;
 perform event(l.document_id,p_line,'new_sku',actor,to_jsonb(l.item_id),jsonb_build_object('sku',p_sku,'item_id',result,'baseline',opening));
 return result;
end $$;

create function public.wm2_link_revision(p_line uuid,p_rev integer,p_item uuid) returns void
language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); l work_lines%rowtype;
begin
 perform work_lock();l:=editable(p_line,p_rev,true);
 if not exists(select from work_documents where id=l.document_id and status='reconcile') then raise exception 'WM_STALE'; end if;
 if not exists(select from items i join datasets d on d.id=i.dataset_id and d.active where i.id=p_item) then raise exception 'WM_NOT_FOUND'; end if;
 update work_lines set item_id=p_item,rev=rev+1 where id=l.id;
 perform event(l.document_id,l.id,'link',actor,to_jsonb(l.item_id),to_jsonb(p_item));
end $$;

create function public.wm2_manual(p_item uuid,p_day date,p_category text,p_qty integer,p_request uuid,
 p_customer text default '',p_method text default null,p_direction text default null,p_note text default '',
 p_corrects bigint default null,p_related uuid default null)
returns jsonb language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); name text; result jsonb; j jsonb; original record; entry_origin text:='manual';
begin
 perform work_lock();
 if p_request is null or p_day is null or p_qty is null or p_qty<1 or length(p_note)>1500 then raise exception 'WM_INVALID'; end if;
 select i.name into strict name from items i join datasets d on d.id=i.dataset_id and d.active where i.id=p_item;
 if p_corrects is not null then
  select d.category,l.customer,l.method,coalesce(ref.case_id,d.case_id) case_id,e.item_id into strict original from posted_lines p join entries e on e.id=p.entry_id
   join work_lines l on l.id=p.line_id join work_documents d on d.id=l.document_id left join work_documents ref on ref.id=d.related_document where e.id=p_corrects;
  if (original.item_id<>p_item and not exists(select from work_lines l join work_documents d on d.id=l.document_id
     where d.id=p_related and d.case_id=original.case_id and d.status='reconcile' and l.item_id=p_item)) or p_direction is null or p_direction not in ('in','out') or nullif(btrim(p_note),'') is null then raise exception 'WM2_REASON'; end if;
  if p_related is not null and not exists(select from work_documents where id=p_related and case_id=original.case_id) then raise exception 'WM_INVALID'; end if;
  p_category:=original.category; p_customer:=original.customer;p_method:=original.method;entry_origin:='correction';
 end if;
 if p_related is not null and p_corrects is null then raise exception 'WM_INVALID'; end if;
 j:=jsonb_build_object('schema_version',1,'document_id','wm-manual/'||p_request,'case_id','wm-manual/'||p_request,'version',1,
  'work_date',p_day,'document_type',case when entry_origin='correction' then '정정 전표' else '수기 전표' end,'category',p_category,'direction',p_direction,
  'customer',coalesce(p_customer,''),'method',p_method,'source',jsonb_build_object('text',coalesce(p_note,'')),
  'corrects',p_corrects,'related',p_related,'lines',jsonb_build_array(jsonb_build_object('line_id','1','raw_name',name,'sku',p_item,'qty',p_qty)));
 result:=intake(j,entry_origin,actor,p_corrects,p_related);
 return result;
end $$;

create view work_rows as
 select l.id,l.document_id,l.pos,l.line_key,l.raw_name,l.raw_sku,l.spec,l.read_qty,l.final_qty,l.item_id,l.method,l.customer,
 l.decision,l.reason,l.picked,l.pick_changed,l.rev,d.external_id,d.case_id,c.external_key as case_key,d.work_day,d.category,
 d.direction,d.origin,d.edition,d.version,d.status as doc_status,d.corrects_entry,d.related_document,
 i.name,i.qty,i.racks,i.revision,coalesce(s.sku,i.name) as sku,s.spec as item_spec,
 p.entry_id,p.batch_id
 from work_lines l join work_documents d on d.id=l.document_id left join work_cases c on c.id=d.case_id
 left join items i on i.id=l.item_id left join sku_details s on s.item_id=i.id left join posted_lines p on p.line_id=l.id;
revoke all on work_rows from public,anon,authenticated;
alter table close_batches add column reviewed jsonb not null;

create function warehouse_master.day_view(day_to_read date) returns jsonb language plpgsql stable set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare r jsonb; issues jsonb; batches jsonb; removed jsonb; mark text;
begin
 select coalesce(jsonb_agg(to_jsonb(w) order by w.name,w.external_id,w.pos),'[]') into r from work_rows w
 where w.work_day=day_to_read and (w.doc_status='current' or w.entry_id is not null);
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
 where n.status='current' and n.work_day=day_to_read and not exists(select from work_lines x where x.document_id=n.id and x.line_key=old.line_key);
 mark:=fingerprint(jsonb_build_array(r,issues));
 return jsonb_build_object('rows',r,'issues',issues,'batches',batches,'removed',removed,'stamp',mark);
end $$;
create function public.wm2_day(p_day date) returns jsonb language plpgsql stable security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
begin perform member_role();return day_view(p_day);end $$;
create function public.wm2_open_days() returns jsonb language plpgsql stable security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
begin
 perform require_admin();
 return (select coalesce(jsonb_agg(day order by day),'[]') from (
 select work_day as day from work_rows where doc_status='current' and entry_id is null and decision in ('ready','pending','hold')
 union select work_day from work_documents where status in ('unlinked','reconcile')) q);
end $$;
create function public.wm2_close(p_day date,p_stamp text,p_request uuid) returns jsonb
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
 perform i.id from items i where exists(select from work_rows w where w.work_day=p_day and w.doc_status='current' and
  w.entry_id is null and w.decision='ready' and w.item_id=i.id) order by i.id for update of i;
 state:=day_view(p_day);
 if state->>'stamp'<>p_stamp then raise exception 'WM_STALE'; end if;
 if exists(select from jsonb_array_elements(state->'issues') x where not (x->>'deferred')::boolean)
  or exists(select from work_rows w where w.work_day=p_day and w.doc_status='current' and w.entry_id is null and
   (w.decision='pending' or (w.decision='ready' and (w.item_id is null or w.final_qty is null or
    (w.category='sale' and (w.method is null or nullif(w.customer,'') is null)) or exists(
     select from work_documents d where d.suspected_case=w.case_id and d.status='unlinked'))))) then raise exception 'WM2_REVIEW_FIRST'; end if;
 for r in select item_id,name,qty,sum(direction::bigint*final_qty) delta from work_rows
  where work_day=p_day and doc_status='current' and entry_id is null and decision='ready' group by item_id,name,qty loop
  if r.qty is null then raise exception 'WM_UNKNOWN'; end if;
  if r.qty+r.delta<0 then raise exception 'WM_SHORT' using detail=jsonb_build_object('current',r.qty,'short',-(r.qty+r.delta),'name',r.name)::text; end if;
 end loop;
 select * into last_batch from close_batches where work_day=p_day order by sequence desc limit 1;
 reviews:=jsonb_build_object('rows',state->'rows','issues',state->'issues');
 if jsonb_array_length(state->'rows')=0 and jsonb_array_length(state->'issues')=0 then raise exception 'WM2_EMPTY'; end if;
 if not exists(select from work_rows where work_day=p_day and doc_status='current' and entry_id is null and decision='ready') and
  last_batch.id is not null and not exists(
   select 1 from jsonb_array_elements(state->'rows') x where x->>'entry_id' is null and not exists(
    select from jsonb_array_elements(last_batch.reviewed->'rows') y where y->>'id'=x->>'id' and y->>'rev'=x->>'rev'))
  and state->'issues'=last_batch.reviewed->'issues' then raise exception 'WM2_EMPTY'; end if;
 insert into close_batches(id,work_day,sequence,snapshot,previous_id,approver,reviewed)
  values(p_request,p_day,coalesce(last_batch.sequence,0)+1,p_stamp,last_batch.id,auth.uid(),reviews) returning * into b;
 for r in select * from work_rows where work_day=p_day and doc_status='current' and entry_id is null and decision='ready'
  order by item_id,direction desc,document_id,pos loop
  select revision into strict item_revision from items where id=r.item_id;
  posted:=apply_stock_change(r.item_id,case when r.direction=1 then 'in' else 'out' end,r.final_qty,
    left(concat_ws(' · ',r.external_id,r.customer,r.method,nullif(r.reason,'')),1000),item_revision,r.id);
  result_id:=(posted->>'entry')::bigint;
  insert into posted_lines(line_id,entry_id,batch_id) values(r.id,result_id,b.id);tally:=tally+1;
 end loop;
 return jsonb_build_object('id',b.id,'sequence',b.sequence,'count',tally,'duplicate',false);
end $$;

create function public.wm2_batch(p_id uuid) returns jsonb language plpgsql stable security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare b close_batches%rowtype;
begin perform member_role();select * into strict b from close_batches where id=p_id;
 return to_jsonb(b)||jsonb_build_object('actor',(select display_name from members where user_id=b.approver));end $$;

create function public.wm2_document(p_doc uuid) returns jsonb language plpgsql stable security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare d work_documents%rowtype; admin boolean:=member_role()='admin'; versions jsonb; audit jsonb; suggestions jsonb; settled jsonb;
begin
 select * into strict d from work_documents where id=p_doc;
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'external_id',x.external_id,'version',x.version,'edition',x.edition,
 'status',x.status,'work_day',x.work_day,'origin',x.origin,'document_type',x.document_type,'created_at',x.created_at,
 'submitted_by',x.submitted_by,'customer',x.customer,'corrects_entry',x.corrects_entry,'related_document',x.related_document,
 'source',case when admin then x.payload->'source' end,'source_time',x.payload->'source_time',
 'has_file',admin and exists(select from storage.objects o where o.bucket_id='warehouse-documents-v2' and o.name=x.file_hash),
 'lines',(select coalesce(jsonb_agg(to_jsonb(w)||jsonb_build_object('confidence',x.payload->'lines'->(w.pos-1)->'confidence',
 'read_reason',x.payload->'lines'->(w.pos-1)->'review_reason') order by w.pos),'[]') from work_rows w where w.document_id=x.id))
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
  select m.* from movement_log m join work_documents x on x.id=m.document_id
  where x.case_id=coalesce(d.case_id,d.suspected_case) or exists(select from work_documents a where a.id=x.related_document and a.case_id=coalesce(d.case_id,d.suspected_case))
  union select next.* from movement_log next join trail prev on next.corrects_entry=prev.id
 ) select coalesce(jsonb_agg(to_jsonb(trail) order by id),'[]') into settled from trail;
 return jsonb_build_object('selected',d.id,'versions',versions,'audit',audit,'suggestions',suggestions,'settled',settled);
end $$;
create function public.wm2_file_ref(p_doc uuid) returns text language plpgsql stable security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare k text;
begin perform require_admin();select d.file_hash into k from work_documents d join storage.objects o on o.bucket_id='warehouse-documents-v2' and o.name=d.file_hash where d.id=p_doc;
 if k is null then raise exception 'WM_NOT_FOUND'; end if;return k;end $$;

create function public.wm2_attach_file(p_doc uuid,p_sha text,p_name text) returns void
language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); d work_documents%rowtype;
begin
 perform work_lock();select * into strict d from work_documents where id=p_doc;
 if d.file_hash is not null and d.file_hash<>p_sha then raise exception 'WM2_DOCUMENT_CONFLICT';end if;
 if not exists(select from storage.objects o where o.bucket_id='warehouse-documents-v2' and o.name=p_sha) then raise exception 'WM_NOT_FOUND';end if;
 if exists(select from work_documents where file_hash=p_sha and id<>p_doc) then raise exception 'WM2_FILE_USED';end if;
 if d.file_hash is distinct from p_sha then update work_documents set file_hash=p_sha where id=d.id;end if;
 if not exists(select from work_audit a where a.document_id=d.id and a.action='file') then
  perform event(d.id,null,'file',actor,null,jsonb_build_object('name',left(p_name,250)));
 end if;
end $$;

create function public.wm2_documents(p_day date) returns jsonb language plpgsql stable security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
begin
 perform require_admin();
 return (select coalesce(jsonb_agg(jsonb_build_object('id',id,'external_id',external_id,'customer',customer,'version',version,'status',status,
 'work_day',work_day,'origin',origin,'document_type',document_type,'issue',issue,'deferred',deferred) order by created_at desc),'[]') from work_documents where work_day=p_day);
end $$;
create view movement_log as
 select e.id,e.item_id,i.name,coalesce(s.sku,i.name) sku,coalesce(s.spec,'') spec,e.kind,e.amount,e.before_qty,e.after_qty,e.actor_name,e.memo,
 e.created_at,coalesce(d.work_day,(e.created_at at time zone 'Asia/Seoul')::date) work_day,
 coalesce(d.category,e.kind) category,coalesce(d.origin,e.source) origin,l.customer,l.method,l.read_qty,l.final_qty,d.external_id,
 d.id document_id,d.edition,d.version,b.id batch_id,b.sequence,b.approved_at,d.corrects_entry,d.related_document,
 case e.kind when 'in' then e.amount when 'out' then -e.amount when 'count' then e.after_qty-e.before_qty end signed_qty
 from entries e join items i on i.id=e.item_id join datasets ds on ds.id=i.dataset_id and ds.active
 left join sku_details s on s.item_id=i.id left join posted_lines p on p.entry_id=e.id left join close_batches b on b.id=p.batch_id
 left join work_lines l on l.id=p.line_id left join work_documents d on d.id=l.document_id;
revoke all on movement_log from public,anon,authenticated;
create function public.wm2_log(p_filters jsonb default '{}',p_after bigint default null) returns jsonb
language plpgsql stable security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare oldest boolean:=coalesce(p_filters->>'sort','desc')='asc'; result jsonb;
begin
 perform member_role();
 with filtered as (
  select m.* from movement_log m where
  (nullif(p_filters->>'item','') is null or m.item_id=(p_filters->>'item')::uuid)
  and (nullif(p_filters->>'from','') is null or m.work_day>=nullif(p_filters->>'from','')::date)
  and (nullif(p_filters->>'to','') is null or m.work_day<=nullif(p_filters->>'to','')::date)
  and (nullif(p_filters->>'category','') is null or m.category=p_filters->>'category')
  and (nullif(p_filters->>'method','') is null or m.method=p_filters->>'method')
  and strpos(lower(coalesce(m.customer,'')),lower(coalesce(p_filters->>'customer','')))>0
  and strpos(norm(concat_ws(' ',m.name,m.sku,m.spec)),norm(coalesce(p_filters->>'query','')))>0
 ), boundary as (select work_day,id from movement_log where id=p_after),
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
do $$ declare f regprocedure;
begin
 for f in select p.oid::regprocedure from pg_proc p where p.pronamespace='warehouse_master'::regnamespace
 and p.proname=any(array['work_lock','require_admin','event','fingerprint','match_sku','attach_document','intake','editable','day_view']) loop
  execute format('revoke all on function %s from public,anon,authenticated',f);
 end loop;
end $$;
do $$ declare f regprocedure;
begin
 foreach f in array array[
 'public.wm_change(uuid,text,integer,text,bigint,uuid)'::regprocedure,
 'public.wm2_attach_file(uuid,text,text)'::regprocedure,'public.wm2_link_revision(uuid,integer,uuid)'::regprocedure,
 'public.wm2_catalog(text)'::regprocedure,'public.wm2_import(jsonb)'::regprocedure,'public.wm2_key(text)'::regprocedure,
 'public.wm2_cases(text)'::regprocedure,'public.wm2_resolve(uuid,text,uuid,text)'::regprocedure,
 'public.wm2_review(uuid,integer,uuid,integer,text,text,text,text)'::regprocedure,'public.wm2_pick(uuid,integer,boolean)'::regprocedure,
 'public.wm2_new_sku(uuid,integer,text,text,text,text[],boolean,boolean)'::regprocedure,
 'public.wm2_manual(uuid,date,text,integer,uuid,text,text,text,text,bigint,uuid)'::regprocedure,
 'public.wm2_day(date)'::regprocedure,'public.wm2_open_days()'::regprocedure,'public.wm2_close(date,text,uuid)'::regprocedure,
 'public.wm2_batch(uuid)'::regprocedure,'public.wm2_document(uuid)'::regprocedure,'public.wm2_file_ref(uuid)'::regprocedure,
 'public.wm2_documents(date)'::regprocedure,'public.wm2_log(jsonb,bigint)'::regprocedure
 ] loop
  execute format('revoke all on function %s from public,anon,authenticated',f);
  execute format('grant execute on function %s to authenticated',f);
 end loop;
end $$;
revoke all on function public.wm2_submit(text,jsonb) from public,anon,authenticated;
grant execute on function public.wm2_submit(text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';
commit;
