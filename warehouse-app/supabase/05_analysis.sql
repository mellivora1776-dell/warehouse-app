-- One-time application upgrade. Existing documents, lines, balances and journal rows are untouched.
begin;
set local search_path=warehouse_master,pg_catalog;
create table analysis_rules (
 alias text not null, context text not null default '', standard_name text not null,
 managed boolean not null, basis text not null, target_item uuid references items, primary key(alias,context)
);
insert into analysis_rules(alias,context,standard_name,managed,basis) values
 ('T3-032T-M','','KTB-032T 모터',false,'터보 모터 · 관리 창고 집계 제외'),
 ('KTB-032T 모터','','KTB-032T 모터',false,'터보 모터 · 관리 창고 집계 제외'),
 ('3-1','blower_motor','KJ3AB-750 모터',true,'송풍기 모터 문맥 · 3상 1마력'),
 ('A3-750-M','blower_motor','KJ3AB-750 모터',true,'송풍기 모터 · 3상 1마력'),
 ('A','blower_motor_3phase_1hp','KJ3AB-750 모터',true,'송풍기 모터 · 3상 1마력 확인'),
 ('송 모터','blower_motor_3phase_1hp','KJ3AB-750 모터',true,'송풍기 모터 · 3상 1마력 확인'),
 ('송송 모터','blower_motor_3phase_1hp','KJ3AB-750 모터',true,'송풍기 모터 · 3상 1마력 확인'),
 ('KJB3-8600S','','KJB3-8600',true,'10마력 S타입'),
 ('휠터(소)-32A','','32A 휠터',true,'현장 확인 명칭');
create unique index wm3_normalized_rule on analysis_rules (warehouse_master.norm(alias),context);
create table line_plans (
 line_id uuid primary key references work_lines, analysis jsonb not null,
 pick_qty integer check(pick_qty>=0), stock_qty integer check(stock_qty>=0)
);
create index wm3_candidate_key on line_plans ((analysis->>'variant_key')) where analysis->>'resolution'='order_candidate';
create table nonstock_closures (
 line_id uuid primary key references work_lines, batch_id uuid not null references close_batches
);
alter table analysis_rules enable row level security;
alter table line_plans enable row level security;
alter table nonstock_closures enable row level security;
revoke all on analysis_rules,line_plans,nonstock_closures from public,anon,authenticated;
-- Date/party are never document identity. The same physical file may be re-read after an explicit cancellation.
alter table work_documents drop constraint work_documents_file_hash_key;
create index wm3_file_hash on work_documents(file_hash) where file_hash is not null;
alter table work_documents drop constraint work_documents_method_check,
 add check(method in ('직납','화물','방문','퀵','퀵·용차','용차'));
alter table work_lines drop constraint work_lines_method_check,
 add check(method in ('직납','화물','방문','퀵','퀵·용차','용차'));

create function warehouse_master.shipping_method(input text) returns text language sql immutable strict set search_path='' as $$
 select case when input ~ '퀵' and input ~ '용차' then '퀵·용차' when input ~ '용차' then '용차' when input ~ '퀵' then '퀵'
 when input ~ '방문' then '방문' when input ~ '화물' then '화물' when input ~ '직납' then '직납' end
$$;
create function warehouse_master.spec_key(s text) returns text language sql immutable set search_path='' as $$
 select warehouse_master.norm(regexp_replace(lower(coalesce(s,'')),'([0-9]{3})\s*(?:v\s*)?[-/· ]+\s*([0-9]{2})\s*(?:hz)?','\1v\2hz','gi'))
$$;
create function warehouse_master.part_kind(label text) returns text language sql immutable set search_path='' as $$
 select case when label ~* '모터|motor|[-]M($|\s)' then 'motor' when label ~ '완성품|완제품' then 'finished' when label ~ '휠터|필터|명판' then 'part' end
$$;
create function warehouse_master.attributes(label text) returns jsonb language sql immutable set search_path='' as $$
 select jsonb_strip_nulls(jsonb_build_object(
 'kind',warehouse_master.part_kind(label),
 'voltage',coalesce((regexp_match(label,'([0-9]{3})\s*[vV]'))[1],(regexp_match(label,'([0-9]{3})\s*[-/]\s*[0-9]{2}(?:[^0-9]|$)'))[1]),
 'frequency',coalesce((regexp_match(label,'([0-9]{2})\s*[hH][zZ]'))[1],(regexp_match(label,'[0-9]{3}\s*[-/]\s*([0-9]{2})(?:[^0-9]|$)'))[1]),
 'material',substring(label from '(주물|철판|스테인리스|스텐|알루미늄)'),
 'shaft',coalesce((regexp_match(label,'([0-9]+(?:[.][0-9]+)?)\s*[ΦφØø]'))[1],(regexp_match(label,'[ΦφØø]\s*([0-9]+(?:[.][0-9]+)?)'))[1],(regexp_match(label,'(?:샤프트|축경|축)\s*([0-9]+(?:[.][0-9]+)?)'))[1]),
 'heat',substring(label from '(고온용|상온용)'),
 'paint',substring(label from '(특수\s*도장|[가-힣A-Za-z0-9-]+색\s*도장)'),
 'rotation',case when label ~* '반시계|역회전|CCW' then 'ccw' when label ~* '시계방향|정회전|CW' then 'cw' end,
 'stage',substring(label from '([0-9]+단)')))
$$;
create function warehouse_master.spec_conflict(raw_attrs jsonb, target_attrs jsonb, is_order boolean) returns text
language sql immutable set search_path='' as $$
 select k from jsonb_each_text(raw_attrs) a(k,v)
 where (case when k='kind' then coalesce(target_attrs->>k,'finished') when k='voltage' then coalesce(target_attrs->>k,'380') when k='frequency' then coalesce(target_attrs->>k,'60')
 when k in ('shaft','heat','material','paint','stage') then coalesce(target_attrs->>k,'')
 else target_attrs->>k end) <> v limit 1
$$;

