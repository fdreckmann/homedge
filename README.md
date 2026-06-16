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

Das Terminal-Menue ist in neun Gruppen mit Breadcrumb (z. B. `HomeEdge > Sicherheit`)
und je `b) Zurueck` / `0) Beenden` organisiert:

```text
1) Status / Ampel            6) Backup & Restore
2) Domains & Dienste         7) Updates & Wartung
3) WireGuard Tunnel          8) Logs & Diagnose
4) Caddy / HTTPS / Cloudflare 9) Einstellungen
5) Sicherheit                0) Beenden
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
`homeedge wg-menu`, `homeedge network`. Weitere: `homeedge reload`, `certs`,
`domains`, `test-domain DOMAIN`, `set-token`, `mtu`, `migrate`, `rollback`.

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

Im Menue unter `Wartung / Updates`:

```text
1) HomeEdge-Version anzeigen
2) Nach Update suchen
3) HomeEdge aus GitHub aktualisieren (empfohlen)
4) Caddy/Docker neu bauen und aktualisieren
5) Systemupdates installieren
6) Backup vor Update erstellen
7) Rollback auf letztes Backup
```

- Standardquelle ist `https://raw.githubusercontent.com/fdreckmann/homedge/main/homeedge.sh`.
- Vor jedem Update wird automatisch ein Backup erstellt.
- Der Download wird geprueft (HomeEdge-Marker, optionale SHA256, `bash -n`),
  bevor er installiert wird. Bei Fehlern bleibt die laufende Version unveraendert.
- Repo/Branch aendern: `sudo homeedge set-repo`.
- Empfehlung: nicht blind von `main`, sondern bevorzugt getaggte Releases nutzen.
- Nach dem Update laeuft automatisch eine Migration (`sudo homeedge migrate`):
  Cloudflare-Token wird bereinigt (immer einzeilig), fehlende Werte werden
  ergaenzt (`ENABLE_HTTP3=0`, `WG_MTU=1280`, Fail2ban-Schwellenwerte), die
  Caddyfile neu erzeugt/validiert und ein Healthcheck ausgefuehrt. Bestehende
  Dienste, Zertifikate und WireGuard-Keys bleiben erhalten.

## HTTP/3 / QUIC und Firewall

- Standard ist `ENABLE_HTTP3=0` (nur HTTP/1.1 + HTTP/2, UFW oeffnet nur 443/tcp).
  Fuer Jellyfin erstmal AUS empfohlen.
- Die Installer fragen HTTP/3 beim Setup ab (Default: nein); der Bootstrap
  oeffnet `443/udp` nur, wenn HTTP/3 aktiviert wurde.
- Aktivieren ueber `Caddy / HTTPS / Cloudflare -> HTTP/3 aktivieren/deaktivieren`;
  dabei wird `443/udp` in UFW passend geoeffnet bzw. wieder geschlossen.
- `sudo homeedge firewall` setzt UFW passend zur Konfiguration (443/udp nur bei HTTP/3).

## WireGuard MTU

- Standard `WG_MTU=1280`, wird in `/etc/wireguard/<if>.conf` geschrieben.
- Aendern ueber `WireGuard Tunnel -> MTU anzeigen/aendern` (oder `sudo homeedge mtu`).
- Hinweis: MTU ggf. auch auf UniFi-Seite setzen, falls dort ein MTU-Feld existiert.

## Backup / Restore

Im Menue unter `Backup / Restore`. Ein Backup enthaelt:

```text
/etc/homeedge        HomeEdge-Konfiguration, Keys
/etc/wireguard       WireGuard-Konfiguration
/opt/caddy-edge      Caddy (Caddyfile, Compose, Daten)
Fail2ban-Konfiguration
UFW-Regeln
/usr/local/bin/homeedge  (Binary/Script)
```

- Vor kritischen Aenderungen bietet HomeEdge automatisch ein Backup an.
- Restore warnt deutlich und ueberschreibt die aktuelle Konfiguration.
- **WICHTIG: Backups enthalten Secrets** (WireGuard-Keys, Cloudflare Token).
  Niemals unverschluesselt teilen oder ins Repo legen.

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

## Security-Check

`sudo homeedge health` (oder Menue -> Sicherheitsmenue -> Ampel-Check komplett)
prueft Dienste, Firewall, Fail2ban, WireGuard-Handshake, Backends, DNS und
Zertifikate. Bewertung als einfache Ampel (ASCII):

```text
[GRUEN] sicher / aktiv
[GELB ] Hinweis / optional
[ROT  ] Problem
```

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

`homeedge reload` erzeugt das Caddyfile immer komplett aus der Service-Liste,
validiert es, ersetzt es atomar und wartet danach bis zu 120 s auf das
Zertifikat (DNS-01 kann etwas dauern). Ist es noch nicht fertig, gibt es eine
Warnung statt eines harten Fehlers.

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
/etc/homeedge/
/root/homeedge/
/opt/caddy-edge/
/etc/wireguard/
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
