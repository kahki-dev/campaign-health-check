// =====================================================================
//  Campaign Health Check – Edge Function "hc-images"
//  Bildmaterial Spitzenkandidat/in: auflisten, hochladen, bearbeiten, löschen.
//
//  Zugriff:
//   - Landesverband: Bearbeitungslink-Token (lesen + schreiben) bzw. Leselink-Token (nur lesen)
//   - KAH: angemeldete Admins (Supabase-Auth-JWT + Eintrag in public.hc_admins), Parameter check_id
//
//  WICHTIG: In den Function-Einstellungen "Verify JWT" AUS, da Landesverbände
//  ohne Anmeldung arbeiten. Die Prüfung erfolgt hier im Code.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const BUCKET = "hc-images";
const MAX_BYTES = 15 * 1024 * 1024;
const MAX_THUMB_BYTES = 1.5 * 1024 * 1024;
const MAX_IMAGES = 30;
const MIME: Record<string, string> = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" };
const RIGHTS = ["cdu", "wahlkampf", "eingeschraenkt", "cc", "ungeklaert"];
const URL_TTL = 60 * 60; // Sekunden

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

class HttpError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (legacy) return legacy;
  const multi = Deno.env.get("SUPABASE_SECRET_KEYS");
  if (multi) {
    try { const v = Object.values(JSON.parse(multi))[0]; if (typeof v === "string") return v; } catch { /* ignorieren */ }
  }
  return Deno.env.get("SUPABASE_SECRET_KEY") ?? "";
}
const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  serviceKey(),
  { auth: { persistSession: false, autoRefreshToken: false } },
);

type Access = { checkId: string; mode: "edit" | "view" | "admin" };

async function resolveAccess(req: Request, p: Record<string, unknown>): Promise<Access> {
  const auth = req.headers.get("authorization") ?? "";
  const checkId = typeof p.check_id === "string" ? p.check_id : "";
  if (checkId && auth.startsWith("Bearer ")) {
    const { data, error } = await db.auth.getUser(auth.slice(7));
    const email = data?.user?.email?.toLowerCase();
    if (error || !email) throw new HttpError(401, "Anmeldung ungültig oder abgelaufen");
    const { data: adm } = await db.from("hc_admins").select("email").eq("email", email).maybeSingle();
    if (!adm) throw new HttpError(403, "Kein Zugriff auf das KAH-Backend");
    return { checkId, mode: "admin" };
  }
  const token = typeof p.token === "string" ? p.token : "";
  if (token.length < 32) throw new HttpError(403, "Link ungültig");
  const { data: e } = await db.from("health_checks").select("id").eq("edit_token", token).maybeSingle();
  if (e) return { checkId: e.id, mode: "edit" };
  const { data: v } = await db.from("health_checks").select("id").eq("view_token", token).maybeSingle();
  if (v) return { checkId: v.id, mode: "view" };
  throw new HttpError(403, "Link ungültig oder gesperrt");
}

const clean = (v: unknown, max = 500) => (typeof v === "string" ? v.trim().slice(0, max) : "");
const safeName = (n: string) => n.replace(/[^\p{L}\p{N}._ -]+/gu, "_").slice(0, 120) || "bild";

function validateMeta(p: Record<string, unknown>) {
  const photographer = clean(p.photographer, 200);
  const rights = clean(p.rights, 40);
  if (!photographer) throw new HttpError(400, "Bitte den Namen des Fotografen / der Fotografin angeben");
  if (!RIGHTS.includes(rights)) throw new HttpError(400, "Bitte die Bildrechte angeben");
  return { photographer, rights, rights_note: clean(p.rights_note, 2000), caption: clean(p.caption, 500) };
}

async function list(a: Access) {
  const { data: rows, error } = await db.from("hc_images").select("*").eq("check_id", a.checkId).order("created_at");
  if (error) throw new HttpError(500, error.message);
  const out = [];
  for (const r of rows ?? []) {
    const [thumb, orig] = await Promise.all([
      db.storage.from(BUCKET).createSignedUrl(r.thumb_path ?? r.path, URL_TTL),
      db.storage.from(BUCKET).createSignedUrl(r.path, URL_TTL, { download: r.filename ?? true }),
    ]);
    out.push({
      id: r.id, filename: r.filename, mime: r.mime, bytes: r.bytes, width: r.width, height: r.height,
      photographer: r.photographer, rights: r.rights, rights_note: r.rights_note, caption: r.caption,
      created_at: r.created_at, updated_at: r.updated_at,
      thumb_url: thumb.data?.signedUrl ?? null, download_url: orig.data?.signedUrl ?? null,
    });
  }
  return { mode: a.mode, max: MAX_IMAGES, images: out };
}