-- Resolve one line for both preview and import. No writes, including for a new order.
create function warehouse_master.plan_line(j jsonb,l jsonb,origin_name text) returns jsonb
language plpgsql stable set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare raw text:=coalesce(l->>'raw_name',''); spec text:=coalesce(l->>'spec','');
 std text:=nullif(btrim(l->>'standard_name'),''); std_spec text:=btrim(coalesce(l->>'standard_spec',''));
 input_sku text:=btrim(coalesce(l->>'sku','')); ref text:=nullif(l->>'item_id',''); context_key text:=coalesce(l->>'context','');
 basis text:=btrim(coalesce(l->>'match_basis',l->>'review_reason','')); kind text:=nullif(l->>'product_kind','');
 variant text:=coalesce(l->>'variant','basic'); ordered boolean; cat text:=coalesce(l->>'category',j->>'category');
 customer text:=btrim(coalesce(l->>'customer',j->>'customer','')); note text:=coalesce(l->>'remarks','');
 shipping text; ship_raw text; n int; pick int; stock int; needs_pick boolean; managed boolean;
 rule analysis_rules%rowtype; target record; actual_id uuid; attrs jsonb; given jsonb; conflict text; issue text:='';
 outcome text; rule_name text; hint text:=coalesce(l->>'review_reason',''); v2 boolean:=j->>'schema_version'='2';
begin
 if jsonb_typeof(l) is distinct from 'object' or btrim(raw)='' or length(raw)>600 or length(spec)>1500 or length(std_spec)>1500 or length(basis)>1500
  or nullif(btrim(l->>'line_id'),'') is null or length(l->>'line_id')>160 or (l->>'qty' is not null and
  (jsonb_typeof(l->'qty')<>'number' or l->>'qty' !~ '^[1-9][0-9]{0,9}$')) then raise exception 'WM2_LINE';end if;
 if cat is null or cat not in ('sale','production_in','production_out','return','as') then raise exception 'WM2_FORMAT';end if;
 if origin_name='chatgpt' and cat in ('return','as') then raise exception 'WM2_MANUAL_ONLY';end if;
 if l->>'confidence' is not null and (jsonb_typeof(l->'confidence')<>'number' or (l->>'confidence')::numeric not between 0 and 1) then raise exception 'WM2_LINE';end if;
 if variant not in ('basic','order') or kind not in ('motor','finished','part') then raise exception 'WM2_LINE';end if;
 n:=(l->>'qty')::int;
 if ref is null and input_sku ~* '^[0-9a-f]{8}-[0-9a-f-]{27}$' then ref:=input_sku;end if;
 select * into rule from analysis_rules a where norm(a.alias)=norm(raw) and
  (a.context='' or a.context=context_key or (a.context='blower_motor' and context_key='blower_motor_3phase_1hp')) order by length(a.context) desc limit 1;
 rule_name:=rule.standard_name;
 if std is not null and rule_name is not null and norm(std)<>norm(rule_name) then issue:='확인된 별칭과 표준명이 다릅니다.';end if;
 std:=coalesce(std,rule_name);
 attrs:=attributes(concat_ws(' ',raw,spec)); given:=attributes(concat_ws(' ',std,std_spec));
 if (kind is not null and coalesce(attrs->>'kind',kind)<>kind) or exists(select from jsonb_each_text(attrs) a where given->>a.key<>a.value)
 then issue:='원문과 확정한 품목 사양이 충돌합니다.';end if;
 kind:=coalesce(kind,attrs->>'kind',given->>'kind');attrs:=given||attrs||jsonb_strip_nulls(jsonb_build_object('kind',kind));
 ordered:=variant='order' or coalesce(attrs->>'voltage','380')<>'380' or coalesce(attrs->>'frequency','60')<>'60';
 -- Registered aliases carry SKU identity only in the compatible basic/order specification.
 if rule.target_item is not null and exists(select from items i left join sku_details s on s.item_id=i.id where i.id=rule.target_item and
    coalesce(s.made_to_order,false)=ordered and spec_conflict(attrs,attributes(concat_ws(' ',i.name,s.spec)),ordered) is null) then
  if ref is not null and lower(ref)<>rule.target_item::text then issue:='지정 ID와 문맥별 별칭이 충돌합니다.';end if;
  ref:=coalesce(ref,rule.target_item::text);
 end if;
 if l->>'variant'='basic' and ordered then issue:='기본품과 주문 전기 사양이 충돌합니다.';end if;
 managed:=coalesce((l->>'stock_managed')::boolean,rule.managed,true);
 if rule.managed is not null and managed<>rule.managed then issue:='현장 집계 규칙과 재고 반영 요청이 다릅니다.';end if;
 if not managed and rule.managed is distinct from false and (std is null or basis='') then issue:='집계 제외 표준명과 확인 근거가 필요합니다.';end if;
 if ref is not null and not managed then issue:='집계 제외 품목에 관리 SKU가 지정됐습니다.';end if;
  select * into target from (
   select i.id,i.name,coalesce(s.spec,'') item_spec,coalesce(s.sku,i.name) item_sku,i.racks,coalesce(s.made_to_order,false) custom,count(*) over() matches
   from items i join datasets d on d.id=i.dataset_id and d.active left join sku_details s on s.item_id=i.id
   where managed and case when ref is not null then i.id::text=lower(ref)
    when nullif(input_sku,'') is not null then (i.name=input_sku or s.sku=input_sku or input_sku=any(s.aliases) or
      (ordered and std is not null and norm(i.name)=norm(std) and not exists(select from items j2 left join sku_details t on t.item_id=j2.id
       where j2.dataset_id=d.id and (j2.name=input_sku or t.sku=input_sku or input_sku=any(t.aliases)))))
    else (norm(i.name)=norm(coalesce(std,raw)) or coalesce(std,raw)=any(s.aliases) or s.sku=coalesce(std,raw)) end
   and (ref is not null or (not ordered and (not v2 or not coalesce(s.made_to_order,false))) or
    (ordered and s.made_to_order and (std_spec='' or spec_key(s.spec)=spec_key(std_spec))))
  ) found limit 1;
 if managed then
  if ref is not null and target.id is null then issue:='현재 마스터에 없는 품목 ID입니다.';end if;
  if target.matches=1 then
   conflict:=spec_conflict(attrs,attributes(target.name||' '||target.item_spec),target.custom);
   if v2 and ref is not null and not exists(select from items i where i.id=target.id and norm(i.name)=norm(raw)) and exists(
    select from items i join datasets d on d.id=i.dataset_id and d.active left join sku_details s on s.item_id=i.id
    where i.id<>target.id and (norm(i.name)=norm(raw) or s.sku=raw) and coalesce(s.made_to_order,false)=ordered) then
    issue:='원문이 다른 마스터 품목과 일치합니다.';
   end if;
   if conflict is not null or (attrs ? 'rotation' and not(attributes(target.name||' '||target.item_spec) ? 'rotation') and (ref is null or basis='')) or (ordered and not target.custom) or
    (v2 and l->>'variant'='basic' and target.custom) or
    (kind='motor' and coalesce(part_kind(target.name||' '||target.item_spec),'finished')<>'motor') or
    (kind='finished' and part_kind(target.name||' '||target.item_spec) in ('motor','part')) or
    (std is not null and norm(std)<>norm(target.name) and std<>target.item_sku and not exists(select from sku_details s where s.item_id=target.id and std=any(s.aliases))) then
     if ref is not null or input_sku<>'' then issue:='지정한 품목의 기본·주문 구분 또는 사양이 다릅니다.';end if;
   elsif v2 and norm(raw)<>norm(target.name) and rule_name is null and basis='' and ref is not null then
     issue:='약칭과 지정 ID를 연결한 확인 근거가 필요합니다.';
   else actual_id:=target.id;std:=target.name;std_spec:=target.item_spec;end if;
  end if;
 end if;
 ship_raw:=nullif(btrim(l->>'method'),'');
 if ship_raw is not null and shipping_method(ship_raw) is null then issue:='지원하지 않는 행 출고 방식입니다.';end if;
 if cat='sale' then
  shipping:=coalesce(shipping_method(note),shipping_method(ship_raw),shipping_method(j->>'method'));
  if shipping is null and norm(j->>'document_type')='직납출고지시서' and (btrim(note)='' or (note ~ '포장' and note !~ '배송|택배|미정|미확인')) then shipping:='직납';end if;
  ship_raw:=case when shipping_method(note) is not null then note else coalesce(ship_raw,j->>'method',shipping) end;
 elsif ship_raw is not null then issue:='영업출고 이외의 행에 배송 방식이 지정됐습니다.';end if;
 needs_pick:=coalesce((l->>'pick_required')::boolean,cat in ('sale','production_out') and origin_name<>'correction');
 if (l ? 'pick_qty' and (jsonb_typeof(l->'pick_qty') not in ('number','null') or l->>'pick_qty' !~ '^(0|[1-9][0-9]{0,9})$')) or
    (l ? 'stock_qty' and (jsonb_typeof(l->'stock_qty') not in ('number','null') or l->>'stock_qty' !~ '^(0|[1-9][0-9]{0,9})$')) then raise exception 'WM2_LINE';end if;
 pick:=case when l ? 'pick_qty' then (l->>'pick_qty')::int when needs_pick then n else 0 end;
 stock:=case when l ? 'stock_qty' then (l->>'stock_qty')::int when managed then n else 0 end;
 if (not needs_pick and pick is distinct from 0) or (needs_pick and pick=0) or
  (not managed and stock is distinct from 0) or (managed and stock=0) then issue:='피킹·재고 처리 여부와 수량이 맞지 않습니다.';end if;
 outcome:=case when issue<>'' then 'conflict' when not managed and needs_pick then 'pick_only' when not managed then 'reference'
  when actual_id is not null then 'matched' when ordered then 'order_candidate' else 'unlinked' end;
 if actual_id is null and ordered and std_spec='' then std_spec:=concat_ws('·',nullif(attrs->>'voltage','')||'V',nullif(attrs->>'frequency','')||'Hz');end if;
 return jsonb_build_object('line_id',l->>'line_id','raw_name',raw,'raw_spec',spec,'raw_qty',n,'item_id',actual_id,
  'standard_name',coalesce(std,raw),'standard_spec',std_spec,'product_kind',kind,'variant',case when ordered or (actual_id is not null and target.custom) then 'order' else 'basic' end,
  'variant_key',fingerprint(jsonb_build_array(norm(coalesce(std,raw)),spec_key(std_spec),kind,attrs)),'match_basis',coalesce(nullif(basis,''),rule.basis,case when actual_id is not null then '마스터 일치' end),
  'context',context_key,'resolution',outcome,'pick_required',needs_pick,'pick_qty',pick,'stock_managed',managed,'stock_qty',stock,
  'category',cat,'customer',customer,'method',shipping,'method_raw',ship_raw,'packing',coalesce(l->>'packing',''),'remarks',note,
  'requester',coalesce(l->>'requester',j->>'requester',''),'racks',case when actual_id is not null then to_jsonb(target.racks) else '[]'::jsonb end,
  'reason',case when issue<>'' then issue when outcome='order_candidate' then '동일한 주문품 SKU를 확인하거나 신규 등록하세요.'
   when outcome='unlinked' then '기존 품목 연결 필요' when cat='sale' and shipping is null then '출고 방식 확인 필요' when cat='sale' and customer='' then '거래처 확인 필요' when n is null or (managed and stock is null) or (needs_pick and pick is null) then '수량 확인 필요' else hint end);
