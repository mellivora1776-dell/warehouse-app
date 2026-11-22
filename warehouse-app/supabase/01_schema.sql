-- One-time migration. Schema ownership stays with the SQL Editor database owner.
begin;
create schema warehouse_master;
revoke all on schema warehouse_master from public, anon, authenticated;
set local search_path = warehouse_master, pg_catalog;
create table members (
  user_id uuid primary key default gen_random_uuid(),
  display_name text not null check (char_length(display_name) between 1 and 60),
  pin_digest bytea not null unique,
  enabled boolean not null default true,
  role text not null check (role in ('admin','staff'))
);
create unique index one_warehouse_admin on members (role) where role = 'admin';
create table datasets (
  id uuid primary key default gen_random_uuid(),
  digest text unique not null check (digest ~ '^[a-f0-9]{64}$'),
  source_file text not null,
  row_count integer not null check (row_count > 0),
  verified_at timestamptz,
  active boolean not null default false,
  check (not active or verified_at is not null)
);
create unique index one_active_dataset on datasets (active) where active;
create table items (
  id uuid primary key default gen_random_uuid(),
  dataset_id uuid not null references datasets,
  ordinal integer not null check (ordinal > 0),
  name text not null check (btrim(name) <> ''),
  racks text[] not null,
  opening_qty integer check (opening_qty >= 0),
  qty integer check (qty >= 0),
  revision bigint not null default 0,
  unique (dataset_id, ordinal)
);
create table entries (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default clock_timestamp(),
  item_id uuid not null references items,
  kind text not null check (kind in ('opening','in','out','count')),
  amount integer,
  before_qty integer,
  after_qty integer,
  actor_id uuid,
  actor_name text not null,
  memo text not null default '',
  source text not null,
  request_id uuid unique,
  base_revision bigint,
  check (case when kind = 'opening' then request_id is null and source='excel'
      else request_id is not null and actor_id is not null and base_revision is not null
        and amount is not null and after_qty is not null and source='manual' end)
);
create index entries_by_item on entries (item_id,id desc);
create unique index one_opening on entries(item_id) where kind='opening';
-- Private tables have no API grants or RLS write policies. Only the narrowly
-- scoped definer functions below can read or mutate data on behalf of a user.
alter table members enable row level security;
alter table datasets enable row level security;
alter table items enable row level security;
alter table entries enable row level security;
revoke all on all tables in schema warehouse_master from public, anon, authenticated;
revoke all on all sequences in schema warehouse_master from public, anon, authenticated;

create function warehouse_master.member_role() returns text
language plpgsql stable set search_path = '' as $$
declare r text;
begin
  select role into r from warehouse_master.members where user_id=auth.uid() and enabled;
  if r is null then raise exception 'WM_APPROVAL' using errcode='42501'; end if;
  return r;
end $$;
create function warehouse_master.norm(s text) returns text
language sql immutable strict set search_path = '' as $$
 select lower(regexp_replace(s, '[[:space:]‐‑‒–—−-]+', '', 'g'))
$$;
create function warehouse_master.matches(i warehouse_master.items, q text) returns boolean
language sql immutable set search_path = '' as $$
 select q='' or strpos(warehouse_master.norm(i.name),q)>0 or exists (
   select from unnest(i.racks) r where strpos(warehouse_master.norm(r),q)>0
 )
$$;
create function public.wm_profile() returns jsonb
language sql stable security definer set search_path='' as $$
 select jsonb_build_object('role',warehouse_master.member_role(),
   'name',(select display_name from warehouse_master.members where user_id=auth.uid()),
   'ready',exists(select from warehouse_master.datasets where active))
$$;
create function public.wm_items(p_query text default '',p_after integer default 0) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare q text:=warehouse_master.norm(coalesce(p_query,'')); result jsonb;
begin
  perform warehouse_master.member_role();
  with found as materialized (
    select i.id,i.name,i.qty,i.ordinal from warehouse_master.items i
    join warehouse_master.datasets d on d.id=i.dataset_id and d.active
    where warehouse_master.matches(i,q)
  ), page as (select * from found where ordinal>p_after order by ordinal limit 100)
  select jsonb_build_object('total',(select count(*) from found),
    'rows',coalesce(jsonb_agg(to_jsonb(page) order by ordinal),'[]'::jsonb),
    'more',exists(select from found where ordinal>(select max(ordinal) from page)))
    into result from page;
  return result;
