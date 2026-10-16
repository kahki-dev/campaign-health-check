-- =====================================================================
--  Campaign Health Check – Bildmaterial Spitzenkandidat/in
--  Nach den beiden vorherigen Migrationen im SQL Editor ausführen.
--
--  - Bilder liegen in einem privaten Storage-Bucket "hc-images".
--  - Metadaten (Fotograf/in, Bildrechte, Bildunterschrift) in public.hc_images.
--  - Zugriff ausschließlich über die Edge Function "hc-images", die den
--    Bearbeitungs-/Leselink bzw. die KAH-Anmeldung prüft. Weder Tabelle
--    noch Bucket sind für anon/authenticated direkt erreichbar.
-- =====================================================================

-- ---------- Privater Bucket (max. 15 MB, nur JPEG/PNG/WebP) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('hc-images', 'hc-images', false, 15728640, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update
  set public = false,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- ---------- Metadaten ----------
create table if not exists public.hc_images (
  id            uuid primary key default gen_random_uuid(),
  check_id      uuid not null references public.health_checks(id) on delete cascade,
  path          text not null,
  thumb_path    text,
  filename      text,
  mime          text,
  bytes         integer,
  width         integer,
  height        integer,
  photographer  text not null check (length(trim(photographer)) > 0),
  rights        text not null check (rights in ('cdu','wahlkampf','eingeschraenkt','cc','ungeklaert')),
  rights_note   text,
  caption       text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists hc_images_check_idx on public.hc_images (check_id, created_at);

alter table public.hc_images enable row level security;
revoke all on public.hc_images from anon, authenticated;

-- Die Edge Function arbeitet mit der service_role
grant select, insert, update, delete on public.hc_images to service_role;
grant select on public.health_checks, public.hc_admins to service_role;

-- ---------- Bildanzahl in der KAH-Übersicht ----------
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
             'images', (select count(*) from public.hc_images i where i.check_id = c.id),
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
revoke all on function public.hc_admin_list() from public, anon;
grant execute on function public.hc_admin_list() to authenticated;