end $$;

create function warehouse_master.document_identity(j jsonb,origin_name text) returns jsonb
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

create function warehouse_master.saved_plan(doc uuid) returns jsonb language sql stable set search_path=warehouse_master,pg_catalog,pg_temp as $$
 select coalesce(jsonb_agg(coalesce(p.analysis,'{}')||jsonb_build_object('line_id',l.line_key,'raw_name',l.raw_name,'raw_spec',l.spec,
 'raw_qty',l.read_qty,'item_id',l.item_id,'standard_name',coalesce(i.name,p.analysis->>'standard_name',l.raw_name),'method',l.method,
 'customer',l.customer,'pick_qty',case when p.line_id is not null then p.pick_qty when d.direction<0 then l.final_qty else 0 end,
 'stock_qty',case when p.line_id is not null then p.stock_qty else l.final_qty end) order by l.pos),'[]')
 from work_lines l join work_documents d on d.id=l.document_id left join line_plans p on p.line_id=l.id left join items i on i.id=l.item_id where d.id=doc
$$;
create function warehouse_master.preflight(j jsonb,origin_name text) returns jsonb
language plpgsql stable set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare ident jsonb; plans jsonb; reasons text[]:='{}'; duplicate_doc uuid; stored jsonb; line jsonb; p jsonb; collected jsonb:='[]'; stamp text;
begin
 j:=j-'preview_stamp';ident:=document_identity(j,origin_name);
 if j->>'schema_version'='2' then
  if (j-array['schema_version','document_id','case_id','version','is_revision','replaces','document_type','work_date','source_time','category','customer','method','source','lines','change_type','requester','supersedes_cancelled','preview_stamp'])<>'{}'::jsonb or (j ? 'source' and (jsonb_typeof(j->'source')<>'object' or ((j->'source')-array['kind','text','name','sha256','reply_to','message_id','issuer','note'])<>'{}'::jsonb)) then
   reasons:=array_append(reasons,'지원하지 않는 문서 또는 근거 필드입니다. 입력 명세를 확인하세요.');end if;
  if exists(select from jsonb_array_elements(j->'lines') l where (l-array['line_id','raw_name','sku','spec','qty','confidence','review_reason','item_id','standard_name','standard_spec','match_basis','context','product_kind','variant','stock_managed','pick_required','category','customer','method','remarks','packing','requester','pick_qty','stock_qty'])<>'{}'::jsonb or
    (l ? 'pick_required' and jsonb_typeof(l->'pick_required')<>'boolean') or (l ? 'stock_managed' and jsonb_typeof(l->'stock_managed')<>'boolean')) then
   reasons:=array_append(reasons,'지원하지 않는 행 필드 또는 처리 여부 값입니다.');end if;
 end if;
 if coalesce(j->>'change_type','new') not in ('new','additional','revision','cancel') then reasons:=array_append(reasons,'지원하지 않는 변경 유형입니다.');end if;
 if j->>'change_type'='cancel' then reasons:=array_append(reasons,'취소는 관리자가 기존 미승인 문서에서 사유를 확인하고 처리하세요.');end if;
 if j->>'schema_version'='2' and (ident->>'status'='unlinked' or (j->>'change_type'='revision' and nullif(j->>'replaces','') is null)) then
  reasons:=array_append(reasons,'출고 건 및 이전 문서와의 관계를 확인하세요.');end if;
 if exists(select from jsonb_array_elements(j->'lines') x group by x->>'line_id' having count(*)>1) then raise exception 'WM2_LINE';end if;
 for line in select value from jsonb_array_elements(j->'lines') loop
  p:=plan_line(j,line,origin_name);
  if p->>'resolution'='conflict' or (j->>'schema_version'='2' and p->>'resolution'='unlinked' and (nullif(line->>'standard_name','') is not null or nullif(line->>'item_id','') is not null)) then reasons:=array_append(reasons,(p->>'line_id')||' · '||(p->>'reason'));end if;
  collected:=collected||jsonb_build_array(p);
 end loop;
 plans:=collected;
 if (ident->>'duplicate')::boolean then
  duplicate_doc:=(ident->>'id')::uuid;stored:=saved_plan(duplicate_doc);
  ident:=ident||jsonb_build_object('already_closed',exists(select from work_rows where document_id=duplicate_doc and batch_id is not null));
  if j->>'schema_version'='2' and exists(select from work_documents d where d.id=duplicate_doc and d.suggested_key is distinct from nullif(j->>'case_id','') and d.status<>'dismissed') then
   reasons:=array_append(reasons,'동일한 원본이 다른 건으로 등록돼 있습니다. 출고 건을 확인하세요.');end if;
  if j->>'schema_version'='2' and (ident->>'same_input')::boolean is not true and
   (select jsonb_agg(x-'racks' order by ord) from jsonb_array_elements(plans) with ordinality t(x,ord)) is distinct from
   (select jsonb_agg(x-'racks' order by ord) from jsonb_array_elements(stored) with ordinality t(x,ord)) then
   reasons:=array_append(reasons,'중복 원본의 저장 결과가 다릅니다. 기존 문서와 수정본 관계를 확인하세요.');end if;
 end if;
 stamp:=fingerprint(jsonb_build_array(j,ident,plans));
 return ident||jsonb_build_object('stamp',stamp,'can_submit',cardinality(reasons)=0,'blockers',to_jsonb(reasons),'lines',plans,'stored_lines',stored);
