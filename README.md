# HomeEdge

**HomeEdge - Secure VPS Gateway for Home Services**

HomeEdge ist ein schlankes VPS-Gateway, das Home-Services wie Jellyfin sicher
ins Internet bringt, ohne zu Hause Ports zu oeffnen. Bedienung komplett ueber
ein Terminal-Menue, keine Web-GUI.

## Was ist HomeEdge?

Ein kleiner VPS nimmt den Internet-Traffic an (HTTPS via Caddy) und leitet ihn
durch einen WireGuard-Tunnel zu deinem Heimnetz. Dein Backend (z. B. Jellyfin)
bleibt hinter der UniFi-Firewall und ist nie direkt aus dem Internet erreichbar.

## Architektur

```text
Internet -> VPS/Caddy -> WireGuard -> UniFi/Home-Netz -> Backend-Service
```

## Security-Komponenten

```text
UFW Firewall            nur SSH, 443/tcp und WireGuard/udp offen
Fail2ban                SSH und optional Caddy/Jellyfin 401/403
Caddy Reverse Proxy     HTTPS mit automatischen Let's-Encrypt-Zertifikaten
WireGuard Tunnel        VPS <-> UniFi, optional mit Preshared Key
UniFi Firewall          nur VPS-WG-IP -> Backend-IP:Port
automatische Updates    unattended-upgrades
```

## Hauptbefehl

```bash
sudo homeedge menu
```

`edgectl` bleibt als Kompatibilitaets-Alias erhalten (`sudo edgectl menu`).

Das Terminal-Menue ist in Gruppen mit Breadcrumb (z. B. `HomeEdge > Sicherheit`)
und je `b) Zurueck` / `0) Beenden` organisiert:

```text
1) Status / Ampel             6) Backup & Restore
2) Domains & Dienste          7) Updates & Wartung
3) WireGuard Tunnel           8) Logs & Diagnose
4) Caddy / HTTPS / Cloudflare 9) Einstellungen
5) Sicherheit                10) Monitoring / Beszel Agent (optional)
                              0) Beenden
```

Weitere Direktbefehle:

```bash
sudo homeedge health        # Ampel-Check
sudo homeedge status        # Status der Dienste
sudo homeedge wg-values     # WireGuard/UniFi-Werte inkl. Keys
sudo homeedge backup        # Backup / Restore
sudo homeedge self-update   # Update direkt aus dem GitHub-Repo
sudo homeedge check-update  # nur pruefen, ob ein Update vorliegt
```

Direktbefehle oeffnen die jeweilige Menue-Gruppe:
`homeedge security`, `homeedge fail2ban`, `homeedge backup`, `homeedge update`,
`homeedge wg-menu`, `homeedge network`, `homeedge monitoring`. Weitere:
`homeedge reload`, `restart`, `caddy-rebuild`, `caddy-update`, `caddy-logs`,
`certs`, `domains`, `test-domain DOMAIN`, `verify-setup`, `set-token`, `mtu`,
`migrate`, `rollback`, `diagnose`.

## Installation

### Windows

ZIP entpacken, PowerShell im Ordner oeffnen:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-EdgeVps.ps1
```

### Linux/macOS

ZIP entpacken, Terminal im Ordner oeffnen:

```bash
chmod +x Install-EdgeVps.sh
./Install-EdgeVps.sh
```

Beide Installer fragen am Ende, ob direkt per SSH auf den VPS gewechselt und
`sudo homeedge menu` gestartet werden soll. Bei aktiviertem SSH-Hardening wird
dabei automatisch der neue Admin-User verwendet.

### Direkt auf dem VPS

```bash
sudo apt update && sudo apt install git -y
git clone https://github.com/fdreckmann/homedge.git
cd homedge
sudo bash Install-Direct-OnVps.sh
```

Der Wizard zeigt die Netzwerkadapter zur Auswahl an, fasst alle Eingaben
uebersichtlich zusammen und startet erst nach ausdruecklicher Bestaetigung.

## Update

Im Menue unter `Updates & Wartung`:

```text
1) HomeEdge Version anzeigen      6) Server Auslastung anzeigen
2) Nach Update suchen             7) Dienste neu starten
3) HomeEdge aktualisieren         8) Rollback auf letztes Backup
4) Systemupdates installieren     9) System rebooten
5) Docker / Caddy neu bauen
```

**Was automatisch laeuft und was manuell ist** (auch im Menue und in `status` sichtbar):

```text
Automatisch:  OS-Sicherheitsupdates (unattended-upgrades), TLS-Zertifikate (Caddy)
Manuell:      HomeEdge-Script, Caddy/Docker-Image, Cloudflare-DNS-Plugin, Container-Rebuild
```

Automatische Container-/Image-Updates sind bewusst NICHT aktiv (koennten Dienste
ungeplant brechen).

- Standardquelle ist `https://raw.githubusercontent.com/fdreckmann/homedge/main/homeedge.sh`.
- Vor jedem Update wird automatisch ein Backup erstellt.
- Der Download wird geprueft (HomeEdge-Marker, optionale SHA256, `bash -n`),
  bevor er installiert wird. Bei Fehlern bleibt die laufende Version unveraendert.
