# Campaign Health Check

Interaktive Checkliste (6 Teile, 22 Fragenblöcke, 141 Leitfragen) für Landtagswahlkämpfe im CDU Corporate Design 2023, mit gemeinsamer Speicherung in Supabase.

- **Ohne Anmeldung:** Jeder Check hat einen geheimen **Bearbeitungslink** (Kampagnenteam) und einen **Leselink** (KAH).
- Automatisches Speichern, gleichzeitiges Bearbeiten mit Zusammenführung pro Feld, Sicherungskopien alle 15 Minuten.
- Ohne Supabase-Konfiguration läuft die Seite rein lokal im Browser.

## Aufbau

| Datei | Zweck |
|---|---|
| `index.html` | Die komplette Anwendung (HTML, CSS, JS in einer Datei) |
| `config.js` | Supabase-URL und öffentlicher Key |
| `impressum.html`, `datenschutz.html` | Impressum und Datenschutzhinweise (Datenschutz als Entwurf, vor Go-live vom DSB freigeben) |
| `assets/` | Lokal eingebundene Schriften (Inter, IBM Plex Serif, SIL OFL) und Styles der Rechtstexte – keine Verbindung zu Google Fonts |
| `supabase/migrations/…_health_check.sql` | Tabellen, Zugriffsschutz, API-Funktionen |
| `.github/workflows/pages.yml` | Automatische Veröffentlichung auf GitHub Pages |

## Inbetriebnahme

### 1. Supabase einrichten (ca. 10 Min.)
1. Auf [supabase.com](https://supabase.com) ein Projekt anlegen, **Region: Frankfurt (eu-central-1)**.
2. **SQL Editor** → Inhalt von `supabase/migrations/…_health_check.sql` einfügen → **Run**.
3. Anlage-Schlüssel notieren:
   ```sql
   select value from public.hc_settings where key = 'create_key';
   ```
4. Unter **Project Settings → API** die **Project URL** und den **anon public**- bzw. **Publishable**-Key kopieren.
   ⚠️ Niemals den `service_role`- bzw. `secret`-Key verwenden.

### 2. Auf GitHub hochladen
**Variante A: GitHub Desktop (ohne Terminal)**
1. Auf github.com ein neues Repository anlegen (z. B. `campaign-health-check`, **Private**).
2. GitHub Desktop → *File → Add Local Repository* → diesen Ordner wählen → *Create a repository*.
3. *Publish repository* → das angelegte Repository wählen.

**Variante B: Terminal**
```bash
cd "campaign-health-check"
git init -b main
git add .
git commit -m "Campaign Health Check: erste Version"
git remote add origin https://github.com/<organisation>/campaign-health-check.git
git push -u origin main
```

### 3. Veröffentlichen mit GitHub Pages
1. Im Repository: **Settings → Secrets and variables → Actions → Variables** → zwei Variablen anlegen:
   - `SUPABASE_URL` = `https://<projekt>.supabase.co`
   - `SUPABASE_KEY` = öffentlicher anon-/publishable-Key
2. **Settings → Pages → Source: GitHub Actions**.
3. **Actions → „Auf GitHub Pages veröffentlichen“ → Run workflow** (läuft danach bei jedem Push auf `main` automatisch).
4. Die Adresse steht anschließend unter *Settings → Pages*, z. B. `https://<organisation>.github.io/campaign-health-check/`.

> **Hinweis zur Sichtbarkeit:** GitHub-Pages-Seiten sind öffentlich erreichbar, auch aus privaten Repositories (Ausnahme: GitHub Enterprise Cloud mit privater Pages-Sichtbarkeit). Pages aus einem privaten Repository braucht außerdem einen kostenpflichtigen Plan (Pro, Team oder Enterprise). Die **Antworten** sind trotzdem geschützt, denn ohne gültigen Link liefert die Datenbank nichts. Öffentlich sichtbar sind nur die Leitfragen. Wenn auch die Seite selbst geschützt sein soll: siehe unten.

### Alternative: Hosting mit Zugangsschutz
- **Cloudflare Pages + Cloudflare Access** (bis 50 Nutzer kostenlos): Repository verbinden, Build-Befehl leer, Ausgabeordner `/`. Mit Access ist die Seite nur nach E-Mail-Code mit `@cdu.de`-Adressen erreichbar. `config.js` vorher im Repository befüllen.
- **Netlify:** Repository verbinden, Ausgabeordner `/`. Passwortschutz gibt es nur in kostenpflichtigen Plänen.
- **Interner Webserver:** `index.html` und `config.js` einfach hochladen.

### 4. Ersten Check anlegen
Seite öffnen → *Neuen Health Check anlegen* → Bezeichnung und Anlage-Schlüssel eingeben → Bearbeitungslink an den Landesverband, Leselink ans KAH.

## Betrieb

Admin-Abfragen (alle Checks mit Fortschritt, Link sperren, alten Stand wiederherstellen) stehen als Kommentar am Ende der SQL-Datei.

**Checkliste vor dem Einsatz**
- [ ] Vertrag zur Auftragsverarbeitung (AVV) mit Supabase abschließen (Dashboard → Organization → Legal) und mit dem Datenschutz abstimmen
- [ ] Anlage-Schlüssel nur an KAH-Verantwortliche geben
- [ ] Leitfragen bei Änderungen nur in `index.html` (Array `groups`) anpassen. Die Antworten sind über die fortlaufende Nummer der Frage gespeichert, deshalb **nach Inbetriebnahme keine Fragen einfügen, löschen oder umsortieren**, sonst verrutschen gespeicherte Antworten. Umformulieren ist unbedenklich. Neue Fragen nur ganz am Ende anhängen oder die Antworten vorher migrieren.
- [ ] Auf Supabase Free werden Projekte nach 7 Tagen Inaktivität pausiert. Für den Wahlkampfeinsatz den Pro-Plan nutzen (inkl. täglicher Backups).