end $$;

create or replace function warehouse_master.intake(j jsonb,origin_name text,actor text,anchor bigint default null,related uuid default null)
returns jsonb language plpgsql set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare stamp text:=j->>'preview_stamp'; plan jsonb; job uuid; doc uuid; new_line uuid; state text; row_plan jsonb; raw jsonb;
 pos int:=0; verify_rows jsonb; fp text; ext text:=btrim(j->>'document_id'); key text:=nullif(btrim(j->>'case_id'),'');
begin
 perform work_lock();j:=j-'preview_stamp';fp:=fingerprint(j);plan:=preflight(j,origin_name);
 if not (plan->>'can_submit')::boolean then raise exception 'WM3_BLOCKED' using detail=(plan->'blockers')::text;end if;
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
  insert into work_lines(document_id,pos,line_key,raw_sku,raw_name,spec,read_qty,final_qty,item_id,customer,method,reason)
  values(doc,pos,row_plan->>'line_id',coalesce(raw->>'sku',''),row_plan->>'raw_name',row_plan->>'raw_spec',(row_plan->>'raw_qty')::int,
   (row_plan->>'raw_qty')::int,(row_plan->>'item_id')::uuid,row_plan->>'customer',row_plan->>'method',coalesce(raw->>'review_reason','')) returning id into new_line;
  insert into line_plans(line_id,analysis,pick_qty,stock_qty) values(new_line,row_plan,(row_plan->>'pick_qty')::int,(row_plan->>'stock_qty')::int);
 end loop;
 state:='unlinked';if plan->>'status'<>'unlinked' then state:=attach_document(doc,job,actor);end if;
 verify_rows:=saved_plan(doc);
 if verify_rows is distinct from plan->'lines' or state is distinct from plan->>'status' then raise exception 'WM3_RECEIPT_MISMATCH';end if;
 return jsonb_build_object('id',doc,'status',state,'duplicate',false,'verified',true,'stock_posted',false,'stored_lines',verify_rows);