- Repo/Branch aendern: `sudo homeedge set-repo`.
- Empfehlung: nicht blind von `main`, sondern bevorzugt getaggte Releases nutzen.
- Nach dem Update laeuft automatisch eine Migration (`sudo homeedge migrate`):
  Cloudflare-Token wird bereinigt (immer einzeilig), fehlende Werte werden
  ergaenzt (`ENABLE_HTTP3=0`, `ENABLE_IPV6=0`, `WG_MTU=` leer/automatisch), die
  Caddyfile neu erzeugt/validiert und ein Healthcheck ausgefuehrt. **Bestehende
  Werte werden respektiert** (z. B. `ENABLE_HTTP3=1` oder `WG_MTU=1280` bleiben
  erhalten, es gibt nur einen Hinweis). Dienste, Zertifikate und WireGuard-Keys
  bleiben erhalten.
- **Migration/Update melden Fehler ehrlich:** Bleibt `services.tsv` nach dem
  Reparaturversuch ungueltig, wird der Caddy-Reload uebersprungen (die laufende
  Caddyfile bleibt aktiv), die Migration endet mit `[ERR]` und Exitcode != 0 -
  und auch das Self-/Repo-Update endet mit Fehlerstatus. Ein Update wirkt nie
  faelschlich erfolgreich.
- Die "Nur HomeEdge aktualisieren"-Skripte (`Update-HomeEdgeOnly.sh/.ps1`)
  ersetzen das Script, erstellen ein Pre-Update-Backup und fuehren danach
  Migration, `validate-services` und `health` aus; bei Fehlern wird ein
  Rollback-Hinweis ausgegeben und der Exitcode ist != 0.
- Logs (Menue Logs & Diagnose, Diagnosebericht) werden maskiert ausgegeben;
  ein Caddy-Container im Status "Restarting" gilt als Fehler, nicht als OK.

## HTTP/3 / QUIC und Firewall

- Standard ist `ENABLE_HTTP3=0` (nur HTTP/1.1 + HTTP/2, UFW oeffnet nur 443/tcp).
  Fuer Jellyfin erstmal AUS empfohlen.
- Die Installer fragen HTTP/3 beim Setup ab (Default: nein); der Bootstrap
  oeffnet `443/udp` nur, wenn HTTP/3 aktiviert wurde.
- Aktivieren ueber `Caddy / HTTPS / Cloudflare -> HTTP/3 aktivieren/deaktivieren`;
  dabei wird `443/udp` in UFW passend geoeffnet bzw. wieder geschlossen.
- `sudo homeedge firewall` setzt UFW passend zur Konfiguration (443/udp nur bei HTTP/3).

## IPv6 (optional, nur externer Zugriff)

IPv6 betrifft ausschliesslich den externen Zugriff Client -> VPS/Caddy. Der
Backend-Zugriff ins Heimnetz bleibt IPv4 ueber WireGuard.

- Standard `ENABLE_IPV6=0`. Aktivieren ueber
  `Caddy / HTTPS / Cloudflare -> IPv6 extern aktivieren/deaktivieren`
  (oder `sudo homeedge ipv6`).
