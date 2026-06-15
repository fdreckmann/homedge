# HomeEdge

HomeEdge ist ein schlankes VPS-Gateway für Home-Services wie Jellyfin.

Datenfluss:

```text
Internet -> VPS/Caddy -> WireGuard -> UniFi -> interner Dienst
```

Security-Stack:

```text
UFW Firewall
Fail2ban fuer SSH und optional Caddy/Jellyfin 401/403
Caddy Reverse Proxy mit automatischen Let's-Encrypt-Zertifikaten
WireGuard Tunnel mit optionalem Preshared Key
UniFi Firewall nur VPS-WG-IP -> Backend-IP:Port
automatische Sicherheitsupdates
```

## Befehle auf dem VPS

```bash
sudo homeedge menu
sudo homeedge health
sudo homeedge certs
sudo homeedge status
sudo homeedge wg-values
sudo homeedge fail2ban
sudo homeedge backup
sudo homeedge update
```

`edgectl` bleibt als Kompatibilitaets-Alias erhalten:

```bash
sudo edgectl menu
```

## Installation von Windows

ZIP entpacken und PowerShell im Ordner öffnen:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-EdgeVps.ps1
```

Nach der Installation fragt das Script, ob direkt eine SSH-Sitzung geöffnet und das HomeEdge-Menü gestartet werden soll.

## Installation von Linux/macOS

ZIP entpacken und Terminal im Ordner öffnen:

```bash
chmod +x Install-EdgeVps.sh
./Install-EdgeVps.sh
```

Nach der Installation fragt das Script, ob direkt per SSH auf den VPS gewechselt und `sudo homeedge menu` gestartet werden soll.

## Direkt auf dem VPS installieren

Repo klonen (oder ZIP entpacken) und dort ausführen:

```bash
sudo apt update
sudo apt install git -y
git clone https://github.com/fdreckmann/homedge.git
cd homedge
sudo bash Install-Direct-OnVps.sh
```

Alternativ per ZIP:

```bash
sudo apt install unzip -y
unzip homeedge-vps-gateway.zip
cd homeedge-package
sudo bash Install-Direct-OnVps.sh
```

## Nur HomeEdge aktualisieren

Windows:

```powershell
powershell -ExecutionPolicy Bypass -File .\Update-HomeEdgeOnly.ps1
```

Linux/macOS:

```bash
chmod +x Update-HomeEdgeOnly.sh
./Update-HomeEdgeOnly.sh
```

## Update-Funktion im Programm

Im Menü:

```text
Wartung / Updates
```

Dort kannst du:

```text
Version anzeigen
Update-Quelle setzen, z. B. GitHub Release Download-URL
HomeEdge aus der Update-Quelle aktualisieren
Caddy/Docker aktualisieren
Systemupdates ausführen
Backup vor Update erstellen
```

Empfohlene GitHub-Quelle später:

```text
https://github.com/USER/REPO/releases/latest/download/homeedge.sh
```

Nicht empfohlen: blind von `main` installieren.

## Wichtige Dateien auf dem VPS

```text
/usr/local/bin/homeedge
/usr/local/bin/edgectl -> Alias
/etc/homeedge/
/root/homeedge/
/opt/caddy-edge/
/etc/wireguard/
```

Bei bestehenden Installationen migriert HomeEdge alte Daten aus:

```text
/etc/edgectl/
/root/vps-edge/
```

## Hinweise

- Jellyfin selbst braucht intern kein HTTPS. Caddy macht HTTPS außen.
- Für Jellyfin Cloudflare DNS only / graue Wolke verwenden.
- In Jellyfin als Known Proxy die VPS-WireGuard-IP eintragen, z. B. `10.0.1.1`.
- In UniFi nur erlauben: VPS-WG-IP -> Backend-IP:Port.
- Backups enthalten Secrets wie WireGuard Keys und Cloudflare Token.

## Sicherheit / Secrets

- Lokale Installer-Configs (`*.config.env`, `*.config.json`) können den
  Cloudflare API Token enthalten und sind per `.gitignore` vom Repo
  ausgeschlossen. Niemals einchecken.
- Das Install-Log (`/root/edge-install.log`) enthält **keine** WireGuard-Keys.
  Die Werte stehen in `/root/homeedge/unifi-wireguard-werte.txt` (chmod 600)
  und über `sudo homeedge wg-values`.
- HomeEdge ändert den sshd-Port **nicht** selbst. Der abgefragte SSH-Port gilt
  nur für UFW/Fail2ban. Der aktuell genutzte SSH-Port bleibt in der Firewall
  immer offen, damit du dich nicht aussperrst.