end $$;
create function public.wm3_preview(p_doc jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin perform warehouse_master.require_admin();return warehouse_master.preflight(p_doc,'chatgpt');end $$;
create function public.wm3_preview_token(p_token text,p_doc jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if length(p_token) is distinct from 64 or not exists(select from warehouse_master.intake_keys where enabled and digest=extensions.digest(p_token,'sha256')) then
  raise exception 'WM2_TOKEN' using errcode='42501';end if;
 return warehouse_master.preflight(p_doc,'chatgpt');
end $$;
create function warehouse_master.preview_chatgpt(p_utf8_base64 text) returns jsonb language plpgsql stable security invoker set search_path='' as $$
begin
 if p_utf8_base64 is null or length(p_utf8_base64)>340000 or p_utf8_base64 !~ '^[A-Za-z0-9+/]+={0,2}$' then raise exception 'WM2_FORMAT';end if;
 return warehouse_master.preflight(convert_from(decode(p_utf8_base64,'base64'),'UTF8')::jsonb,'chatgpt');
end $$;

create function public.wm3_cancel(p_doc uuid,p_reason text) returns void language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); d work_documents%rowtype;
begin
 perform work_lock();select * into strict d from work_documents where id=p_doc;
 if nullif(btrim(p_reason),'') is null or length(p_reason)>1500 then raise exception 'WM2_REASON';end if;
 if d.status='dismissed' then return;end if;
 if d.status not in ('unlinked','current') or exists(select from work_rows where case_id=d.case_id and batch_id is not null) then raise exception 'WM3_CORRECTION_ONLY';end if;
 update work_documents set status='dismissed',issue=p_reason,deferred=false where id=p_doc;
 perform event(d.id,null,'cancel',actor,to_jsonb(d.status),jsonb_build_object('reason',p_reason));
end $$;

create function public.wm3_remember_alias(p_line uuid,p_context text default '') returns void language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); r record; existing analysis_rules%rowtype;
begin
 perform work_lock();select * into strict r from work_rows where id=p_line;
 if (r.stock_managed and r.item_id is null) or (r.stock_managed and r.raw_name=r.name) or length(p_context)>120
 or (trim(coalesce(p_context,''))='' and (norm(r.raw_name) in ('31','a','송모터','송송모터','ro50a') or exists(select from analysis_rules k where norm(k.alias)=norm(r.raw_name) and k.context<>''))) or r.doc_status not in ('reconcile','current') then raise exception 'WM2_INCOMPLETE';end if;
 select * into existing from analysis_rules where norm(alias)=norm(r.raw_name) and context=trim(coalesce(p_context,''));
 if found and (existing.standard_name<>r.standard_name or existing.managed<>r.stock_managed or (existing.target_item is not null and existing.target_item<>r.item_id)) then raise exception 'WM3_ALIAS_CONFLICT';end if;
 insert into analysis_rules(alias,context,standard_name,managed,basis,target_item) values(r.raw_name,trim(coalesce(p_context,'')),r.standard_name,r.stock_managed,'관리자 확인 · '||actor,r.item_id) on conflict do nothing;
 perform event(r.document_id,r.id,'alias',actor,null,jsonb_build_object('name',r.standard_name,'context',p_context,'stock_managed',r.stock_managed));
end $$;



create or replace view work_rows as
 select l.id,l.document_id,l.pos,l.line_key,l.raw_name,l.raw_sku,l.spec,l.read_qty,l.final_qty,l.item_id,l.method,l.customer,
 l.decision,l.reason,l.picked,l.pick_changed,l.rev,d.external_id,d.case_id,c.external_key as case_key,d.work_day,coalesce(a.analysis->>'category',d.category) category,
 case when d.origin='correction' or d.category='as' then d.direction when coalesce(a.analysis->>'category',d.category) in ('production_in','return') then 1::smallint else -1::smallint end direction,d.origin,d.edition,d.version,d.status as doc_status,d.corrects_entry,d.related_document,
 i.name,i.qty,i.racks,i.revision,coalesce(s.sku,i.name) as sku,s.spec as item_spec,
 p.entry_id,coalesce(p.batch_id,ack.batch_id) batch_id,
 coalesce((a.analysis->>'stock_managed')::boolean,true) stock_managed,
 coalesce((a.analysis->>'pick_required')::boolean,d.category in ('sale','production_out') and d.direction=-1) pick_required,
 case when a.line_id is not null then a.stock_qty else l.final_qty end stock_qty,
 case when a.line_id is not null then a.pick_qty when d.category in ('sale','production_out') and d.direction=-1 then l.final_qty else 0 end pick_qty,
 coalesce(i.name,a.analysis->>'standard_name',l.raw_name) standard_name,
 coalesce(nullif(s.spec,''),a.analysis->>'standard_spec','') standard_spec,
 case when l.item_id is not null then 'matched' else coalesce(a.analysis->>'resolution','unlinked') end resolution,
 coalesce(a.analysis->>'match_basis','') match_basis,case when l.item_id is not null then case when s.made_to_order then 'order' else 'basic' end else coalesce(a.analysis->>'variant','basic') end variant,
 a.analysis->>'product_kind' product_kind,a.analysis->>'context' context,
 a.analysis->>'variant_key' variant_key,a.analysis->>'remarks' remarks,a.analysis->>'packing' packing,
 a.analysis->>'requester' requester,case when l.method is not distinct from a.analysis->>'method' then a.analysis->>'method_raw' else l.method end method_raw,
 a.analysis->>'reason' analysis_reason,e.before_qty posted_before,e.after_qty posted_after
 from work_lines l join work_documents d on d.id=l.document_id left join work_cases c on c.id=d.case_id
 left join items i on i.id=l.item_id left join sku_details s on s.item_id=i.id left join posted_lines p on p.line_id=l.id
 left join entries e on e.id=p.entry_id left join line_plans a on a.line_id=l.id left join nonstock_closures ack on ack.line_id=l.id;

