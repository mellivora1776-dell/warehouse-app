-- Confirmed order identities, draft opening balances and atomic intake.
begin;
set local search_path=warehouse_master,pg_catalog;

alter table sku_details add column order_kind text check(order_kind in ('finished','motor','part')),
 add column confirmed_key text unique;

create function warehouse_master.electric_pattern() returns text language sql immutable set search_path='' as $$
 select '(?<![0-9])([0-9]{3}(?:\s*(?:V\s*)?/\s*[0-9]{3})*)\s*(?:V\s*[/·-]?\s*|[/·-]\s*)([0-9]{2})(?![0-9])(?:\s*Hz)?'::text
$$;
create function warehouse_master.electric_parts(input text) returns text[] language sql immutable set search_path=warehouse_master,pg_catalog,pg_temp as $$
 select case when m is not null then array[regexp_replace(m[1],'[[:space:]v]+','','gi'),m[2]] end
 from (select regexp_match(input,electric_pattern(),'i') m) x
$$;
create function warehouse_master.order_spec(input text) returns text language sql immutable set search_path=warehouse_master,pg_catalog,pg_temp as $$
 select btrim(regexp_replace(case when e is null then s else
  regexp_replace(s,electric_pattern(),e[1]||'V·'||e[2]||'Hz','i') end,'[[:space:]]+',' ','g'))
 from (select btrim(coalesce(input,'')) s,electric_parts(input) e) q
$$;
create or replace function warehouse_master.spec_key(s text) returns text language sql immutable set search_path=warehouse_master,pg_catalog,pg_temp as $$
 select norm(order_spec(s))
$$;
alter function warehouse_master.attributes(text) rename to legacy_attributes;
create function warehouse_master.attributes(label text) returns jsonb language sql immutable set search_path=warehouse_master,pg_catalog,pg_temp as $$
 select legacy_attributes(label)||jsonb_strip_nulls(jsonb_build_object('voltage',e[1],'frequency',e[2],
  'housing',upper(coalesce((regexp_match(label,'([hv])\s*형','i'))[1],(regexp_match(label,'[(]([hv])[)]','i'))[1]))))
 from (select electric_parts(label) e) q
$$;

create function warehouse_master.order_model(model text, kind text) returns text language sql immutable set search_path='' as $$
 select btrim(regexp_replace(btrim(model),case when kind='motor' then '(\s+모터|\s*\(\s*모터\s*\))$'
 when kind='finished' then '(\s+완[성제]품|\s*\(\s*완[성제]품\s*\))$' else '(?!)' end,'','i'))
$$;
create function warehouse_master.order_key(ds uuid,model text,spec text,kind text) returns text language sql immutable
set search_path=warehouse_master,pg_catalog,pg_temp as $$
 -- Extract named attributes and preserve the remaining specification, including unrecognised options.
 select fingerprint(jsonb_build_array('warehouse-order/1',ds,norm(order_model(model,kind)),kind,
  electric_parts(s),a->>'material',a->>'shaft',a->>'housing',norm(trim(both ' ·,;' from
  regexp_replace(regexp_replace(regexp_replace(regexp_replace(s,electric_pattern(),' ','i'),
  '([0-9]+(?:[.][0-9]+)?)\s*[ΦφØø]|[ΦφØø]\s*([0-9]+(?:[.][0-9]+)?)',' '),
  '(?:[hv]\s*형|[(][hv][)])',' ','i'),'(주물|철판|스테인리스|스텐|알루미늄)',' ')))))
 from (select order_spec(spec) s,attributes(spec) a) q
$$;

create view order_catalog as
 select i.id,i.dataset_id,i.name,s.spec,s.sku,s.aliases,k.kind,
 coalesce(s.confirmed_key,order_key(i.dataset_id,i.name,s.spec,k.kind)) identity_key
 from items i join datasets d on d.id=i.dataset_id and d.active join sku_details s on s.item_id=i.id and s.made_to_order
 cross join lateral (select coalesce(s.order_kind,part_kind(concat_ws(' ',i.name,s.spec)),'finished') kind) k;