- Aktiv: UFW setzt `IPV6=yes` und gibt `443/tcp` (und bei HTTP/3 `443/udp`)
  auch fuer IPv6 frei. Aus: kein v6-Service offen (UFW v6 default deny).
- Status: `sudo homeedge ipv6-status` (VPS-IPv6, UFW-IPv6, Caddy-Listen).
- `sudo homeedge domains` zeigt je Domain A/AAAA, erwartete VPS-IPv4/IPv6 und
  bewertet AAAA (z. B. Warnung, wenn AAAA gesetzt aber `ENABLE_IPV6=0`).
- Kein IPv6 fuer das Backend noetig (keine IPv6-Backend-IP, keine v6-WG-Subnetze).

## WireGuard MTU

- Standard `WG_MTU=` leer = automatisch: es wird KEINE `MTU`-Zeile in
  `/etc/wireguard/<if>.conf` geschrieben, WireGuard/Linux nutzt den Default.
  `1280` ist nur ein optionaler Troubleshooting-Wert.
- Aendern ueber `WireGuard Tunnel -> MTU anzeigen/aendern` (oder `sudo homeedge mtu`):
  automatisch (leer), manuell (numerisch 1200-1420) oder Empfehlung anzeigen.
- Hinweis: MTU ggf. auch auf UniFi-Seite setzen, falls dort ein MTU-Feld existiert.

## Backup / Restore

Im Menue unter `Backup / Restore`. Ein Backup enthaelt:

```text
/etc/homeedge        HomeEdge-Konfiguration, Keys (inkl. beszel.env, falls vorhanden)
/etc/wireguard       WireGuard-Konfiguration
/opt/caddy-edge      Caddy (Caddyfile, Compose, Daten)
Fail2ban-Konfiguration
UFW-Regeln
beszel-agent.service (systemd-Unit, falls installiert)
/usr/local/bin/homeedge  (Binary/Script)
```

Das Beszel-Agent-Binary wird bewusst NICHT gesichert (per `beszel-install` /
`beszel-update` jederzeit neu holbar).

- Vor kritischen Aenderungen bietet HomeEdge automatisch ein Backup an.
- **Restore-Varianten:** "Komplettes Restore" (Software + Config) oder
  "Config Restore" (nur Konfiguration, Software bleibt). Vor jedem Restore wird
  automatisch ein Pre-Restore-Backup erstellt.
- Restore validiert `services.tsv` und die Config, generiert die Caddyfile neu
  und meldet **keinen** Erfolg, wenn `services.tsv` defekt ist.
- Vor dem Erstellen eines Backups wird `services.tsv` geprueft; ein defekter
  Stand wird nur nach Rueckfrage gesichert.
- **WICHTIG: Backups enthalten Secrets** (WireGuard-Keys, Cloudflare Token).
  Niemals unverschluesselt teilen oder ins Repo legen.

## Dienste-Datei (services.tsv)

- Jeder Dienst ist eine Zeile mit genau 5 Feldern:
  `domain<TAB>scheme<TAB>ip<TAB>port<TAB>profile`.
- Streng validiert werden Domain (vollstaendiger FQDN oder `*.domain.tld`, keine
  Sonderzeichen), Scheme (`http`/`https`), Backend (IPv4 oder Hostname), Port
  (1-65535) und Profil (`standard`/`jellyfin`/`jellyseerr`). Fehlermeldungen
  nennen Zeile und Ursache, z. B. `Zeile 1: Domain "jf" ist ungueltig` mit dem
  Hinweis, einen vollstaendigen FQDN wie `jf.smatitec.de` zu verwenden.
- HomeEdge haengt neue Dienste immer sauber an (Trailing-Newline-Schutz) und
  validiert die Datei nach jeder Aenderung; bei Fehlern wird zurueckgerollt.
- `sudo homeedge repair-services` arbeitet atomar: die defekte Datei wird nach
  `services.tsv.broken.TIMESTAMP` gesichert, repariert wird nur in einer
  Temp-Datei, und die aktive Datei wird nur ersetzt, wenn das Ergebnis gueltig
  ist. Ist die Reparatur unsicher, bleibt die aktive Datei unveraendert und ein
  Vorschlag wird als `services.tsv.repair-failed.TIMESTAMP` zur Diagnose abgelegt.