create or replace function warehouse_master.attach_document(doc_id uuid,job_id uuid,actor text) returns text
language plpgsql set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare new_doc work_documents%rowtype; prior work_documents%rowtype; new_status text; seq integer;
begin
 select * into strict new_doc from work_documents where id=doc_id and status='unlinked';
 select * into prior from work_documents where case_id=job_id and edition is not null order by edition desc limit 1;
 seq:=coalesce(prior.edition,0)+1;
 new_status:=case when exists(select from work_rows where case_id=job_id and batch_id is not null) then 'reconcile' else 'current' end;
 if prior.id is not null and prior.status<>'dismissed' then
  -- Only carry a completed pick when the line identity AND its physical requirements agree.
  update work_lines n set picked=o.picked and n.read_qty is not distinct from o.final_qty and
    n.item_id is not distinct from o.item_id and n.raw_name=o.raw_name and n.spec=o.spec and n.raw_sku=o.raw_sku and not exists(select from work_rows a,work_rows b where a.id=n.id and b.id=o.id and
     (a.pick_qty,a.customer,a.method,a.standard_name,a.packing,a.remarks,a.requester) is distinct from (b.pick_qty,b.customer,b.method,b.standard_name,b.packing,b.remarks,b.requester)),
    pick_changed=o.picked and ((n.read_qty,n.item_id,n.raw_name,n.spec,n.raw_sku) is distinct from
                              (o.final_qty,o.item_id,o.raw_name,o.spec,o.raw_sku) or exists(select from work_rows a,work_rows b where a.id=n.id and b.id=o.id and
     (a.pick_qty,a.customer,a.method,a.standard_name,a.packing,a.remarks,a.requester) is distinct from (b.pick_qty,b.customer,b.method,b.standard_name,b.packing,b.remarks,b.requester))),
    decision=case when o.decision in ('hold','exclude') and not exists(select from work_rows a,work_rows b where a.id=n.id and b.id=o.id and
     (a.stock_qty,a.pick_qty,a.stock_managed,a.category,a.item_id) is distinct from (b.stock_qty,b.pick_qty,b.stock_managed,b.category,b.item_id)) and
      (n.raw_name,n.raw_sku,n.spec,n.read_qty,n.customer,n.method) is not distinct from
      (o.raw_name,o.raw_sku,o.spec,o.final_qty,o.customer,o.method) then o.decision else 'pending' end,
    reason=case when o.decision in ('hold','exclude') and not exists(select from work_rows a,work_rows b where a.id=n.id and b.id=o.id and
     (a.stock_qty,a.pick_qty,a.stock_managed,a.category,a.item_id) is distinct from (b.stock_qty,b.pick_qty,b.stock_managed,b.category,b.item_id)) and
      (n.raw_name,n.raw_sku,n.spec,n.read_qty,n.customer,n.method) is not distinct from
      (o.raw_name,o.raw_sku,o.spec,o.final_qty,o.customer,o.method) then o.reason else n.reason end
  from work_lines o where n.document_id=doc_id and o.document_id=prior.id and n.line_key=o.line_key;
  update work_documents set status='previous' where case_id=job_id and status in ('current','reconcile');
 end if;
 update work_documents set case_id=job_id,edition=seq,status=new_status,deferred=false,suspected_case=null,
 issue=case when new_status='reconcile' then '승인된 건의 수정본입니다. 반출 실적과 대조해 주세요.' else '' end where id=doc_id;
 perform event(doc_id,null,'version',actor,to_jsonb(prior.id),jsonb_build_object('edition',seq,'status',new_status));
 return new_status;
end $$;

create or replace function warehouse_master.editable(id_to_check uuid,expected integer,allow_reconcile boolean default false) returns work_lines
language plpgsql set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare l work_lines%rowtype;
begin
 select x.* into l from work_lines x join work_documents d on d.id=x.document_id and (d.status='current' or (allow_reconcile and d.status='reconcile'))
 where x.id=id_to_check and not exists(select from posted_lines p where p.line_id=x.id) and not exists(select from nonstock_closures a where a.line_id=x.id) for update of x;
 if not found or l.rev is distinct from expected then raise exception 'WM_STALE'; end if;
 return l;
end $$;

create or replace function public.wm3_review(p_line uuid,p_rev integer,p_item uuid,p_qty integer,p_method text,p_customer text,p_decision text,p_reason text,p_pick_qty integer,p_stock_qty integer,p_remember boolean default false,p_context text default '')
returns void language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); l work_lines%rowtype; w work_rows%rowtype; target record; cat text; edited work_lines%rowtype;
begin
 perform work_lock(); l:=editable(p_line,p_rev);
 select * into strict w from work_rows where id=l.id;cat:=w.category;
 if (not w.pick_required and p_pick_qty is distinct from 0) or (w.pick_required and p_pick_qty<=0) or
    (not w.stock_managed and (p_stock_qty is distinct from 0 or p_item is not null)) or
    (w.stock_managed and p_stock_qty<=0) then raise exception 'WM_INVALID';end if;
 if p_item is not null and (w.variant='order' or exists(select from line_plans where line_id=p_line)) then
  select i.name,s.spec,s.made_to_order into target from items i left join sku_details s on s.item_id=i.id where i.id=p_item;
  if (w.variant='order' and target.made_to_order is not true) or (w.variant='basic' and target.made_to_order is true)
    or spec_conflict(attributes(concat_ws(' ',w.standard_spec,w.raw_name,w.spec))||jsonb_strip_nulls(jsonb_build_object('kind',w.product_kind)),attributes(concat_ws(' ',target.name,target.spec)),coalesce(target.made_to_order,false)) is not null then raise exception 'WM3_VARIANT';end if;
 end if;
 if p_decision is null or p_decision not in ('ready','hold','exclude','pending') or p_qty<=0 or length(p_reason)>1500 or length(p_customer)>250 then raise exception 'WM_INVALID'; end if;
 if p_item is not null and not exists(select from items i join datasets d on d.id=i.dataset_id and d.active where i.id=p_item) then raise exception 'WM_NOT_FOUND'; end if;
 if nullif(p_method,'') is not null and (cat<>'sale' or p_method not in ('직납','화물','방문','퀵','용차','퀵·용차')) then raise exception 'WM2_METHOD'; end if;
 if p_decision='ready' and (p_qty is null or (w.stock_managed and (p_item is null or p_stock_qty is null)) or (w.pick_required and p_pick_qty is null) or (cat='sale' and (nullif(p_method,'') is null or nullif(btrim(p_customer),'') is null))) then raise exception 'WM2_INCOMPLETE'; end if;
 if p_decision in ('hold','exclude') and nullif(btrim(p_reason),'') is null then raise exception 'WM2_REASON'; end if;
 update work_lines set item_id=p_item,final_qty=p_qty,method=nullif(p_method,''),customer=btrim(coalesce(p_customer,'')),decision=p_decision,
 reason=btrim(coalesce(p_reason,'')),rev=rev+1,picked=picked and (item_id,w.pick_qty,method,customer) is not distinct from (p_item,p_pick_qty,nullif(p_method,''),btrim(coalesce(p_customer,''))),
 pick_changed=pick_changed or (picked and (item_id,w.pick_qty,method,customer) is distinct from (p_item,p_pick_qty,nullif(p_method,''),btrim(coalesce(p_customer,'')))) where id=p_line returning * into edited;
 -- Earlier documents acquire a plan only if an administrator now reviews the line.
 insert into line_plans(line_id,analysis,pick_qty,stock_qty)
 values(p_line,jsonb_build_object('line_id',w.line_key,'raw_name',w.raw_name,'raw_spec',w.spec,'raw_qty',w.read_qty,
 'standard_name',w.standard_name,'standard_spec',w.standard_spec,'variant',w.variant,'category',w.category,'pick_required',w.pick_required,
 'stock_managed',w.stock_managed,'pick_qty',w.pick_qty,'stock_qty',w.stock_qty,'resolution',w.resolution,'item_id',w.item_id,
 'match_basis',w.match_basis,'customer',w.customer,'method',w.method,'method_raw',w.method_raw),p_pick_qty,p_stock_qty)
 on conflict(line_id) do update set pick_qty=excluded.pick_qty,stock_qty=excluded.stock_qty;
 if p_remember then perform public.wm3_remember_alias(p_line,p_context);end if;
 perform event(l.document_id,p_line,'review',actor,to_jsonb(w),(select to_jsonb(x) from work_rows x where x.id=p_line));
