-- Run this once in Supabase: SQL Editor -> New query -> paste -> Run

create table if not exists public.availability (
  id bigint generated always as identity primary key,
  name text not null check (char_length(name) between 1 and 40),
  day date not null,
  hour smallint not null check (hour between 0 and 23),
  created_at timestamptz not null default now(),
  unique (name, day, hour)
);

alter table public.availability enable row level security;

-- Anyone with the link can view, add and remove slots (fine for a friends-only site)
create policy "anyone can read"   on public.availability for select to anon using (true);
create policy "anyone can add"    on public.availability for insert to anon with check (true);
create policy "anyone can remove" on public.availability for delete to anon using (true);