- `homeedge reload` verweigert das Neu-Generieren der Caddyfile bei defekter
  `services.tsv` und behaelt die letzte funktionierende Version.

## Fail2ban: IP entbannen

Im Menue unter `Fail2ban verwalten`:

```text
1) Status anzeigen
2) Gebannte IPs anzeigen
3) IP aus Liste auswaehlen und entbannen
4) IP manuell entbannen
...
```

Sind keine IPs gebannt, meldet HomeEdge: `Aktuell sind keine IPs gebannt.`

## Monitoring: Beszel Agent (optional)

HomeEdge kann optional einen [Beszel](https://github.com/henrygd/beszel) Agent
als systemd-Service installieren. Der Agent wird **nie automatisch** installiert,
sondern nur ueber `Hauptmenue -> Monitoring / Beszel Agent` bzw.
`sudo homeedge monitoring`.

Beim Setup fragt HomeEdge zuerst den **Betriebsmodus**:

**1) Pull / SSH (empfohlen):** Der Beszel Hub (z. B. auf dem Unraid-/Docker-Host,
`192.168.10.3`) verbindet sich ueber den WireGuard-Tunnel zum Agent auf dem VPS
(`10.0.0.1:45876`). Das System wird im Hub manuell hinzugefuegt (Host/IP + Port).
Benoetigt nur `KEY` (Public Key aus dem Hub), Agent-Port, WG-Interface und die
WG-IP des Hub - **kein** `HUB_URL`/`TOKEN`.

**2) WebSocket / Token (advanced):** Der Agent verbindet sich **aktiv** zum Hub
(`https://beszel.example.de`) - sinnvoll, wenn der Hub den Agent nicht direkt
erreichen kann. Benoetigt `KEY`, `HUB_URL`, `TOKEN`. Es ist **keine** eingehende
UFW-Regel noetig; HomeEdge prueft nur die ausgehende Erreichbarkeit der `HUB_URL`.

**Sicherheitsprinzip (Pull-Modus):** Der Agent-Port ist **ausschliesslich fuer die
WireGuard-IP des Hub** freigegeben - nie oeffentlich (weder IPv4 noch IPv6) und
**nicht** fuer beliebige WireGuard-Clients.

```text
Erlaubt:       Beszel-Hub 192.168.10.3 -> WireGuard/unifi -> VPS 10.0.0.1:45876
Nicht erlaubt: Internet -> oeffentliche VPS-IP:45876
               IPv6 oeffentlich -> VPS:45876
               beliebige WireGuard-Clients -> VPS:45876
               andere LAN-Hosts -> VPS:45876
```

- **Pull-Modus** setzt genau **eine** restriktive UFW-Regel, eingeschraenkt auf
  Interface **und** Hub-IP:
  `ufw allow in on <WG_IFACE> from <BESZEL_HUB_WG_IP> to any port <PORT> proto tcp comment 'Homeedge Beszel Agent'`.
  Kein `ufw allow 45876/tcp`, kein `from any`, kein `0.0.0.0/0`/`::/0`, keine reine
  Interface-Bindung ohne `from`. Der Agent bindet zudem bevorzugt direkt an die
  VPS-WireGuard-IP (`LISTEN="10.0.0.1:45876"`).
- **Port/Hub-IP/Modus aendern** (`beszel-reconfigure`): HomeEdge liest die alten
  Werte aus `/etc/homeedge/beszel.env`, entfernt die alte UFW-Regel, schreibt die
  neue Konfiguration, setzt (nur im Pull-Modus) die neue restriktive Regel und
  startet den Agent neu. Bei Wechsel Pull->WebSocket wird die eingehende Regel
  entfernt und `HUB_URL`/`TOKEN` gesetzt bzw. umgekehrt. Fehler beim Entfernen
  einer nicht (mehr) existierenden Regel werden ignoriert.