end $$;

create or replace function public.wm2_review(p_line uuid,p_rev integer,p_item uuid,p_qty integer,p_method text,p_customer text,p_decision text,p_reason text)
returns void language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare w work_rows%rowtype;
begin
 perform require_admin();select * into strict w from work_rows where id=p_line;
 perform public.wm3_review(p_line,p_rev,p_item,p_qty,p_method,p_customer,p_decision,p_reason,
 case when w.pick_required and w.pick_qty is not distinct from w.final_qty then p_qty else w.pick_qty end,
 case when w.stock_managed and w.stock_qty is not distinct from w.final_qty then p_qty else w.stock_qty end);
end $$;

create or replace function public.wm2_pick(p_line uuid,p_rev integer,p_done boolean) returns void
language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); w work_rows%rowtype;
begin
 perform work_lock();select * into strict w from work_rows where id=p_line;
 if w.rev is distinct from p_rev or w.doc_status<>'current' then raise exception 'WM_STALE';end if;
 if w.batch_id is not null or p_done is null or not w.pick_required or coalesce(w.pick_qty,0)<=0 or w.decision in ('hold','exclude')
 or (w.item_id is null and w.resolution<>'pick_only') then raise exception 'WM2_INCOMPLETE';end if;
 update work_lines set picked=p_done,pick_changed=false,rev=rev+1 where id=p_line;
 perform event(w.document_id,p_line,'pick',actor,to_jsonb(w.picked),to_jsonb(p_done));
end $$;

create or replace function public.wm2_new_sku(p_line uuid,p_rev integer,p_sku text,p_name text,p_spec text,p_racks text[],p_ordered boolean,p_first_receipt boolean)
returns uuid language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); l work_lines%rowtype; ds uuid; result uuid; w work_rows%rowtype; sibling record; opening integer; seq integer;
begin
 perform work_lock(); l:=editable(p_line,p_rev,true);
 select * into strict w from work_rows where id=p_line;
 if not w.stock_managed then raise exception 'WM2_INCOMPLETE';end if;
 if w.resolution='order_candidate' and (not p_ordered or spec_key(p_spec)<>spec_key(w.standard_spec) or
   norm(p_name)<>norm(w.standard_name)) then raise exception 'WM3_VARIANT';end if;
 if p_name is null or p_sku is null or length(btrim(p_name)) not between 1 and 600 or length(btrim(p_sku)) not between 1 and 200 or
  length(p_spec)>1500 or cardinality(p_racks)>50 or exists(select from unnest(p_racks) r where length(r)>100 or nullif(btrim(r),'') is null)
  or p_first_receipt is null or p_ordered is null then raise exception 'WM_INVALID'; end if;
 select id into strict ds from datasets where active for update;
 if exists(select from items i left join sku_details s on i.id=s.item_id where i.dataset_id=ds and
    (lower(btrim(p_sku))=lower(coalesce(s.sku,i.name)) or (i.name=btrim(p_name) and spec_key(s.spec)=spec_key(p_spec)))) then raise exception 'WM2_SKU_EXISTS'; end if;
 opening:=case when p_first_receipt then 0 else null end;
 select coalesce(max(ordinal),0)+1 into seq from items where dataset_id=ds;
 insert into items(dataset_id,ordinal,name,racks,opening_qty,qty) values(ds,seq,btrim(p_name),coalesce(p_racks,'{}'),opening,opening) returning id into result;
 insert into sku_details(item_id,sku,spec,made_to_order) values(result,btrim(p_sku),btrim(coalesce(p_spec,'')),p_ordered);
 update work_lines set item_id=result,rev=rev+1,decision='pending',picked=false,pick_changed=picked or pick_changed where id=p_line;
 perform event(l.document_id,p_line,'new_sku',actor,to_jsonb(l.item_id),jsonb_build_object('sku',p_sku,'item_id',result,'baseline',opening));
 if w.resolution='order_candidate' then
  for sibling in select * from work_rows where id<>p_line and variant_key=w.variant_key and item_id is null and
    resolution='order_candidate' and doc_status='current' and batch_id is null loop
   update work_lines set item_id=result,rev=rev+1 where id=sibling.id;
   perform event(sibling.document_id,sibling.id,'link',actor,null,to_jsonb(result));
  end loop;
 end if;
 return result;
end $$;

create or replace function public.wm2_manual(p_item uuid,p_day date,p_category text,p_qty integer,p_request uuid,
 p_customer text default '',p_method text default null,p_direction text default null,p_note text default '',
 p_corrects bigint default null,p_related uuid default null)
returns jsonb language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); name text; result jsonb; j jsonb; original record; entry_origin text:='manual';
begin
 perform work_lock();
 if p_request is null or p_day is null or p_qty is null or p_qty<1 or length(p_note)>1500 then raise exception 'WM_INVALID'; end if;
 select i.name into strict name from items i join datasets d on d.id=i.dataset_id and d.active where i.id=p_item;
 if p_corrects is not null then
  select coalesce(a.analysis->>'category',d.category) as category,l.customer,l.method,coalesce(ref.case_id,d.case_id) case_id,e.item_id into strict original from posted_lines p left join line_plans a on a.line_id=p.line_id join entries e on e.id=p.entry_id
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

create or replace function warehouse_master.day_view(day_to_read date) returns jsonb language plpgsql stable set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare r jsonb; issues jsonb; batches jsonb; removed jsonb; mark text;
begin
 select coalesce(jsonb_agg(to_jsonb(w) order by w.name,w.external_id,w.pos),'[]') into r from work_rows w
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