alter function warehouse_master.plan_line(jsonb,jsonb,text) rename to plan_line_v2;
create function warehouse_master.plan_line(j jsonb,l jsonb,origin_name text) returns jsonb language plpgsql stable
set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare
 confirmed boolean; std text:=btrim(l->>'standard_name'); spec text:=order_spec(l->>'standard_spec'); kind text:=l->>'product_kind';
 ds uuid; ident text; candidate record; result jsonb; validated jsonb:=l; err text; target uuid; action text; attrs jsonb;
begin
 if l ? 'order_confirmed' and jsonb_typeof(l->'order_confirmed')<>'boolean' then raise exception 'WM2_LINE';end if;
 confirmed:=coalesce((l->>'order_confirmed')::boolean,false);
 if not confirmed and l ? 'opening_before' then raise exception 'WM5_CONFIRM';end if;
 if not confirmed then return plan_line_v2(j,l,origin_name);end if;
 if j->>'schema_version' is distinct from '2' or l->>'variant' is distinct from 'order' or kind is null or kind not in ('motor','finished','part')
  or nullif(std,'') is null or spec='' or length(std)>600 or nullif(btrim(l->>'match_basis'),'') is null
  or (l->>'stock_managed')::boolean is false then raise exception 'WM5_CONFIRM';end if;
 if l ? 'opening_before' and l->'opening_before'<>'null' and (jsonb_typeof(l->'opening_before')<>'number'
  or l->>'opening_before' !~ '^(0|[1-9][0-9]{0,9})$' or (l->>'opening_before')::numeric>2147483647) then raise exception 'WM2_LINE';end if;
 select id into strict ds from datasets where active;
 ident:=order_key(ds,std,spec,kind);
 select oc.*,count(*) over() matches into candidate from order_catalog oc where oc.dataset_id=ds and (oc.identity_key=ident or
  (std=any(oc.aliases) and oc.kind=l->>'product_kind' and order_key(ds,std,oc.spec,l->>'product_kind')=ident)) limit 1;
 if candidate.matches>1 then err:='같은 주문 사양으로 여러 SKU가 검색됩니다. 기존 품목을 확인하세요.';
 elsif candidate.id is not null then
  if nullif(l->>'item_id','') is not null and lower(l->>'item_id')<>candidate.id::text then err:='확정 주문품과 지정한 품목 ID가 다릅니다.';end if;
  validated:=l||jsonb_build_object('item_id',candidate.id,'standard_name',candidate.name,'standard_spec',candidate.spec);
 end if;
 -- A supplied, recognised SKU or ID must agree with the complete confirmed identity.
 if nullif(btrim(l->>'sku'),'') is not null and exists(select from items i left join sku_details s on s.item_id=i.id
  where i.dataset_id=ds and (i.id::text=lower(l->>'sku') or s.sku=l->>'sku' or l->>'sku'=any(s.aliases))
  and i.id is distinct from candidate.id) then err:='지정한 SKU와 확정 주문 사양이 다릅니다.';end if;
 attrs:=attributes(concat_ws(' ',std,spec))||jsonb_build_object('kind',kind);
 if part_kind(std) is not null and part_kind(std)<>kind or exists(select from (values(l->>'raw_name'),(l->>'spec'),(std),(spec)) input(v) cross join lateral jsonb_each_text(attributes(input.v)) r
   where attrs->>r.key is distinct from r.value) then err:='원문과 확정된 모터·완성품 또는 구별 사양을 대조하세요.';end if;
 result:=plan_line_v2(j,validated,origin_name);
 if err is not null then return result||jsonb_build_object('resolution','conflict','item_id',null,'reason',err);end if;
 if result->>'resolution'='conflict' then return result;end if;
 if (result->>'stock_managed')::boolean is not true then raise exception 'WM5_CONFIRM';end if;
 if candidate.id is null and (nullif(l->>'item_id','') is not null or result->>'item_id' is not null) then
  return result||jsonb_build_object('resolution','conflict','item_id',null,'reason','주문 사양 전체가 지정한 SKU와 일치하는지 확인하세요.');
 end if;
 if candidate.id is null then
  target:=substr(ident,1,32)::uuid;action:='create';
  if exists(select from items where id=target) then raise exception 'WM5_IDENTITY';end if;
  std:=order_model(std,kind)||case when kind='motor' then ' 모터' else '' end;
 else
  target:=candidate.id;ident:=candidate.identity_key;action:='reuse';std:=candidate.name;spec:=candidate.spec;
 end if;
 return result||jsonb_build_object('resolution','matched','item_id',target,'order_action',action,'variant_key',ident,
  'standard_name',std,'standard_spec',spec,'reason',case when result->>'resolution'<>'order_candidate' then result->>'reason'
   when result->>'category'='sale' and result->>'method' is null then '출고 방식 확인 필요'
   when result->>'category'='sale' and nullif(result->>'customer','') is null then '거래처 확인 필요'
   when result->>'raw_qty' is null or result->>'stock_qty' is null or ((result->>'pick_required')::boolean and result->>'pick_qty' is null) then '수량 확인 필요'
   else coalesce(l->>'review_reason','') end,
  'opening_before',(l->>'opening_before')::integer);
