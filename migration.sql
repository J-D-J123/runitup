-- Run Club: groups migration. Paste into the Supabase SQL editor and run once.

-- 1. Groups. The code is the secret in the invite link (12 random hex chars).
create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  code text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
  name text not null check (char_length(name) between 1 and 60),
  created_at timestamptz not null default now()
);

-- 2. Tie availability rows to a group.
--    Rows from before this migration keep group_id = null and are never shown.
alter table public.availability
  add column if not exists group_id uuid references public.groups(id) on delete cascade;
alter table public.availability drop constraint if exists availability_name_day_hour_key;
alter table public.availability
  add constraint availability_group_name_day_hour_key unique (group_id, name, day, hour);

-- 3. Lock the tables down: no direct anon access, only the functions below.
alter table public.groups enable row level security;
alter table public.availability enable row level security;
do $$
declare p record;
begin
  for p in select policyname, tablename from pg_policies
           where schemaname = 'public' and tablename in ('groups', 'availability') loop
    execute format('drop policy %I on public.%I', p.policyname, p.tablename);
  end loop;
end $$;

-- 4. Functions (security definer = run with table access on behalf of anon).
create or replace function public.create_group(p_name text)
returns table (code text, name text)
language plpgsql security definer set search_path = public as $$
begin
  p_name := trim(p_name);
  if p_name is null or char_length(p_name) not between 1 and 60 then
    raise exception 'Group name must be 1-60 characters';
  end if;
  return query insert into groups (name) values (p_name) returning groups.code, groups.name;
end $$;

create or replace function public.get_group(p_code text)
returns text
language sql security definer set search_path = public as $$
  select name from groups where code = lower(p_code);
$$;

-- One row per slot that has anyone free: who is free, grouped for the heatmap.
create or replace function public.get_group_availability(p_code text, p_from date, p_to date)
returns table (day date, hour smallint, names text[])
language sql security definer set search_path = public as $$
  select a.day, a.hour, array_agg(a.name order by a.name)
  from availability a join groups g on g.id = a.group_id
  where g.code = lower(p_code) and a.day between p_from and p_to
  group by a.day, a.hour;
$$;

create or replace function public.get_my_slots(p_code text, p_name text, p_from date, p_to date)
returns table (day date, hour smallint)
language sql security definer set search_path = public as $$
  select a.day, a.hour
  from availability a join groups g on g.id = a.group_id
  where g.code = lower(p_code) and a.name = lower(trim(p_name))
    and a.day between p_from and p_to;
$$;

-- Replace one person's slots for the window, atomically.
-- p_slots looks like [{"day":"2026-10-24","hour":7}, ...]
create or replace function public.save_availability(
  p_code text, p_name text, p_from date, p_to date, p_slots jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare gid uuid; n text := lower(regexp_replace(trim(p_name), '\s+', ' ', 'g'));
begin
  select id into gid from groups where code = lower(p_code);
  if gid is null then raise exception 'Group not found'; end if;
  if n is null or char_length(n) not between 1 and 40 then
    raise exception 'Name must be 1-40 characters';
  end if;
  if p_to - p_from > 14 then raise exception 'Window too large'; end if;

  delete from availability
   where group_id = gid and name = n and day between p_from and p_to;

  insert into availability (group_id, name, day, hour)
  select gid, n, s.day, s.hour
  from jsonb_to_recordset(p_slots) as s(day date, hour smallint)
  where s.day between p_from and p_to and s.hour between 0 and 23
  on conflict do nothing;
end $$;

revoke all on function public.create_group, public.get_group, public.get_group_availability,
  public.get_my_slots, public.save_availability from public;
grant execute on function public.create_group, public.get_group, public.get_group_availability,
  public.get_my_slots, public.save_availability to anon;