create or replace function public.wm2_open_days() returns jsonb language plpgsql stable security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
begin
 perform require_admin();
 return (select coalesce(jsonb_agg(day order by day),'[]') from (
 select work_day as day from work_rows where doc_status='current' and batch_id is null and decision in ('ready','pending','hold')
 union select work_day from work_documents where status in ('unlinked','reconcile')) q);
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
 perform i.id from items i where exists(select from work_rows w where w.work_day=p_day and w.doc_status='current' and
  w.batch_id is null and w.decision='ready' and w.stock_managed and w.item_id=i.id) order by i.id for update of i;
 state:=day_view(p_day);
 if state->>'stamp'<>p_stamp then raise exception 'WM_STALE'; end if;
 if exists(select from jsonb_array_elements(state->'issues') x where not (x->>'deferred')::boolean)
  or exists(select from work_rows w where w.work_day=p_day and w.doc_status='current' and w.batch_id is null and
   (w.decision='pending' or (w.decision='ready' and ((w.stock_managed and (w.item_id is null or coalesce(w.stock_qty,0)<=0)) or (w.pick_required and coalesce(w.pick_qty,0)<=0) or w.final_qty is null or
    (w.category='sale' and (w.method is null or nullif(w.customer,'') is null)) or exists(
     select from work_documents d where d.suspected_case=w.case_id and d.status='unlinked'))))) then raise exception 'WM2_REVIEW_FIRST'; end if;
 for r in select item_id,name,qty,sum(direction::bigint*stock_qty) delta from work_rows
  where work_day=p_day and doc_status='current' and batch_id is null and decision='ready' and stock_managed group by item_id,name,qty loop
  if r.qty is null then raise exception 'WM_UNKNOWN'; end if;
  if r.qty+r.delta<0 then raise exception 'WM_SHORT' using detail=jsonb_build_object('current',r.qty,'short',-(r.qty+r.delta),'name',r.name)::text; end if;
 end loop;
 select * into last_batch from close_batches where work_day=p_day order by sequence desc limit 1;
 reviews:=jsonb_build_object('rows',state->'rows','issues',state->'issues');
 if jsonb_array_length(state->'rows')=0 and jsonb_array_length(state->'issues')=0 then raise exception 'WM2_EMPTY'; end if;
 if not exists(select from work_rows where work_day=p_day and doc_status='current' and batch_id is null and decision='ready') and
  last_batch.id is not null and not exists(
   select 1 from jsonb_array_elements(state->'rows') x where x->>'batch_id' is null and not exists(
    select from jsonb_array_elements(last_batch.reviewed->'rows') y where y->>'id'=x->>'id' and y->>'rev'=x->>'rev'))
  and state->'issues'=last_batch.reviewed->'issues' then raise exception 'WM2_EMPTY'; end if;
 insert into close_batches(id,work_day,sequence,snapshot,previous_id,approver,reviewed)
  values(p_request,p_day,coalesce(last_batch.sequence,0)+1,p_stamp,last_batch.id,auth.uid(),reviews) returning * into b;
 for r in select * from work_rows where work_day=p_day and doc_status='current' and batch_id is null and decision='ready'
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

create or replace view movement_log as
 select e.id,e.item_id,i.name,coalesce(s.sku,i.name) sku,coalesce(s.spec,'') spec,e.kind,e.amount,e.before_qty,e.after_qty,e.actor_name,e.memo,
 e.created_at,coalesce(d.work_day,(e.created_at at time zone 'Asia/Seoul')::date) work_day,
 coalesce(a.analysis->>'category',d.category,e.kind) category,coalesce(d.origin,e.source) origin,l.customer,l.method,l.read_qty,l.final_qty,d.external_id,
 d.id document_id,d.edition,d.version,b.id batch_id,b.sequence,b.approved_at,d.corrects_entry,d.related_document,
 case e.kind when 'in' then e.amount when 'out' then -e.amount when 'count' then e.after_qty-e.before_qty end signed_qty,
 case when l.method is not distinct from a.analysis->>'method' then a.analysis->>'method_raw' else l.method end method_raw
 from entries e join items i on i.id=e.item_id join datasets ds on ds.id=i.dataset_id and ds.active
 left join sku_details s on s.item_id=i.id left join posted_lines p on p.entry_id=e.id left join close_batches b on b.id=p.batch_id
 left join work_lines l on l.id=p.line_id left join work_documents d on d.id=l.document_id left join line_plans a on a.line_id=l.id;

create or replace function public.wm2_attach_file(p_doc uuid,p_sha text,p_name text) returns void
language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); d work_documents%rowtype;
begin
 perform work_lock();select * into strict d from work_documents where id=p_doc;
 if d.file_hash is not null and d.file_hash<>p_sha then raise exception 'WM2_DOCUMENT_CONFLICT';end if;
 if not exists(select from storage.objects o where o.bucket_id='warehouse-documents-v2' and o.name=p_sha) then raise exception 'WM_NOT_FOUND';end if;
 if d.file_hash is distinct from p_sha and exists(select from work_documents w where w.file_hash=p_sha and w.id<>p_doc and
  not (w.status='dismissed' and (d.payload->>'replaces' is not distinct from w.external_id or coalesce(d.payload->'supersedes_cancelled','[]') ? w.external_id))) then raise exception 'WM2_FILE_USED';end if;
 if d.file_hash is distinct from p_sha then update work_documents set file_hash=p_sha where id=d.id;end if;
 if not exists(select from work_audit a where a.document_id=d.id and a.action='file') then
  perform event(d.id,null,'file',actor,null,jsonb_build_object('name',left(p_name,250)));
 end if;
end $$;

do $$ declare f regprocedure;
begin
 for f in select p.oid::regprocedure from pg_proc p where p.pronamespace='warehouse_master'::regnamespace and
 p.proname=any(array['shipping_method','spec_key','part_kind','attributes','spec_conflict','plan_line','document_identity','saved_plan','preflight','preview_chatgpt'])
 loop execute format('revoke all on function %s from public,anon,authenticated,service_role',f);end loop;
 foreach f in array array[
 'public.wm3_preview(jsonb)'::regprocedure,'public.wm3_cancel(uuid,text)'::regprocedure,'public.wm3_remember_alias(uuid,text)'::regprocedure,
 'public.wm3_review(uuid,integer,uuid,integer,text,text,text,text,integer,integer,boolean,text)'::regprocedure]
 loop execute format('revoke all on function %s from public,anon,authenticated',f);execute format('grant execute on function %s to authenticated',f);end loop;
end $$;
revoke all on function public.wm3_preview_token(text,jsonb) from public,anon,authenticated;
grant execute on function public.wm3_preview_token(text,jsonb) to anon,authenticated;
notify pgrst,'reload schema';
commit;