- **KEY-Validierung:** Der Public Key wird geprueft (`ssh-ed25519 AAAA...`); ein
  fehlendes Leerzeichen nach dem Typ (`ssh-ed25519AAAA...`) wird automatisch
  korrigiert. Ungueltige Keys werden **nicht** gespeichert - klare Fehlermeldung.
- Weitere Validierung: Port nur 1-65535, Hub-IP darf nicht leer sein, `0.0.0.0/0`
  und `::/0` werden abgelehnt, das WireGuard-Interface muss existieren.
- Eine **oeffentliche Freigabe** wird nur gemeldet, wenn UFW wirklich eine zu weite
  Regel enthaelt (`Anywhere`, `Anywhere (v6)`, `0.0.0.0/0`, `::/0`, Allow ohne
  Source-Einschraenkung). Eine korrekte `... ALLOW 192.168.10.3`-Regel gilt **nicht**
  als oeffentlich. **Fremde Regeln werden nie ungefragt geloescht.**
- Der Status zeigt (modusabhaengig): Betriebsmodus, installiert, Service aktiv,
  Version, LISTEN, Agent-Port, WG-Interface, erlaubter Hub (Pull), HUB_URL/TOKEN
  gesetzt (WebSocket), KEY gesetzt, UFW-Regel vorhanden, oeffentliche Freigabe,
  lauscht auf dem Port. `KEY` und `TOKEN` werden **nie** im Klartext angezeigt.
- Konfiguration in `/etc/homeedge/beszel.env` (`chmod 600`): `KEY`, `HUB_URL`,
  `TOKEN`, `LISTEN`, `BESZEL_MODE`, `BESZEL_AGENT_PORT`, `BESZEL_WG_IFACE`,
  `BESZEL_HUB_WG_IP`. Fuer die Firewall zaehlt **nur** `BESZEL_HUB_WG_IP`, nie
  `HUB_URL`. Es wird **kein** Beszel Hub installiert.
- Das Binary wird passend zur Architektur (amd64/arm64/armv7) heruntergeladen und
  atomar installiert; ein fehlgeschlagener Download laesst das alte Binary intakt.

Menue / CLI:

```text
1) Installieren                                5) Neu starten
2) Konfigurieren / Port, Modus oder Hub-IP     6) Aktualisieren
3) Status                                      7) Deinstallieren
4) Logs (-f)                                   8) Firewall-Regeln pruefen
```

```bash
sudo homeedge beszel-install         # fragt zuerst den Modus (Pull/WebSocket),
                                     # dann nur die je Modus noetigen Werte
sudo homeedge beszel-reconfigure     # Modus/Port/Hub-IP/Interface aendern (alte Regel raus, neue rein)
sudo homeedge beszel-status          # modusabhaengiger Status (ohne Secrets)
sudo homeedge beszel-logs -f         # journalctl -u beszel-agent -f (maskiert)
sudo homeedge beszel-check-firewall  # Regeln pruefen / restriktive Regel (neu) setzen
sudo homeedge beszel-uninstall       # fragt pro Artefakt (Binary, env, UFW-Regel) einzeln
```

`/etc/homeedge/beszel.env` im **Pull-Modus**:

```env
KEY="ssh-ed25519 AAAA..."
HUB_URL=""
TOKEN=""
LISTEN="10.0.0.1:45876"
BESZEL_MODE="pull"
BESZEL_AGENT_PORT="45876"
BESZEL_WG_IFACE="unifi"
BESZEL_HUB_WG_IP="192.168.10.3"
```

im **WebSocket-Modus**:

```env
KEY="ssh-ed25519 AAAA..."
HUB_URL="https://beszel.example.de"
TOKEN="..."
LISTEN=""
BESZEL_MODE="websocket"
BESZEL_AGENT_PORT="45876"
BESZEL_WG_IFACE=""
BESZEL_HUB_WG_IP=""
```

Bei der Deinstallation wird der Service gestoppt/deaktiviert, die systemd-Unit und
genau die eigene Beszel-UFW-Regel (anhand der gespeicherten Werte) entfernt;
Binary und `beszel.env` optional. Andere Firewall-Regeln bleiben unangetastet.