end $$;

-- Only the intake transaction and explicitly scoped repairs call this private function.
create function warehouse_master.ensure_order(plan jsonb) returns uuid language plpgsql
set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare ds uuid; target uuid:=(plan->>'item_id')::uuid; model text:=plan->>'standard_name'; spec text:=plan->>'standard_spec';
 kind text:=plan->>'product_kind'; ident text; found_id uuid; seq integer;
begin
 perform work_lock();
 select id into strict ds from datasets where active for update;
 ident:=order_key(ds,model,spec,kind);
 if plan->>'variant'<>'order' or plan->>'resolution'<>'matched' or plan->>'variant_key' is distinct from ident
  or target is null or not (plan->>'stock_managed')::boolean then raise exception 'WM5_IDENTITY';end if;
 select id into found_id from order_catalog where identity_key=ident;
 if found then
  if target<>found_id then raise exception 'WM3_PREFLIGHT_CHANGED';end if;
  return found_id;
 end if;
 if target<>substr(ident,1,32)::uuid or plan->>'order_action' is distinct from 'create' then raise exception 'WM3_PREFLIGHT_CHANGED';end if;
 select coalesce(max(ordinal),0)+1 into seq from items where dataset_id=ds;
 insert into items(id,dataset_id,ordinal,name,racks,qty,opening_qty) values(target,ds,seq,model,'{}',null,null);
 insert into sku_details(item_id,sku,spec,made_to_order,order_kind,confirmed_key) values(target,'ORD-'||target::text,spec,true,kind,ident);
 return target;
end $$;

-- Shared planning, receipt comparison and approval.
create or replace function warehouse_master.plan_line_v2(j jsonb,l jsonb,origin_name text) returns jsonb
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
   select i.id,i.name,coalesce(s.spec,'') item_spec,coalesce(s.sku,i.name) item_sku,i.racks,coalesce(s.made_to_order,false) custom,coalesce(s.order_kind,part_kind(concat_ws(' ',i.name,s.spec))) stored_kind,count(*) over() matches
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
   conflict:=spec_conflict(attrs,attributes(target.name||' '||target.item_spec)||jsonb_strip_nulls(jsonb_build_object('kind',target.stored_kind)),target.custom);
   if v2 and ref is not null and not exists(select from items i where i.id=target.id and norm(i.name)=norm(raw)) and exists(
    select from items i join datasets d on d.id=i.dataset_id and d.active left join sku_details s on s.item_id=i.id
    where i.id<>target.id and (norm(i.name)=norm(raw) or s.sku=raw) and coalesce(s.made_to_order,false)=ordered) then
    issue:='원문이 다른 마스터 품목과 일치합니다.';
   end if;
   if conflict is not null or (attrs ? 'rotation' and not(attributes(target.name||' '||target.item_spec) ? 'rotation') and (ref is null or basis='')) or (ordered and not target.custom) or
    (v2 and l->>'variant'='basic' and target.custom) or
    (kind='motor' and coalesce(target.stored_kind,'finished')<>'motor') or
    (kind='finished' and target.stored_kind in ('motor','part')) or
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

