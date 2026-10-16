# Campaign Health Check

Interaktive Checkliste (6 Teile, 22 Fragenblöcke, 141 Leitfragen) für Landtagswahlkämpfe im CDU Corporate Design 2023, mit gemeinsamer Speicherung in Supabase.

Das Werkzeug besteht aus zwei getrennten Bereichen:

| Bereich | Adresse | Für wen | Zugang |
|---|---|---|---|
| **Frontend** | `index.html` | Kampagnenteams der Landesverbände | Persönlicher Bearbeitungslink (`…/#t=…`), kein Konto nötig |
| **KAH-Backend** | `admin.html` | Mitarbeitende des Konrad-Adenauer-Hauses | Anmeldung per E-Mail-Link, nur freigeschaltete Adressen |

Im KAH-Backend: Übersicht aller Checks mit Fortschritt und Ampelständen, neue Checks anlegen, Bearbeitungs- und Leselinks anzeigen, sperren und neu erzeugen, einzelne Checks ansehen und als CSV/JSON exportieren, Übersicht als CSV.

## Aufbau

| Datei | Zweck |
|---|---|
| `index.html` | Frontend für die Landesverbände (Checkliste) |
| `admin.html` | KAH-Backend |
| `config.js` | Supabase-URL und öffentlicher Key |
| `impressum.html`, `datenschutz.html` | Impressum und Datenschutzhinweise (Datenschutz als Entwurf, vor Go-live vom DSB freigeben) |
| `assets/questions.js` | Die 141 Leitfragen – gemeinsame Quelle für Frontend und Backend |
| `assets/cdu-logo.png` | Offizielles Logo der CDU Deutschlands |
| `assets/fonts/`, `assets/fonts.css` | Lokal eingebundene Schriften (Inter, IBM Plex Serif, SIL OFL) – keine Verbindung zu Google Fonts |
| `supabase/migrations/` | Datenbank in zwei Schritten: `…000000_health_check.sql` (Checks, Links, Speichern), `…120000_kah_backend.sql` (KAH-Anmeldung, Admin-Funktionen) |

## Supabase (eingerichtet)

- Projekt `campaign-health-check` in der Organisation kahki-dev, Region Frankfurt
- Beide SQL-Dateien sind ausgeführt.
- **Authentication → URL Configuration:** Site URL `https://kahki-dev.github.io/campaign-health-check/admin.html`, Redirect `https://kahki-dev.github.io/campaign-health-check/**`. Bei anderer Adresse (z. B. eigene Domain) beide Werte anpassen, sonst funktioniert der Anmeldelink nicht.

### KAH-Mitarbeitende freischalten
Im SQL Editor:
```sql
insert into public.hc_admins (email, note) values ('vorname.nachname@cdu.de', 'Abteilung …');
-- entfernen:
delete from public.hc_admins where email = 'vorname.nachname@cdu.de';
```

### E-Mail-Versand der Anmeldelinks
Der eingebaute Mailversand von Supabase stellt nur an **Mitglieder der Supabase-Organisation** zu und ist stark begrenzt (wenige Mails pro Stunde). Für weitere KAH-Mitarbeitende unter **Authentication → Emails → SMTP Settings** einen eigenen SMTP-Server eintragen (z. B. CDU-Mailserver oder einen Versanddienstleister mit Sitz in der EU).

## Veröffentlichen mit GitHub Desktop

1. Änderungen in GitHub Desktop committen (**Commit to main**) und **Push origin**.
2. Auf github.com: **Settings → Pages → Deploy from a branch → `main` / `(root)` → Save**.
3. Nach ca. einer Minute erreichbar unter `https://kahki-dev.github.io/campaign-health-check/` (Frontend) und `…/admin.html` (KAH-Backend).

> **Sichtbarkeit:** GitHub-Pages-Seiten sind öffentlich erreichbar, auch aus privaten Repositories (Ausnahme: GitHub Enterprise Cloud). Pages aus einem privaten Repository braucht einen Team- oder Enterprise-Plan. Die **Inhalte** sind trotzdem geschützt: Ohne gültigen Link bzw. KAH-Anmeldung liefert die Datenbank nichts. Öffentlich sichtbar sind nur die Leitfragen. Wer auch die Seite schützen will: Cloudflare Pages + Cloudflare Access (Zugang nur mit `@cdu.de`-Adresse). Dann Redirect-URLs in Supabase und Abschnitt 5 der Datenschutzhinweise anpassen.

Optional liegt unter `deploy/github-pages.yml` ein Actions-Workflow, der `config.js` aus Repository-Variablen erzeugt. Für „Deploy from a branch“ wird er nicht gebraucht.

## Ablauf

1. KAH meldet sich unter `admin.html` an und legt einen Check an (z. B. „LTW Sachsen-Anhalt 2026“).
2. Den **Bearbeitungslink** an das Kampagnenteam des Landesverbands schicken (nur über interne Kanäle).
3. Der Landesverband füllt die Checkliste aus; alles wird automatisch gespeichert.
4. KAH verfolgt Fortschritt und Ampelstände in der Übersicht, öffnet Checks im Lesemodus und exportiert bei Bedarf.
5. Wird ein Link weitergegeben oder ein Teammitglied scheidet aus: im Backend **Links → Neu erzeugen**. Der alte Link ist sofort gesperrt.

## Checkliste vor dem Echtbetrieb

- [ ] Datenschutzhinweise vom Datenschutzbeauftragten freigeben lassen, danach den Entwurf-Hinweis in `datenschutz.html` entfernen
- [ ] Vertrag zur Auftragsverarbeitung (AVV) mit Supabase abschließen
- [ ] Supabase auf den Pro-Plan umstellen (der Free-Plan pausiert Projekte nach 7 Tagen Inaktivität; Pro enthält tägliche Backups)
- [ ] Eigenen SMTP-Server für die Anmeldelinks eintragen
- [ ] Testdatensatz löschen: `delete from public.health_checks where label = 'Testcheck (kann gelöscht werden)';`
- [ ] Leitfragen nur in `assets/questions.js` ändern. Antworten hängen an der fortlaufenden Nummer der Frage: **nach Go-live keine Fragen einfügen, löschen oder umsortieren**. Umformulieren ist unbedenklich, neue Fragen nur ganz am Ende anhängen.