**Akzeptanz (Pull-Modus):** Der Agent-Port ist ueber die oeffentliche VPS-IP nicht
erreichbar (weder IPv4 noch IPv6), sondern nur von der angegebenen
Beszel-Hub-WireGuard-IP ueber das WireGuard-Interface.

## Security-Check

`sudo homeedge health` (oder Menue -> Sicherheitsmenue -> Ampel-Check komplett)
prueft Dienste, Firewall, Fail2ban, WireGuard-Handshake, Backends, DNS und
Zertifikate. Bewertung als einfache Ampel (ASCII):

```text
[GRUEN] sicher / aktiv
[GELB ] Hinweis / optional
[ROT  ] Problem
```

- Bei defekter `services.tsv` bricht der Check nicht ab: die Datei wird als
  eigener `[ROT]`-Punkt gemeldet, die uebrigen Checks (Docker, Caddy, UFW,
  Fail2ban, WireGuard) laufen trotzdem weiter. Der Gesamtstatus ist dann `[ROT]`
  und der Exitcode != 0.
- TLS/Zertifikate werden differenziert: `[GELB]` solange Caddy das Zertifikat
  per DNS-01 noch anfordert, `[ROT]` erst bei einem eindeutigen ACME-Fehler in
  den Logs (z. B. falscher Cloudflare Token) oder wenn Caddy gar nicht laeuft.
- Nach einem Wizard/Apply prueft `sudo homeedge verify-setup` den kompletten
  Stack (Caddy-Container laeuft, UFW aktiv, 443/tcp + WG-Port frei, Fail2ban,
  caddy-auth Jail, WireGuard-Interface, lokaler SNI-Test je Domain). Im
  Parallelbetrieb (`MIGRATION_MODE=1`) ist ein DNS-Eintrag, der noch auf den
  alten VPS zeigt, nur eine Warnung - der Rest muss trotzdem gruen sein.

## Diagnose & Tests

```bash
sudo homeedge domains            # pro Domain: Backend, erwartete VPS-IP, A/AAAA-Record, Bewertung
sudo homeedge test-domain DOMAIN # lokaler HTTPS-Test mit korrektem SNI
sudo homeedge reload             # Caddyfile neu erzeugen, validieren, reloaden, auf Zertifikat warten
```

Wichtig: Lokale HTTPS-Tests immer mit SNI per `--resolve` durchfuehren,
sonst schlaegt der Test fehl (kein SNI):

```bash
curl -vk --resolve DOMAIN:443:127.0.0.1 https://DOMAIN
# NICHT: curl -vk https://127.0.0.1 -H "Host: DOMAIN"
```

`homeedge reload` erzeugt das Caddyfile zuerst als `Caddyfile.generated`,
validiert es in einem Wegwerf-Container gegen das **bereits vorhandene** Image
(ohne die produktive Datei zu mounten), formatiert und validiert erneut, und
ersetzt die produktive `/opt/caddy-edge/Caddyfile` nur bei Erfolg. Danach wird die
aktive Config im laufenden Container neu geladen - per
`docker exec caddy-edge caddy reload` mit hartem Timeout
(`timeout --kill-after=5s 20s`), **nicht** ueber `docker compose exec` (das hing
nach einem erfolgreichen Caddy-Reload gelegentlich im Exec). Laeuft der
Reload-Befehl in ein Timeout, aber die Caddy-Logs zeigen `load complete` bzw.
`config is unchanged`, wertet HomeEdge das als Erfolg mit Warnung - es haengt
also nie endlos. Schlaegt der Reload echt fehl, gibt es **keinen** stillen
`up -d --force-recreate`, sondern eine klare Meldung und die Rueckfrage
„Caddy-Container neu erzeugen?".

**Der normale Reload baut nie ein Docker-Image.** Ist `homeedge-caddy:local`
vorhanden, startet weder `homeedge reload` noch die Migration jemals ein
`docker compose build`. Ein Image-Build laeuft ausschliesslich bei
Erstinstallation, `sudo homeedge caddy-rebuild`, `caddy-update` oder dem
Menuepunkt "Caddy neu bauen". Validate, `caddy fmt` und `caddy reload` haben je
ein Timeout von 20 s, damit ein kleiner VPS nicht haengt.