end $$;
create function public.wm_item(p_item uuid) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  perform warehouse_master.member_role();
  select jsonb_build_object('id',i.id,'name',i.name,'qty',i.qty,'revision',i.revision,'racks',i.racks)
  into result from warehouse_master.items i join warehouse_master.datasets d
  on d.id=i.dataset_id and d.active where i.id=p_item;
  if result is null then raise exception 'WM_NOT_FOUND'; end if;
  return result;
end $$;
create function public.wm_history(p_item uuid default null,p_query text default '',p_kind text default '',
 p_before bigint default null) returns jsonb
language plpgsql stable security definer set search_path='' as $$
declare result jsonb;
begin
  perform warehouse_master.member_role();
  with found as (
    select e.id,e.created_at,i.name,i.id as item_id,e.kind,e.amount,e.before_qty,e.after_qty,
      e.actor_name,e.memo,e.source from warehouse_master.entries e
    join warehouse_master.items i on i.id=e.item_id
    join warehouse_master.datasets d on d.id=i.dataset_id and d.active
    where (p_item is null or i.id=p_item) and (p_kind='' or e.kind=p_kind)
      and (p_before is null or e.id<p_before)
      and warehouse_master.matches(i,warehouse_master.norm(coalesce(p_query,'')))
    order by e.id desc limit 51
  ), page as (select * from found order by id desc limit 50)
  select jsonb_build_object('rows',coalesce(jsonb_agg(to_jsonb(page) order by id desc),'[]'::jsonb),
    'more',(select count(*)>50 from found)) into result from page;
  return result;
end $$;

-- One trusted entry point for all manual mutations. Clients never send the
-- resulting balance, actor, timestamp or source.
create function public.wm_change(p_item uuid,p_kind text,p_amount integer,p_memo text,
 p_revision bigint,p_request uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare i warehouse_master.items%rowtype; old warehouse_master.entries%rowtype;
  uid uuid:=auth.uid(); label text; next_qty bigint; entry_id bigint;
  note text:=btrim(coalesce(p_memo,''));
begin
  if warehouse_master.member_role()<>'admin' then raise exception 'WM_READ_ONLY' using errcode='42501'; end if;
  if p_request is null or p_revision is null or p_revision<0 or p_kind is null or
     p_kind not in ('in','out','count') or p_amount is null or p_amount<0 or
     (p_kind<>'count' and p_amount=0) or char_length(note)>1000 then
    raise exception 'WM_INVALID';
  end if;
  select x.* into i from warehouse_master.items x join warehouse_master.datasets d
    on d.id=x.dataset_id and d.active where x.id=p_item for update of x;
  if not found then raise exception 'WM_NOT_FOUND'; end if;
  select * into old from warehouse_master.entries where request_id=p_request;
  if found then
    if (old.actor_id,old.item_id,old.kind,old.amount,old.memo,old.base_revision)
       is distinct from (uid,p_item,p_kind,p_amount,note,p_revision) then raise exception 'WM_REQUEST_MISMATCH'; end if;
    return jsonb_build_object('entry',old.id,'after',old.after_qty);
  end if;
  if i.revision<>p_revision then raise exception 'WM_STALE'; end if;
  if i.qty is null and p_kind<>'count' then raise exception 'WM_UNKNOWN'; end if;
  next_qty:=case p_kind when 'in' then i.qty::bigint+p_amount
    when 'out' then i.qty::bigint-p_amount else p_amount end;
  if next_qty<0 then raise exception 'WM_SHORT' using detail=jsonb_build_object('current',i.qty,'short',-next_qty)::text; end if;
  if next_qty>2147483647 then raise exception 'WM_LIMIT'; end if;
  select display_name into strict label from warehouse_master.members where user_id=uid and enabled;
  insert into warehouse_master.entries(item_id,kind,amount,before_qty,after_qty,actor_id,actor_name,
    memo,source,request_id,base_revision) values(i.id,p_kind,p_amount,i.qty,next_qty,uid,label,
    note,'manual',p_request,p_revision) returning id into entry_id;
  update warehouse_master.items set qty=next_qty, revision=revision+1 where id=i.id;
  return jsonb_build_object('entry',entry_id,'after',next_qty);
end $$;
revoke all on all functions in schema warehouse_master from public,anon,authenticated;
do $$ declare f regprocedure;
begin
  foreach f in array array[
    'public.wm_profile()'::regprocedure,'public.wm_items(text,integer)'::regprocedure,
    'public.wm_item(uuid)'::regprocedure,'public.wm_history(uuid,text,text,bigint)'::regprocedure,
    'public.wm_change(uuid,text,integer,text,bigint,uuid)'::regprocedure
  ] loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to authenticated',f);
  end loop;
end $$;
notify pgrst, 'reload schema';
commit;
