-- BASELINE (already applied to the live project by hand). Idempotent. Do NOT run `supabase db push` until the history is repaired:
--   supabase migration repair --status applied 20261102120000

-- =====================================================================
-- VIVEDHA INFRA : live customer reviews (Supabase / PostgreSQL)
-- Run once in Supabase > SQL Editor. Safe to re-run.
-- Security model
--   * Visitors (role "anon") can only READ published reviews and call
--     submit_review(). They have no INSERT/UPDATE/DELETE on the table.
--   * submit_review() validates, strips HTML, rate-limits per IP hash,
--     rejects duplicates, and holds spam-like text for moderation.
--   * Admins (rows in review_admins) can read everything and
--     hide / publish / delete through Row Level Security.
--   * Never put the service_role key in the website. Use only the
--     project URL and the public anon key.
-- =====================================================================

create table if not exists public.reviews (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  name         text not null check (char_length(name) between 2 and 60),
  rating       smallint not null check (rating between 1 and 5),
  body         text not null check (char_length(body) between 20 and 600),
  project_type text check (project_type is null or char_length(project_type) <= 60),
  project_ref  text check (project_ref  is null or char_length(project_ref)  <= 80),
  status       text not null default 'held' check (status in ('published','held','hidden'))
);
create index if not exists reviews_status_created_idx on public.reviews (status, created_at desc);

-- private anti-abuse data, never readable by visitors
create table if not exists public.review_meta (
  review_id   uuid primary key references public.reviews(id) on delete cascade,
  created_at  timestamptz not null default now(),
  ip_hash     text not null,
  flag_reason text
);
create index if not exists review_meta_ip_idx on public.review_meta (ip_hash, created_at desc);

create table if not exists public.review_admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

alter table public.reviews       enable row level security;
alter table public.review_meta   enable row level security;
alter table public.review_admins enable row level security;

create or replace function public.is_review_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.review_admins a where a.user_id = auth.uid());
$$;

-- privileges: start from nothing, then grant the minimum
revoke all on public.reviews, public.review_meta, public.review_admins from anon, authenticated;
grant select on public.reviews to anon, authenticated;
grant update (status) on public.reviews to authenticated;
grant delete on public.reviews to authenticated;
grant select on public.review_meta, public.review_admins to authenticated;

drop policy if exists "public reads published"  on public.reviews;
drop policy if exists "admins read all"         on public.reviews;
drop policy if exists "admins set status"       on public.reviews;
drop policy if exists "admins delete"           on public.reviews;
drop policy if exists "admins read meta"        on public.review_meta;
drop policy if exists "read own admin row"      on public.review_admins;

create policy "public reads published" on public.reviews for select to anon, authenticated using (status = 'published');
create policy "admins read all"        on public.reviews for select to authenticated using (public.is_review_admin());
create policy "admins set status"      on public.reviews for update to authenticated using (public.is_review_admin()) with check (public.is_review_admin());
create policy "admins delete"          on public.reviews for delete to authenticated using (public.is_review_admin());
create policy "admins read meta"       on public.review_meta for select to authenticated using (public.is_review_admin());
create policy "read own admin row"     on public.review_admins for select to authenticated using (user_id = auth.uid());