create or replace function warehouse_master.product_label(product text, specification text, ordered boolean, kind text default null)
returns text language plpgsql immutable set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare
 base text:=btrim(coalesce(product,'')); extra text:=btrim(coalesce(specification,''));
 electric text:=electric_pattern();
 m text[]; voltage text; hz text; motor boolean; specs text[];
begin
 m:=electric_parts(extra||' '||base);voltage:=m[1];hz:=m[2];
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

create or replace function warehouse_master.saved_plan(doc uuid) returns jsonb language sql stable set search_path=warehouse_master,pg_catalog,pg_temp as $$
 select coalesce(jsonb_agg(coalesce(p.analysis,'{}')||case when p.analysis->>'resolution'='order_candidate' and i.id is not null then
 jsonb_build_object('resolution','matched','reason',coalesce(d.payload->'lines'->(l.pos-1)->>'review_reason',''),'standard_spec',coalesce(s.spec,''),'racks',i.racks)
 else '{}'::jsonb end||jsonb_build_object('line_id',l.line_key,'raw_name',l.raw_name,'raw_spec',l.spec,
 'raw_qty',l.read_qty,'item_id',l.item_id,'standard_name',coalesce(i.name,p.analysis->>'standard_name',l.raw_name),'method',l.method,
 'customer',l.customer,'pick_qty',case when p.line_id is not null then p.pick_qty when d.direction<0 then l.final_qty else 0 end,
 'stock_qty',case when p.line_id is not null then p.stock_qty else l.final_qty end) order by l.pos),'[]')
 from work_lines l join work_documents d on d.id=l.document_id left join line_plans p on p.line_id=l.id left join items i on i.id=l.item_id left join sku_details s on s.item_id=i.id where d.id=doc
$$;

