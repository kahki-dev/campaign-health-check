-- =====================================================================
--  Campaign Health Check – KAH-Backend (Admin-Bereich)
--  Nach 20261016000000_health_check.sql im SQL Editor ausführen.
--
--  - KAH-Mitarbeitende melden sich per E-Mail-Link (Supabase Auth) an.
--  - Zugriff hat nur, wer in public.hc_admins steht (Freischaltliste).
--  - Neue Checks legt ausschließlich das KAH an; die bisherige anonyme
--    Anlage mit Anlage-Schlüssel (hc_create / hc_settings) entfällt.
-- =====================================================================

-- ---------- Freischaltliste ----------
create table if not exists public.hc_admins (
  email      text primary key check (email = lower(email) and email like '%@%'),
  note       text,
  created_at timestamptz not null default now()
);
alter table public.hc_admins enable row level security;
revoke all on public.hc_admins from anon, authenticated;

insert into public.hc_admins (email, note)
values ('benjamin.laepple@cdu.de', 'Ersteinrichtung')
on conflict (email) do nothing;

-- ---------- Anonyme Anlage abschalten ----------
drop function if exists public.hc_create(text, text, jsonb);
drop table if exists public.hc_settings;

-- ---------- Prüffunktion ----------
create or replace function public.hc_is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null
     and exists (select 1 from public.hc_admins
                  where email = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

-- ---------- Wer bin ich? ----------
create or replace function public.hc_admin_me()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('email', auth.jwt() ->> 'email', 'is_admin', public.hc_is_admin());
$$;

-- ---------- Übersicht aller Checks ----------
create or replace function public.hc_admin_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.hc_is_admin() then
    raise exception 'Kein Zugriff auf das KAH-Backend' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
             'id', c.id,
             'label', c.label,
             'created_at', c.created_at,
             'updated_at', c.updated_at,
             'version', c.version,
             'edit_token', c.edit_token,
             'view_token', c.view_token,
             'wahltermin', c.data #>> '{metadata,Wahltermin}',
             'verantwortlich', c.data #>> '{metadata,Gesamtverantwortliche/r}',
             'stand', c.data #>> '{metadata,Stand der Erhebung}',
             'counts', (
               select jsonb_build_object(
                 'green',  count(*) filter (where a.value ->> 'status' = 'green'),
                 'yellow', count(*) filter (where a.value ->> 'status' = 'yellow'),
                 'red',    count(*) filter (where a.value ->> 'status' = 'red'),
                 'na',     count(*) filter (where a.value ->> 'status' = 'na'))
               from jsonb_each(case when jsonb_typeof(c.data -> 'answers') = 'object'
                                    then c.data -> 'answers' else '{}'::jsonb end) a)
           ) order by c.updated_at desc)
      from public.health_checks c), '[]'::jsonb);
end $$;

-- ---------- Check anlegen ----------
create or replace function public.hc_admin_create(p_label text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.health_checks;
begin
  if not public.hc_is_admin() then
    raise exception 'Kein Zugriff auf das KAH-Backend' using errcode = '42501';
  end if;
  if nullif(trim(p_label), '') is null then
    raise exception 'Bitte eine Bezeichnung angeben';
  end if;
  insert into public.health_checks (label, data)
  values (trim(p_label),
          jsonb_build_object('format', 'campaign-health-check-v2',
                             'metadata', jsonb_build_object('Bundesland / Wahl', trim(p_label)),
                             'answers', '{}'::jsonb))
  returning * into r;
  return jsonb_build_object('id', r.id, 'edit_token', r.edit_token, 'view_token', r.view_token);
end $$;

-- ---------- Link sperren und neu erzeugen ----------
create or replace function public.hc_admin_rotate(p_id uuid, p_which text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r public.health_checks;
  t text := replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','');
begin
  if not public.hc_is_admin() then
    raise exception 'Kein Zugriff auf das KAH-Backend' using errcode = '42501';
  end if;
  if p_which = 'edit' then
    update public.health_checks set edit_token = t where id = p_id returning * into r;
  elsif p_which = 'view' then
    update public.health_checks set view_token = t where id = p_id returning * into r;
  else
    raise exception 'Unbekannter Linktyp';
  end if;
  if not found then raise exception 'Check nicht gefunden'; end if;
  return jsonb_build_object('id', r.id, 'edit_token', r.edit_token, 'view_token', r.view_token);
end $$;

-- ---------- Einzelnen Check laden (Export) ----------
create or replace function public.hc_admin_get(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r public.health_checks;
begin
  if not public.hc_is_admin() then
    raise exception 'Kein Zugriff auf das KAH-Backend' using errcode = '42501';
  end if;
  select * into r from public.health_checks where id = p_id;
  if not found then raise exception 'Check nicht gefunden'; end if;
  return jsonb_build_object('id', r.id, 'label', r.label, 'data', r.data,
                            'version', r.version, 'updated_at', r.updated_at, 'created_at', r.created_at);
end $$;

-- ---------- Ausführungsrechte: nur angemeldete Nutzer, Prüfung in der Funktion ----------
revoke all on function public.hc_is_admin()               from public, anon;
revoke all on function public.hc_admin_me()               from public, anon;
revoke all on function public.hc_admin_list()             from public, anon;
revoke all on function public.hc_admin_create(text)       from public, anon;
revoke all on function public.hc_admin_rotate(uuid, text) from public, anon;
revoke all on function public.hc_admin_get(uuid)          from public, anon;
grant execute on function public.hc_is_admin()               to authenticated;
grant execute on function public.hc_admin_me()               to authenticated;
grant execute on function public.hc_admin_list()             to authenticated;
grant execute on function public.hc_admin_create(text)       to authenticated;
grant execute on function public.hc_admin_rotate(uuid, text) to authenticated;
grant execute on function public.hc_admin_get(uuid)          to authenticated;

-- =====================================================================
--  KAH-Mitarbeitende freischalten / entfernen:
--    insert into public.hc_admins (email, note) values ('vorname.nachname@cdu.de', 'Abteilung …');
--    delete from public.hc_admins where email = 'vorname.nachname@cdu.de';
--  Freigeschaltete anzeigen:
--    select * from public.hc_admins order by email;
-- =====================================================================