HomeEdge unterscheidet die Fehlerursachen klar, statt pauschal "Caddyfile
ungueltig" zu melden: **wirklich ungueltige Caddyfile** (die alte bleibt aktiv,
fehlerhafte Version als `/opt/caddy-edge/Caddyfile.failed`, echter
`caddy validate`-Output in `/var/log/homeedge/caddy-validate.log`), **Image
fehlt** bzw. **Cloudflare-Modul fehlt im Image** (Hinweis auf
`sudo homeedge caddy-rebuild`), **Validate-Timeout** oder **Abbruch (CTRL+C)**. In
diesen umgebungsbedingten Faellen bleibt die produktive Caddyfile aktiv, und eine
Migration gilt **nicht** als kaputt, solange Caddy laeuft und die produktive
Config valide ist.

Der Zertifikatscheck ist beim normalen Reload **kurz** (max. 15 s), damit der
Reload nicht blockiert; ein noch ausstehendes Zertifikat ist nur eine Warnung, ein
eindeutiger ACME-Fehler fuehrt zu Exitcode != 0. Der **lange** Check (bis 120 s,
DNS-01 kann dauern) laeuft nur nach Rebuild/Update oder ueber `sudo homeedge certs`
("Zertifikate pruefen"). `sudo homeedge caddy-rebuild` erzeugt den kompletten
Stack neu, wenn er fehlt oder kaputt ist.

## Cloudflare API Token

- Token aendern: `sudo homeedge set-token` (oder Menue -> Cloudflare API Token aendern).
  Token wird verdeckt eingelesen, bereinigt, optional gegen die Cloudflare
  Verify-API geprueft, in `/etc/homeedge/homeedge.env` und `/opt/caddy-edge/.env`
  geschrieben (immer einzeilig) und Caddy neu geladen.
- Neue Token im Format `cfut_...` werden unterstuetzt. Der `caddy-dns/cloudflare`
  Build (xcaddy) zieht die jeweils neueste Version, die diese Token akzeptiert.
  Falls noetig: Menue -> Wartung -> Caddy/Docker neu bauen (`docker compose build --pull`).
- HomeEdge zeigt Token nie im Klartext; Ausgaben/Logs werden maskiert.

## Wichtige Dateien auf dem VPS

```text
/usr/local/bin/homeedge
/usr/local/bin/edgectl -> Alias (Symlink)
/etc/homeedge/                         (Konfiguration, Keys, optional beszel.env)
/root/homeedge/
/opt/caddy-edge/                       (Caddyfile, Caddyfile.generated, .env, Compose)
/etc/wireguard/
/var/log/homeedge/caddy-validate.log   (echter caddy-validate-Output, maskiert)
/usr/local/bin/beszel-agent            (nur falls Beszel Agent installiert)
/etc/systemd/system/beszel-agent.service
```

Bei bestehenden Installationen migriert HomeEdge alte Daten aus `/etc/edgectl/`
und `/root/vps-edge/`.

## Sicherheit / Secrets

- Lokale Installer-Configs (`*.config.env`, `*.config.json`) koennen den
  Cloudflare API Token enthalten und sind per `.gitignore` ausgeschlossen.
- Das Install-Log (`/root/edge-install.log`) enthaelt **keine** WireGuard-Keys.
- HomeEdge aendert den sshd-Port nicht selbst; der aktuell genutzte SSH-Port
  bleibt in der Firewall immer offen, damit du dich nicht aussperrst.

## Hinweise zu Jellyfin

- Jellyfin braucht intern kein HTTPS, Caddy macht HTTPS aussen.
- In Cloudflare DNS only / graue Wolke verwenden.
- In Jellyfin als Known Proxy die VPS-WireGuard-IP eintragen, z. B. `10.0.1.1`.
- In UniFi nur erlauben: VPS-WG-IP -> Backend-IP:Port.
- Beim Anlegen eines Dienstes kann ein Profil gewaehlt werden
  (Standard / Jellyfin / Jellyseerr). Das Jellyfin-Profil setzt im Caddy-Block
  `flush_interval -1` (besseres Streaming). X-Forwarded-Header setzt Caddy selbst.
