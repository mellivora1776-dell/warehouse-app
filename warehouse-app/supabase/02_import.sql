begin;
-- These functions are available only to the database owner (SQL Editor).
create function warehouse_master.stage(p_digest text,p_file text,p_rows jsonb) returns uuid
language plpgsql set search_path='' as $$
declare batch uuid; actual jsonb; n integer:=jsonb_array_length(p_rows);
begin
  if n is null or n=0 then raise exception '빈 파일입니다.'; end if;
  insert into warehouse_master.datasets(digest,source_file,row_count) values(p_digest,p_file,n) returning id into batch;
  insert into warehouse_master.items(dataset_id,ordinal,name,racks,opening_qty,qty)
  select batch,r.ord,r.obj->>'name',array(select jsonb_array_elements_text(r.obj->'racks')),
    (r.obj->>'qty')::integer,(r.obj->>'qty')::integer
  from jsonb_array_elements(p_rows) with ordinality r(obj,ord);
  insert into warehouse_master.entries(item_id,kind,amount,after_qty,actor_name,source)
    select id,'opening',opening_qty,opening_qty,'엑셀 가져오기','excel'
    from warehouse_master.items where dataset_id=batch order by ordinal;
  select jsonb_agg(jsonb_build_object('name',i.name,'racks',i.racks,'qty',i.qty) order by i.ordinal)
    into actual from warehouse_master.items i join warehouse_master.entries e
    on e.item_id=i.id and e.kind='opening' and e.after_qty is not distinct from i.opening_qty
    where i.dataset_id=batch and i.qty is not distinct from i.opening_qty;
  if actual is distinct from p_rows then raise exception '시작 수량·품목·랙 또는 순서가 원본과 일치하지 않습니다.'; end if;
  update warehouse_master.datasets set verified_at=clock_timestamp() where id=batch;
  return batch;
end $$;
create function warehouse_master.activate(p_digest text) returns void
language plpgsql set search_path='' as $$
begin
  lock table warehouse_master.datasets in exclusive mode;
  if exists(select from warehouse_master.datasets where active and digest=p_digest) then return; end if;
  if exists(select from warehouse_master.datasets where active) then raise exception '이미 운영 중인 재고가 있습니다.'; end if;
  update warehouse_master.datasets set active=true where digest=p_digest and verified_at is not null;
  if not found then raise exception '검증된 적재본을 찾지 못했습니다.'; end if;
end $$;

revoke all on all functions in schema warehouse_master from public,anon,authenticated;
commit;
