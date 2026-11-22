begin;
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create table warehouse_master.pin_secret (
 singleton boolean primary key default true check(singleton), pepper bytea not null
);
insert into warehouse_master.pin_secret(pepper) values(extensions.gen_random_bytes(32));
create table warehouse_master.login_limits (
 bucket text primary key, window_at timestamptz not null, attempts integer not null
);
alter table warehouse_master.pin_secret enable row level security;
alter table warehouse_master.login_limits enable row level security;
revoke all on warehouse_master.pin_secret,warehouse_master.login_limits from public,anon,authenticated;
create function warehouse_master.pin_digest(pin text) returns bytea language sql stable set search_path='' as $$
 select extensions.hmac(convert_to(pin,'UTF8'),pepper,'sha256') from warehouse_master.pin_secret
$$;
create function warehouse_master.issue(label text, member_type text) returns text
language plpgsql set search_path='' as $$
declare pin text; key bytea;
begin
 if member_type not in ('admin','staff') or label is null or char_length(btrim(label)) not between 1 and 60 then raise exception 'WM_INVALID'; end if;
 loop
   pin:=lpad(((('x'||encode(extensions.gen_random_bytes(4),'hex'))::bit(32)::bigint)%100000000)::text,8,'0');
   key:=warehouse_master.pin_digest(pin);
   exit when not exists(select from warehouse_master.members where pin_digest=key);
 end loop;
 insert into warehouse_master.members(display_name,role,pin_digest) values(btrim(label),member_type,key);
 return pin;
end $$;
create function public.wm_staff_list() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
 if warehouse_master.member_role()<>'admin' then raise exception 'WM_READ_ONLY' using errcode='42501'; end if;
 return (select coalesce(jsonb_agg(jsonb_build_object('id',user_id,'name',display_name) order by display_name,user_id),'[]'::jsonb)
   from warehouse_master.members where role='staff' and enabled);
end $$;
create function public.wm_issue_staff(p_name text) returns text language plpgsql security definer set search_path='' as $$
begin
 if warehouse_master.member_role()<>'admin' then raise exception 'WM_READ_ONLY' using errcode='42501'; end if;
 return warehouse_master.issue(p_name,'staff');
end $$;
create function public.wm_revoke_staff(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 if warehouse_master.member_role()<>'admin' then raise exception 'WM_READ_ONLY' using errcode='42501'; end if;
 update warehouse_master.members set enabled=false where user_id=p_id and role='staff';
end $$;
-- Only the Vercel server may exchange a PIN. Limit failures across instances.
create function public.wm_pin_check(p_pin text,p_client text) returns jsonb
language plpgsql security definer set search_path='' as $$
declare b text; row_id uuid; n integer; buckets text[]:=array['global','ip/'||p_client]; now_at timestamptz:=clock_timestamp();
begin
 if p_client is null or char_length(p_client) not between 1 and 128 then return '{"invalid":true}'::jsonb; end if;
 delete from warehouse_master.login_limits where window_at<now_at-interval '1 day';
 foreach b in array buckets loop
  insert into warehouse_master.login_limits(bucket,window_at,attempts) values(b,now_at,0)
   on conflict(bucket) do update set attempts=case when warehouse_master.login_limits.window_at<now_at-interval '10 minutes' then 0 else warehouse_master.login_limits.attempts end,
    window_at=case when warehouse_master.login_limits.window_at<now_at-interval '10 minutes' then now_at else warehouse_master.login_limits.window_at end
   returning attempts into n;
  if n >= (case when b='global' then 150 else 10 end) then return '{"limited":true}'::jsonb; end if;
 end loop;
 if p_pin ~ '^[0-9]{8}$' then
  select user_id into row_id from warehouse_master.members where pin_digest=warehouse_master.pin_digest(p_pin) and enabled;
 end if;
 if row_id is null then
  update warehouse_master.login_limits set attempts=attempts+1 where bucket=any(buckets);
  return '{"invalid":true}'::jsonb;
 end if;
 return jsonb_build_object('id',row_id);
end $$;
revoke all on all functions in schema warehouse_master from public,anon,authenticated;
revoke all on function public.wm_pin_check(text,text) from public,anon,authenticated;
grant execute on function public.wm_pin_check(text,text) to service_role;
revoke all on function public.wm_staff_list(),public.wm_issue_staff(text),public.wm_revoke_staff(uuid) from public,anon,authenticated;
grant execute on function public.wm_staff_list(),public.wm_issue_staff(text),public.wm_revoke_staff(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