-- the only way visitors can add a review
create or replace function public.submit_review(
  p_name text, p_rating integer, p_body text,
  p_project_type text default null, p_project_ref text default null, p_hp text default null
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_name text; v_body text; v_pt text; v_pr text;
  v_ip text; v_hash text; v_status text := 'published'; v_reason text; v_id uuid;
  v_letters text; v_caps int;
begin
  -- honeypot: real visitors never fill this hidden field
  if coalesce(p_hp, '') <> '' then return 'held'; end if;

  -- sanitise: strip tags, control characters, collapse whitespace
  v_name := btrim(regexp_replace(regexp_replace(regexp_replace(coalesce(p_name,''), '<[^>]*>', '', 'g'), '[[:cntrl:]]', ' ', 'g'), '\s+', ' ', 'g'));
  v_body := btrim(regexp_replace(regexp_replace(coalesce(p_body,''), '<[^>]*>', '', 'g'), '[\x00-\x08\x0B\x0C\x0E-\x1F]', '', 'g'));
  v_pt   := nullif(btrim(regexp_replace(regexp_replace(coalesce(p_project_type,''), '<[^>]*>', '', 'g'), '[[:cntrl:]]', ' ', 'g')), '');
  v_pr   := nullif(btrim(regexp_replace(regexp_replace(coalesce(p_project_ref,''),  '<[^>]*>', '', 'g'), '[[:cntrl:]]', ' ', 'g')), '');

  if char_length(v_name) < 2 or char_length(v_name) > 60 then raise exception 'invalid_name'; end if;
  if p_rating is null or p_rating < 1 or p_rating > 5      then raise exception 'invalid_rating'; end if;
  if char_length(v_body) < 20 or char_length(v_body) > 600 then raise exception 'invalid_body'; end if;
  if v_pt is not null and char_length(v_pt) > 60 then raise exception 'invalid_project_type'; end if;
  if v_pr is not null and char_length(v_pr) > 80 then raise exception 'invalid_project_ref'; end if;

  -- abuse prevention: hashed IP, max 1 per minute and 3 per hour, no duplicates
  v_ip   := coalesce(nullif(btrim(split_part(coalesce(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ''), ',', 1)), ''), 'unknown');
  v_hash := encode(sha256(convert_to('vivedha-reviews:' || v_ip, 'UTF8')), 'hex');
  if exists (select 1 from public.review_meta where ip_hash = v_hash and created_at > now() - interval '60 seconds')
     or (select count(*) from public.review_meta where ip_hash = v_hash and created_at > now() - interval '1 hour') >= 3 then
    raise exception 'rate_limited';
  end if;
  if exists (select 1 from public.reviews where lower(body) = lower(v_body)) then raise exception 'duplicate'; end if;

  -- spam / abuse heuristics: flagged text is held for moderation, not published
  v_letters := regexp_replace(v_body, '[^A-Za-z]', '', 'g');
  v_caps    := char_length(regexp_replace(v_letters, '[^A-Z]', '', 'g'));
  if v_body ~* '(https?://|www\.|[a-z0-9-]+\.(com|net|org|in|io|xyz|ru|cn|info|biz)(/|\b))' or v_name ~* '(https?://|www\.)' then
    v_status := 'held'; v_reason := 'contains link';
  elsif v_body ~* '([a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|(\+?\d[\s-]?){10,})' then
    v_status := 'held'; v_reason := 'contains email or phone number';
  elsif v_body ~* '(.)\1{6,}' then
    v_status := 'held'; v_reason := 'repeated characters';
  elsif char_length(v_letters) > 30 and v_caps::numeric / char_length(v_letters) > 0.7 then
    v_status := 'held'; v_reason := 'mostly capitals';
  elsif v_body ~* '\m(fuck|fucking|shit|bitch|bastard|asshole|dick|pussy|cunt|slut)\M' or v_name ~* '\m(fuck|shit|bitch|asshole|cunt)\M' then
    v_status := 'held'; v_reason := 'abusive language';
  elsif v_body ~* '(viagra|casino|crypto|forex|bitcoin|click here|free money|backlink|seo service|loan offer|javascript:|onerror\s*=)' then
    v_status := 'held'; v_reason := 'spam keywords';
  end if;

  insert into public.reviews (name, rating, body, project_type, project_ref, status)
  values (v_name, p_rating::smallint, v_body, v_pt, v_pr, v_status) returning id into v_id;
  insert into public.review_meta (review_id, ip_hash, flag_reason) values (v_id, v_hash, v_reason);
  return v_status;
end $$;

revoke all on function public.submit_review(text, integer, text, text, text, text) from public;
grant execute on function public.submit_review(text, integer, text, text, text, text) to anon, authenticated;

-- live updates for the website (Supabase Realtime)
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'reviews') then
    alter publication supabase_realtime add table public.reviews;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- ADMIN SETUP (run after creating your admin user in Authentication > Users):
--   insert into public.review_admins (user_id)
--   select id from auth.users where email = 'YOUR-ADMIN-EMAIL';
-- ---------------------------------------------------------------------
