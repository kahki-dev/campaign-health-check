-- =====================================================================
--  Campaign Health Check – Supabase-Backend (link-basiert, ohne Login)
--  Einmalig im Supabase-Dashboard unter "SQL Editor" ausführen.
--
--  Prinzip
--  - Jeder Health Check ist eine Zeile in public.health_checks.
--  - Zugriff ausschließlich über zwei geheime Links (Tokens):
--      edit_token  → Bearbeiten        (an das Kampagnenteam des LV)
--      view_token  → Nur Lesen         (z. B. für das KAH)
--  - Die Tabelle selbst ist für den öffentlichen anon-Key komplett
--    gesperrt (RLS ohne Policies + REVOKE). Lesen/Schreiben geht nur über
--    die Funktionen hc_get / hc_save, die das Token prüfen.
--  - Neue Checks kann nur anlegen, wer den Anlage-Schlüssel kennt
--    (hc_settings.create_key) – verhindert Spam über den öffentlichen Key.
--  - Bei jeder Änderung wird höchstens alle 15 Minuten eine Sicherungs-
--    kopie in public.health_check_versions abgelegt.
-- =====================================================================

-- ---------- Tabellen ----------
create table if not exists public.health_checks (
  id          uuid primary key default gen_random_uuid(),
  edit_token  text not null unique
              default replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-',''),
  view_token  text not null unique
              default replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-',''),
  label       text,
  data        jsonb not null default '{}'::jsonb,
  version     integer not null default 1,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists public.health_check_versions (
  id        bigint generated always as identity primary key,
  check_id  uuid not null references public.health_checks(id) on delete cascade,
  version   integer not null,
  data      jsonb not null,
  saved_at  timestamptz not null default now()
);
create index if not exists health_check_versions_check_idx
  on public.health_check_versions (check_id, saved_at desc);

create table if not exists public.hc_settings (
  key   text primary key,
  value text not null
);
-- Zufälligen Anlage-Schlüssel erzeugen (nur beim ersten Lauf)
insert into public.hc_settings (key, value)
values ('create_key', substr(replace(gen_random_uuid()::text,'-',''),1,20))
on conflict (key) do nothing;

-- ---------- Zugriff sperren: nichts direkt über die REST-API ----------
alter table public.health_checks         enable row level security;
alter table public.health_check_versions enable row level security;
alter table public.hc_settings           enable row level security;
revoke all on public.health_checks, public.health_check_versions, public.hc_settings
  from anon, authenticated;

-- ---------- Sicherungskopien ----------
create or replace function public.hc_snapshot()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not exists (
    select 1 from public.health_check_versions
     where check_id = old.id and saved_at > now() - interval '15 minutes'
  ) then
    insert into public.health_check_versions (check_id, version, data)
    values (old.id, old.version, old.data);
  end if;
  return new;
end $$;

drop trigger if exists hc_snapshot_trg on public.health_checks;
create trigger hc_snapshot_trg
  before update on public.health_checks
  for each row when (old.data is distinct from new.data)
  execute function public.hc_snapshot();

-- ---------- API: Check anlegen ----------
create or replace function public.hc_create(p_label text, p_create_key text, p_data jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.health_checks;
begin
  if p_create_key is distinct from (select value from public.hc_settings where key = 'create_key') then
    raise exception 'Anlage-Schlüssel ungültig' using errcode = '28000';
  end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then p_data := '{}'::jsonb; end if;
  insert into public.health_checks (label, data)
  values (nullif(trim(p_label), ''), p_data)
  returning * into r;
  return jsonb_build_object('edit_token', r.edit_token, 'view_token', r.view_token, 'version', r.version);
end $$;

-- ---------- API: Check laden (Bearbeitungs- oder Leselink) ----------
create or replace function public.hc_get(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r public.health_checks;
begin
  if p_token is null or length(p_token) < 32 then
    raise exception 'Link ungültig' using errcode = '28000';
  end if;
  select * into r from public.health_checks where edit_token = p_token;
  if found then
    return jsonb_build_object('mode','edit','label',r.label,'data',r.data,'version',r.version,
                              'updated_at',r.updated_at,'view_token',r.view_token);
  end if;
  select * into r from public.health_checks where view_token = p_token;
  if found then
    return jsonb_build_object('mode','view','label',r.label,'data',r.data,'version',r.version,
                              'updated_at',r.updated_at);
  end if;
  raise exception 'Link ungültig oder Check gelöscht' using errcode = '28000';
end $$;

-- ---------- API: Speichern mit Versionsprüfung ----------
-- Gibt bei Konflikt (jemand anderes hat zwischenzeitlich gespeichert) den
-- aktuellen Serverstand zurück; das Frontend führt dann feldweise zusammen.
create or replace function public.hc_save(p_token text, p_data jsonb, p_version integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.health_checks;
begin
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    raise exception 'Ungültige Daten';
  end if;
  if pg_column_size(p_data) > 2000000 then
    raise exception 'Datenumfang zu groß (max. ca. 2 MB)';
  end if;

  update public.health_checks
     set data       = p_data,
         version    = version + 1,
         updated_at = now(),
         label      = coalesce(nullif(p_data #>> '{metadata,Bundesland / Wahl}', ''), label)
   where edit_token = p_token and version = p_version
  returning * into r;

  if found then
    return jsonb_build_object('ok', true, 'version', r.version, 'updated_at', r.updated_at);
  end if;

  select * into r from public.health_checks where edit_token = p_token;
  if not found then
    raise exception 'Bearbeitungslink ungültig' using errcode = '28000';
  end if;
  return jsonb_build_object('ok', false, 'conflict', true, 'version', r.version,
                            'data', r.data, 'updated_at', r.updated_at);
end $$;

-- ---------- Ausführungsrechte ----------
revoke all on function public.hc_snapshot()                    from public, anon, authenticated;
revoke all on function public.hc_create(text, text, jsonb)     from public;
revoke all on function public.hc_get(text)                     from public;
revoke all on function public.hc_save(text, jsonb, integer)    from public;
grant execute on function public.hc_create(text, text, jsonb)  to anon, authenticated;
grant execute on function public.hc_get(text)                  to anon, authenticated;
grant execute on function public.hc_save(text, jsonb, integer) to anon, authenticated;

-- =====================================================================
--  Nützliche Abfragen für Admins (einzeln im SQL Editor ausführen)
-- =====================================================================
-- Anlage-Schlüssel anzeigen:
--   select value from public.hc_settings where key = 'create_key';
--
-- Anlage-Schlüssel wechseln:
--   update public.hc_settings set value = 'neuer-schluessel' where key = 'create_key';
--
-- Check direkt per SQL anlegen (ohne Schlüssel):
--   insert into public.health_checks (label) values ('LTW Beispielland 2027')
--   returning label, edit_token, view_token;
--
-- Alle Checks mit Fortschritt:
--   select label, version, updated_at,
--          (select count(*) from jsonb_each(data->'answers') a where a.value->>'status' <> '') as bewertet,
--          edit_token, view_token
--     from public.health_checks order by updated_at desc;
--
-- Link sperren (neuer Token, alter Link wird ungültig):
--   update public.health_checks
--      set edit_token = replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','')
--    where label = 'LTW Beispielland 2027' returning edit_token;
--
-- Älteren Stand wiederherstellen:
--   select id, version, saved_at from public.health_check_versions
--    where check_id = '<uuid>' order by saved_at desc;
--   update public.health_checks c set data = v.data, version = c.version + 1, updated_at = now()
--     from public.health_check_versions v where v.id = <id> and c.id = v.check_id;