async function upload(a: Access, form: FormData) {
  const file = form.get("file");
  const thumb = form.get("thumb");
  if (!(file instanceof File)) throw new HttpError(400, "Keine Datei übermittelt");
  const ext = MIME[file.type];
  if (!ext) throw new HttpError(415, "Nur JPEG, PNG oder WebP erlaubt");
  if (file.size > MAX_BYTES) throw new HttpError(413, "Datei zu groß (max. 15 MB)");
  const meta = validateMeta(Object.fromEntries(form.entries()) as Record<string, unknown>);
  if (form.get("confirm") !== "true") throw new HttpError(400, "Bitte die Angaben zu den Bildrechten bestätigen");

  const { count } = await db.from("hc_images").select("id", { count: "exact", head: true }).eq("check_id", a.checkId);
  if ((count ?? 0) >= MAX_IMAGES) throw new HttpError(409, `Maximal ${MAX_IMAGES} Bilder pro Check`);

  const id = crypto.randomUUID();
  const path = `${a.checkId}/${id}.${ext}`;
  const up = await db.storage.from(BUCKET).upload(path, file, { contentType: file.type, upsert: false });
  if (up.error) throw new HttpError(500, "Upload fehlgeschlagen: " + up.error.message);

  let thumbPath: string | null = null;
  if (thumb instanceof File && thumb.type === "image/jpeg" && thumb.size <= MAX_THUMB_BYTES) {
    thumbPath = `${a.checkId}/${id}_thumb.jpg`;
    const t = await db.storage.from(BUCKET).upload(thumbPath, thumb, { contentType: "image/jpeg", upsert: false });
    if (t.error) thumbPath = null;
  }
  const width = Number(form.get("width")) || null;
  const height = Number(form.get("height")) || null;
  const { data, error } = await db.from("hc_images").insert({
    id, check_id: a.checkId, path, thumb_path: thumbPath, filename: safeName(file.name), mime: file.type,
    bytes: file.size, width, height, ...meta,
  }).select("id").single();
  if (error) {
    await db.storage.from(BUCKET).remove([path, ...(thumbPath ? [thumbPath] : [])]);
    throw new HttpError(500, error.message);
  }
  return { ok: true, id: data.id };
}

async function update(a: Access, p: Record<string, unknown>) {
  const meta = validateMeta(p);
  const { data, error } = await db.from("hc_images")
    .update({ ...meta, updated_at: new Date().toISOString() })
    .eq("id", clean(p.id, 60)).eq("check_id", a.checkId).select("id").maybeSingle();
  if (error) throw new HttpError(500, error.message);
  if (!data) throw new HttpError(404, "Bild nicht gefunden");
  return { ok: true };
}

async function remove(a: Access, p: Record<string, unknown>) {
  const { data: r } = await db.from("hc_images").select("id,path,thumb_path")
    .eq("id", clean(p.id, 60)).eq("check_id", a.checkId).maybeSingle();
  if (!r) throw new HttpError(404, "Bild nicht gefunden");
  await db.storage.from(BUCKET).remove([r.path, ...(r.thumb_path ? [r.thumb_path] : [])]);
  await db.from("hc_images").delete().eq("id", r.id);
  return { ok: true };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Nur POST" }, 405);
  try {
    const isForm = (req.headers.get("content-type") ?? "").includes("multipart/form-data");
    const form = isForm ? await req.formData() : null;
    const p: Record<string, unknown> = form ? Object.fromEntries(form.entries()) : await req.json();
    const action = clean(p.action, 20);
    const access = await resolveAccess(req, p);
    const canWrite = access.mode === "edit" || access.mode === "admin";

    switch (action) {
      case "list": return json(await list(access));
      case "upload":
        if (!canWrite || !form) throw new HttpError(403, "Hochladen nur mit Bearbeitungslink");
        return json(await upload(access, form));
      case "update":
        if (!canWrite) throw new HttpError(403, "Bearbeiten nur mit Bearbeitungslink");
        return json(await update(access, p));
      case "delete":
        if (!canWrite) throw new HttpError(403, "Löschen nur mit Bearbeitungslink");
        return json(await remove(access, p));
      default: throw new HttpError(400, "Unbekannte Aktion");
    }
  } catch (e) {
    const status = e instanceof HttpError ? e.status : 500;
    return json({ error: e instanceof Error ? e.message : "Unbekannter Fehler" }, status);
  }
});