create or replace function warehouse_master.preflight(j jsonb,origin_name text) returns jsonb
language plpgsql stable set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare ident jsonb; plans jsonb; reasons text[]:='{}'; duplicate_doc uuid; stored jsonb; line jsonb; p jsonb; collected jsonb:='[]'; stamp text;
begin
 j:=j-'preview_stamp';ident:=document_identity(j,origin_name);
 if j->>'schema_version'='2' then
  if (j-array['schema_version','document_id','case_id','version','is_revision','replaces','document_type','work_date','source_time','category','customer','method','source','lines','change_type','requester','supersedes_cancelled','preview_stamp'])<>'{}'::jsonb or (j ? 'source' and (jsonb_typeof(j->'source')<>'object' or ((j->'source')-array['kind','text','name','sha256','reply_to','message_id','issuer','note'])<>'{}'::jsonb)) then
   reasons:=array_append(reasons,'지원하지 않는 문서 또는 근거 필드입니다. 입력 명세를 확인하세요.');end if;
  if exists(select from jsonb_array_elements(j->'lines') l where (l-array['line_id','raw_name','sku','spec','qty','confidence','review_reason','item_id','standard_name','standard_spec','match_basis','context','product_kind','variant','stock_managed','pick_required','category','customer','method','remarks','packing','requester','pick_qty','stock_qty','order_confirmed','opening_before'])<>'{}'::jsonb or
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
  if p->>'order_action'='create' and ident->>'status'<>'current' then
   p:=(p-'order_action'-'opening_before')||jsonb_build_object('item_id',null,'resolution','order_candidate','reason','문서 관계를 먼저 확인하세요.');
  end if;
  if p->>'resolution'='conflict' or (j->>'schema_version'='2' and p->>'resolution'='unlinked' and (nullif(line->>'standard_name','') is not null or nullif(line->>'item_id','') is not null)) then reasons:=array_append(reasons,(p->>'line_id')||' · '||(p->>'reason'));end if;
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
  if row_plan ? 'order_action' then perform ensure_order(row_plan);end if;
  insert into work_lines(document_id,pos,line_key,raw_sku,raw_name,spec,read_qty,final_qty,item_id,customer,method,reason)
  values(doc,pos,row_plan->>'line_id',coalesce(raw->>'sku',''),row_plan->>'raw_name',row_plan->>'raw_spec',(row_plan->>'raw_qty')::int,
   (row_plan->>'raw_qty')::int,(row_plan->>'item_id')::uuid,row_plan->>'customer',row_plan->>'method',coalesce(raw->>'review_reason','')) returning id into new_line;
  insert into line_plans(line_id,analysis,pick_qty,stock_qty) values(new_line,row_plan,(row_plan->>'pick_qty')::int,(row_plan->>'stock_qty')::int);
  if row_plan ? 'order_action' then
   perform event(doc,new_line,'order_link',actor,null,jsonb_build_object('item_id',row_plan->'item_id','identity',row_plan->'variant_key',
    'confirmation',row_plan->'match_basis','action',row_plan->'order_action'));
  end if;
 end loop;
 state:='unlinked';if plan->>'status'<>'unlinked' then state:=attach_document(doc,job,actor);end if;
 verify_rows:=saved_plan(doc);
 if verify_rows is distinct from plan->'lines' or state is distinct from plan->>'status' then raise exception 'WM3_RECEIPT_MISMATCH';end if;
 return jsonb_build_object('id',doc,'status',state,'duplicate',false,'verified',true,'stock_posted',false,'stored_lines',verify_rows);
end $$;

create or replace function public.wm2_new_sku(p_line uuid,p_rev integer,p_sku text,p_name text,p_spec text,p_racks text[],p_ordered boolean,p_first_receipt boolean)
returns uuid language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare actor text:=require_admin(); l work_lines%rowtype; ds uuid; result uuid; w work_rows%rowtype; sibling record; wanted_identity text; kind text; opening integer; seq integer;
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
 kind:=coalesce(w.product_kind,part_kind(concat_ws(' ',p_name,p_spec)),'finished');
 if p_ordered then
  wanted_identity:=order_key(ds,btrim(p_name),p_spec,kind);
  if exists(select from order_catalog oc where oc.identity_key=wanted_identity) then raise exception 'WM2_SKU_EXISTS';end if;
 end if;
 if exists(select from items i left join sku_details s on i.id=s.item_id where i.dataset_id=ds and
    (lower(btrim(p_sku))=lower(coalesce(s.sku,i.name)) or (i.name=btrim(p_name) and spec_key(s.spec)=spec_key(p_spec)))) then raise exception 'WM2_SKU_EXISTS'; end if;
 opening:=case when p_first_receipt then 0 else null end;
 select coalesce(max(ordinal),0)+1 into seq from items where dataset_id=ds;
 insert into items(dataset_id,ordinal,name,racks,opening_qty,qty) values(ds,seq,btrim(p_name),coalesce(p_racks,'{}'),opening,opening) returning id into result;
 insert into sku_details(item_id,sku,spec,made_to_order,order_kind,confirmed_key)
 values(result,btrim(p_sku),btrim(coalesce(p_spec,'')),p_ordered,case when p_ordered then kind end,wanted_identity);
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
  select i.name,s.spec,s.made_to_order,s.order_kind,i.dataset_id into target from items i left join sku_details s on s.item_id=i.id where i.id=p_item;
  if w.variant='order' and w.product_kind is not null and w.item_id is distinct from p_item and
    not exists(select from order_catalog oc where oc.id=p_item and oc.kind=w.product_kind and
     (oc.identity_key=order_key(oc.dataset_id,w.standard_name,w.standard_spec,w.product_kind) or
     (w.standard_name=any(oc.aliases) and spec_key(w.standard_spec)=spec_key(oc.spec))))
   then raise exception 'WM3_VARIANT';end if;
  if (w.variant='order' and target.made_to_order is not true) or (w.variant='basic' and target.made_to_order is true)
    or spec_conflict(attributes(concat_ws(' ',w.standard_spec,w.raw_name,w.spec))||jsonb_strip_nulls(jsonb_build_object('kind',w.product_kind)),attributes(concat_ws(' ',target.name,target.spec))||jsonb_strip_nulls(jsonb_build_object('kind',target.order_kind)),coalesce(target.made_to_order,false)) is not null then raise exception 'WM3_VARIANT';end if;
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

-- Prior stock is review information until the administrator approves the first movement.
create table order_opening_reviews (
 id bigint generated always as identity primary key, item_id uuid not null references items,
 work_day date not null, line_id uuid not null references work_lines,
 quantity integer not null check(quantity>=0), actor uuid not null references members(user_id),
 actor_name text not null, created_at timestamptz not null default clock_timestamp()
);
create index wm5_opening_item_day on order_opening_reviews(item_id,work_day,id desc);
alter table order_opening_reviews enable row level security;
revoke all on order_opening_reviews from public,anon,authenticated,service_role;

create view order_day_balances as
 with eligible as (
  select w.id,w.item_id,w.work_day,w.direction,(a.analysis->>'opening_before')::int as stated
  from work_rows w left join line_plans a on a.line_id=w.id
  where w.variant='order' and w.item_id is not null and w.qty is null and w.stock_managed and w.doc_status='current'
  and w.batch_id is null and w.decision in ('ready','pending') and not exists(
   select from work_documents d where d.suspected_case=w.case_id and d.status='unlinked' and d.deferred)
 ), per_day as (
  select item_id,work_day,bool_or(direction=1) has_in,bool_or(direction=-1) has_out,min(stated) low,max(stated) high
  from eligible group by item_id,work_day
 ) select p.item_id,p.work_day,coalesce(last.quantity,case when low=high then low end) quantity,last.id review_id,
 case when last.id is null and low<>high then '자료마다 첫 거래 전 재고 수량이 다릅니다. 수량을 확인하세요.'
 when has_out and not has_in then '출고 전 재고 수량 확인' when has_in and not has_out then '입고 전 재고 수량 확인'
 else '첫 거래 전 재고 수량 확인' end question
 from per_day p left join lateral(select r.id,r.quantity from order_opening_reviews r join eligible e on e.id=r.line_id and e.item_id=r.item_id
  where r.item_id=p.item_id and r.work_day=p.work_day order by r.id desc limit 1) last on true;

create function public.wm5_set_opening(p_line uuid,p_stamp text,p_qty integer) returns void
language plpgsql security definer set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare who text:=require_admin(); w work_rows%rowtype;
begin
 perform work_lock();select * into strict w from work_rows where id=p_line;
 if p_qty is null or p_qty<0 then raise exception 'WM_INVALID';end if;
 if w.variant<>'order' or w.item_id is null or w.qty is not null or w.batch_id is not null or w.doc_status<>'current' or not w.stock_managed or w.decision not in ('pending','ready')
  or exists(select from work_documents d where d.suspected_case=w.case_id and d.status='unlinked' and d.deferred)
  or not exists(select from order_day_balances b where b.item_id=w.item_id and b.work_day=w.work_day)
  or day_view(w.work_day)->>'stamp' is distinct from p_stamp then raise exception 'WM_STALE';end if;
 insert into order_opening_reviews(item_id,work_day,line_id,quantity,actor,actor_name) values(w.item_id,w.work_day,w.id,p_qty,auth.uid(),who);
 perform event(w.document_id,w.id,'opening_review',who,null,jsonb_build_object('item_id',w.item_id,'before_first',p_qty));
end $$;

-- Owner-only repair for an explicitly identified, unchanged set of confirmed candidate rows.
create function warehouse_master.link_confirmed_orders(p_day date,p_expected jsonb,p_actor text) returns jsonb
language plpgsql set search_path=warehouse_master,pg_catalog,pg_temp as $$
declare expected jsonb; l work_lines%rowtype; d work_documents%rowtype; original line_plans%rowtype;
 proposal jsonb; target uuid; links jsonb:='[]';
begin
 perform work_lock();
 if nullif(btrim(p_actor),'') is null or p_day is null or jsonb_typeof(p_expected) is distinct from 'array' then raise exception 'WM_INVALID';end if;
 if jsonb_array_length(p_expected) not between 1 and 200 or exists(select from jsonb_array_elements(p_expected) e group by e->>'id' having count(*)>1)
 then raise exception 'WM_INVALID';end if;
 for expected in select value from jsonb_array_elements(p_expected) loop
  select * into strict l from work_lines where id=(expected->>'id')::uuid for update;
  select * into strict d from work_documents where id=l.document_id;
  select * into strict original from line_plans where line_id=l.id;
  if d.work_day<>p_day or d.status<>'current' or l.decision<>'pending' or d.id::text is distinct from expected->>'document_id'
   or md5((to_jsonb(l)-'item_id'-'rev')::text) is distinct from expected->>'line_hash'
   or md5(to_jsonb(original)::text) is distinct from expected->>'analysis_hash'
   or original.analysis->>'resolution' is distinct from 'order_candidate'
   or exists(select from work_rows w where w.id=l.id and w.batch_id is not null) then raise exception 'WM_STALE';end if;
  proposal:=plan_line(d.payload,d.payload->'lines'->(l.pos-1)||jsonb_build_object('order_confirmed',true),d.origin);
  if proposal->>'resolution'<>'matched' or not(proposal ? 'order_action') then raise exception 'WM5_CONFIRM';end if;
  target:=ensure_order(proposal);
  if l.item_id is null and l.rev=(expected->>'rev')::integer then
   update work_lines set item_id=target,rev=rev+1 where id=l.id;
   perform event(d.id,l.id,'order_link',p_actor,null,jsonb_build_object('item_id',target,'identity',proposal->'variant_key','confirmation',proposal->'match_basis','action',proposal->'order_action'));
  elsif l.item_id is distinct from target or l.rev is distinct from ((expected->>'rev')::integer+1) then raise exception 'WM_STALE';end if;
  links:=links||jsonb_build_array(jsonb_build_object('line_id',l.id,'item_id',target,'action',proposal->>'order_action'));
 end loop;
 return links;
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
 when w.pick_changed and w.decision='pending' then '이미 준비한 지시의 내용이 달라졌습니다. 변경된 준비 수량을 확인하세요.'
 when w.decision='pending' and exists(select from work_documents prev join work_lines l on l.document_id=prev.id
   where prev.case_id=w.case_id and prev.edition=w.edition-1 and prev.status='previous' and l.line_key=w.line_key and l.decision in ('exclude','hold'))
 then '이전 지시에서 보류·제외했던 행이 변경됐습니다. 새 수량을 확인하세요.'
 when w.decision='pending' and nullif(w.reason,'') is not null then w.reason
 else '' end check_reason,bal.quantity opening_balance,bal.question opening_question,bal.review_id opening_review
 from work_rows w left join order_day_balances bal on bal.item_id=w.item_id and bal.work_day=w.work_day
 left join catalog_items c on c.id=w.item_id
 left join lateral(select * from record_amendments where entry_id=w.entry_id or nonstock_line=w.id order by revision desc limit 1) a on true;

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
 for r in select item_id,name,coalesce(qty,opening_balance) qty,sum(direction::bigint*stock_qty) delta from daily_rows
  where work_day=p_day and doc_status='current' and batch_id is null and decision in ('pending','ready') and not related_hold and check_reason='' and stock_managed group by item_id,name,qty,opening_balance loop
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
 -- Establish only explicitly confirmed new-order balances in this same transaction.
 for r in select distinct w.item_id,w.opening_balance from daily_rows w
  where w.work_day=p_day and w.doc_status='current' and w.batch_id is null and w.decision in ('pending','ready')
  and not w.related_hold and w.check_reason='' and w.stock_managed and w.qty is null and w.opening_balance is not null loop
  update items set qty=r.opening_balance,opening_qty=r.opening_balance,revision=revision+1 where id=r.item_id and qty is null;
 end loop;
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

revoke all on order_catalog,order_day_balances from public,anon,authenticated,service_role;
do $$ declare f regprocedure;
begin
 for f in select p.oid::regprocedure from pg_proc p where p.pronamespace='warehouse_master'::regnamespace
 and p.proname=any(array['electric_pattern','electric_parts','order_spec','order_key','order_model','legacy_attributes',
 'attributes','plan_line_v2','plan_line','ensure_order','link_confirmed_orders']) loop
  execute format('revoke all on function %s from public,anon,authenticated,service_role',f);
 end loop;
end $$;
revoke all on function public.wm5_set_opening(uuid,text,integer) from public,anon,authenticated,service_role;
grant execute on function public.wm5_set_opening(uuid,text,integer) to authenticated;
notify pgrst,'reload schema';
commit;
