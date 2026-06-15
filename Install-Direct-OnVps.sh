#!/usr/bin/env bash
set -Eeuo pipefail

# Install-Direct-OnVps.sh
# Direkt auf dem VPS ausführen.
# Voraussetzungen: Dieses Script liegt im gleichen Ordner wie homeedge.sh und remote-bootstrap.template.sh
# Start:
#   sudo bash Install-Direct-OnVps.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${SCRIPT_DIR}/Install-Direct-OnVps.config.env"
HOMEEDGE_PATH="${SCRIPT_DIR}/homeedge.sh"
BOOTSTRAP_TEMPLATE="${SCRIPT_DIR}/remote-bootstrap.template.sh"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Bitte direkt auf dem VPS als root ausführen: sudo bash Install-Direct-OnVps.sh"
  exit 1
fi

if [[ ! -f "$HOMEEDGE_PATH" ]]; then
  echo "FEHLER: homeedge.sh nicht gefunden im Ordner: $SCRIPT_DIR"
  exit 1
fi
if [[ ! -f "$BOOTSTRAP_TEMPLATE" ]]; then
  echo "FEHLER: remote-bootstrap.template.sh nicht gefunden im Ordner: $SCRIPT_DIR"
  exit 1
fi

ask() {
  local prompt="$1"
  local default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " value
    printf '%s' "${value:-$default}"
  else
    read -r -p "$prompt: " value
    printf '%s' "$value"
  fi
}

yesno() {
  local prompt="$1"
  local default="${2:-n}"
  local value
  read -r -p "$prompt [$default]: " value
  value="${value:-$default}"
  [[ "$value" =~ ^([YyJj]|yes|YES|ja|JA)$ ]]
}

ask_secret() {
  local prompt="$1"
  local value
  read -r -s -p "$prompt: " value
  echo >&2
  printf '%s' "$value"
}

b64() { printf '%s' "${1:-}" | base64 | tr -d '\n'; }
b64_file() { base64 < "$1" | tr -d '\n'; }

cfg_get() {
  local name="$1"
  local default="${2:-}"
  local val="${!name:-}"
  if [[ -n "$val" ]]; then printf '%s' "$val"; else printf '%s' "$default"; fi
}

select_local_interface() {
  local default_if="$1"
  local default_name default_src
  default_name="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')"
  default_src="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')"

  mapfile -t ifs < <(ls /sys/class/net | sort)
  # Wichtig: Diese Funktion wird via $(...) aufgerufen. Alle Anzeige-Ausgaben
  # muessen nach stderr (>&2), damit nur der gewaehlte Interface-Name auf
  # stdout zurueckkommt. Sonst landet die Liste in der Variable und der
  # Nutzer sieht nichts.
  echo >&2
  echo "Gefundene Netzwerkadapter:" >&2
  echo >&2
  local default_idx=""
  for i in "${!ifs[@]}"; do
    local n="${ifs[$i]}"
    local num=$((i+1))
    local state ipv4 ipv6 hint
    state="$(cat /sys/class/net/$n/operstate 2>/dev/null || echo unknown)"
    ipv4="$(ip -o -4 addr show dev "$n" scope global 2>/dev/null | awk '{print $4}' | paste -sd ',' -)"
    ipv6="$(ip -o -6 addr show dev "$n" scope global 2>/dev/null | awk '{print $4}' | paste -sd ',' -)"
    [[ -z "$ipv4" ]] && ipv4="-"
    [[ -z "$ipv6" ]] && ipv6="-"
    hint=""
    if [[ "$n" == "$default_name" ]]; then
      hint=" <= Default-Route / Internet"
      default_idx="$num"
    fi
    if [[ "$n" == "$default_if" && "$default_if" != "$default_name" ]]; then
      hint="$hint <= Config-Vorschlag"
    fi
    printf "%2d) %-14s Status: %-8s IPv4: %-24s IPv6: %s%s\n" "$num" "$n" "$state" "$ipv4" "$ipv6" "$hint" >&2
  done
  echo >&2
  if [[ -n "$default_name" ]]; then
    echo "Empfehlung: $default_name" >&2
    [[ -n "$default_src" ]] && echo "Source-IP Richtung Internet: $default_src" >&2
  fi
  echo >&2
  local def_answer="${default_idx:-1}"
  local choice
  choice="$(ask "Netzwerkadapter auswaehlen (Nummer oder Interface-Name)" "$def_answer")"
  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    local idx=$((choice-1))
    if (( idx >= 0 && idx < ${#ifs[@]} )); then
      printf '%s' "${ifs[$idx]}"
      return
    fi
  fi
  printf '%s' "$choice"
}

save_config() {
  local save_token="$1"
  umask 077
  cat > "$CONFIG_PATH" <<EOF
VpsPublicHost=$(printf '%q' "$VpsPublicHost")
ExtIf=$(printf '%q' "$ExtIf")
SshPortFinal=$(printf '%q' "$SshPortFinal")
WgIf=$(printf '%q' "$WgIf")
WgPort=$(printf '%q' "$WgPort")
VpsWgAddr=$(printf '%q' "$VpsWgAddr")
ClientWgAddr=$(printf '%q' "$ClientWgAddr")
HomeSubnet=$(printf '%q' "$HomeSubnet")
AcmeEmail=$(printf '%q' "$AcmeEmail")
UsePsk=$(printf '%q' "$UsePsk")
EnableCaddyFail2ban=$(printf '%q' "$EnableCaddyFail2ban")
ClientPublicKey=$(printf '%q' "$ClientPublicKey")
SwapMb=$(printf '%q' "$SwapMb")
CreateAdmin=$(printf '%q' "$CreateAdmin")
AdminUser=$(printf '%q' "$AdminUser")
ServicesTsvB64=$(printf '%q' "$(b64 "$ServicesTsv")")
EOF
  if [[ "$save_token" == "1" ]]; then
    cat >> "$CONFIG_PATH" <<EOF
CloudflareApiToken=$(printf '%q' "$CfToken")
EOF
  fi
  chmod 600 "$CONFIG_PATH"
  echo "Config gespeichert: $CONFIG_PATH"
}

replace_token() {
  local token="$1"
  local value="$2"
  BOOTSTRAP="${BOOTSTRAP//$token/$value}"
}

clear
cat <<'EOF'
============================================================
 HomeEdge Direkt-Installer
============================================================
Dieses Script läuft direkt auf dem VPS.
Es installiert WireGuard, Caddy, Docker, Fail2ban, UFW und homeedge.
============================================================
EOF

if [[ -f "$CONFIG_PATH" ]]; then
  echo
  echo "Vorhandene HomeEdge-Konfiguration gefunden:"
  echo "  $CONFIG_PATH"
  echo
  if yesno "Diese Werte als Vorschlag verwenden?" "y"; then
    # shellcheck disable=SC1090
    source "$CONFIG_PATH"
    if [[ -n "${ServicesTsvB64:-}" ]]; then
      ServicesTsv="$(printf '%s' "$ServicesTsvB64" | base64 -d)"
    fi
    echo "Werte geladen. Alle Eingaben sind als Default vorausgefuellt und koennen ueberschrieben werden."
  fi
fi

PublicAuto="$(curl -4fsS https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
VpsPublicHost="$(ask "Oeffentliche VPS-IP oder DNS-Name" "$(cfg_get VpsPublicHost "$PublicAuto")")"

if yesno "Netzwerkadapter anzeigen und aus Liste waehlen?" "y"; then
  ExtIf="$(select_local_interface "$(cfg_get ExtIf eth0)")"
else
  ExtIf="$(ask "Externes Interface auf dem VPS" "$(cfg_get ExtIf eth0)")"
fi

SshPortFinal="$(ask "SSH Port auf dem VPS" "$(cfg_get SshPortFinal 22)")"
WgIf="$(ask "WireGuard Interface Name" "$(cfg_get WgIf unifi)")"
WgPort="$(ask "WireGuard UDP Port" "$(cfg_get WgPort 51821)")"
VpsWgAddr="$(ask "VPS WireGuard Adresse mit CIDR" "$(cfg_get VpsWgAddr 10.0.1.1/24)")"
ClientWgAddr="$(ask "UniFi/Client WireGuard Adresse mit CIDR" "$(cfg_get ClientWgAddr 10.0.1.2/32)")"
HomeSubnet="$(ask "Backend-Netze hinter UniFi, komma-getrennt" "$(cfg_get HomeSubnet 192.168.10.0/24)")"
AcmeEmail="$(ask "E-Mail fuer Let's Encrypt" "$(cfg_get AcmeEmail '')")"

if [[ -n "${CloudflareApiToken:-}" ]]; then
  if yesno "Gespeicherten Cloudflare API Token verwenden?" "y"; then
    CfToken="$CloudflareApiToken"
  else
    CfToken="$(ask_secret "Cloudflare API Token")"
  fi
else
  CfToken="$(ask_secret "Cloudflare API Token")"
fi

UsePsk="$(cfg_get UsePsk 1)"
if yesno "WireGuard PresharedKey verwenden?" "$([[ "$UsePsk" == "1" ]] && echo y || echo n)"; then UsePsk="1"; else UsePsk="0"; fi

echo
echo "Empfohlen: Ja."
echo "Schuetzt gegen viele fehlerhafte Login-/Auth-Versuche (401/403)."
echo "Gebannte IPs koennen spaeter im HomeEdge-Menue wieder entbannt werden."
EnableCaddyFail2ban="$(cfg_get EnableCaddyFail2ban 1)"
if yesno "Fail2ban fuer Caddy/Jellyfin 401/403 aktivieren?" "$([[ "$EnableCaddyFail2ban" == "0" ]] && echo n || echo y)"; then EnableCaddyFail2ban="1"; else EnableCaddyFail2ban="0"; fi

ClientPublicKey="$(ask "UniFi/Client WireGuard PublicKey optional" "$(cfg_get ClientPublicKey '')")"
SwapMb="$(ask "Swap Groesse in MB" "$(cfg_get SwapMb 2048)")"

if [[ -n "${ServicesTsv:-}" ]] && yesno "Gespeicherte Dienste verwenden?" "y"; then
  :
else
  echo
  echo "Externe Dienste erfassen. Beispiel: jellyfin.domain.de | http | 192.168.10.99 | 8096"
  ServiceCount="$(ask "Anzahl externe Dienste" "1")"
  [[ "$ServiceCount" =~ ^[0-9]+$ ]] || { echo "Ungueltige Anzahl, nutze 1."; ServiceCount=1; }
  ServicesTsv=""
  for ((i=1; i<=ServiceCount; i++)); do
    echo
    echo "Dienst $i"
    d="$(ask "Domain")"
    s="$(ask "Backend Scheme http/https" "http")"
    ip="$(ask "Backend IP im Heimnetz")"
    p="$(ask "Backend Port")"
    ServicesTsv+="${d}"$'\t'"${s}"$'\t'"${ip}"$'\t'"${p}"$'\n'
  done
fi

CreateAdmin="$(cfg_get CreateAdmin 0)"
AdminUser="$(cfg_get AdminUser admin)"
AdminPubKey=""
if yesno "Optional: Admin-User mit SSH-Key erstellen und Root/Password-SSH deaktivieren?" "$([[ "$CreateAdmin" == "1" ]] && echo y || echo n)"; then
  CreateAdmin="1"
  AdminUser="$(ask "Neuer Admin-User" "$AdminUser")"
  echo "Public Key einfügen, z. B. ssh-ed25519 AAAA... user@pc"
  AdminPubKey="$(ask "Public Key")"
else
  CreateAdmin="0"
fi

SaveToken="0"
if yesno "Eingaben fuer naechstes Mal speichern?" "y"; then
  if yesno "Cloudflare Token auch speichern? Datei ist nur chmod 600, nicht verschluesselt" "n"; then SaveToken="1"; fi
  save_config "$SaveToken"
fi

SvcPretty="$(printf '%s' "$ServicesTsv" | awk -F'\t' 'NF>=4{printf "  %d) %-22s -> %s://%s:%s\n", ++n, $1, $2, $3, $4}')"
[[ -z "$SvcPretty" ]] && SvcPretty="  (keine Dienste erfasst)"
F2bCaddyState="$([[ "$EnableCaddyFail2ban" == "1" ]] && echo aktiv || echo inaktiv)"
TokenState="$([[ -n "${CfToken:-}" ]] && echo gesetzt || echo "nicht gesetzt")"
HardeningState="$([[ "$CreateAdmin" == "1" ]] && echo "ja (neuer User: ${AdminUser})" || echo nein)"

cat <<EOF

============================================================
HomeEdge Installationszusammenfassung
============================================================

VPS:
  Host/IP:        $VpsPublicHost
  Interface:      $ExtIf
  SSH-Port:       $SshPortFinal

WireGuard:
  Interface:      $WgIf
  UDP-Port:       $WgPort
  VPS WG-IP:      $VpsWgAddr
  Client WG-IP:   $ClientWgAddr
  Backend-Netze:  $HomeSubnet

Dienste:
$SvcPretty

Security:
  UFW:              wird aktiviert
  Fail2ban SSH:     wird aktiviert
  Fail2ban Caddy:   $F2bCaddyState
  Cloudflare Token: $TokenState
  SSH Hardening:    $HardeningState
============================================================

Achtung:
Ab jetzt werden Pakete installiert und folgende Komponenten konfiguriert:
- Docker / Caddy
- WireGuard
- UFW Firewall
- Fail2ban
- automatische Updates
- Swap
- HomeEdge Menue

Bitte pruefe die Zusammenfassung oben genau.
EOF

if ! yesno "Konfiguration uebernehmen und Installation jetzt starten?" "n"; then
  save_config "${SaveToken:-0}"
  echo
  echo "Installation abgebrochen."
  echo "Die eingegebene Konfiguration wurde gespeichert und kann beim naechsten Start wiederverwendet werden."
  exit 0
fi

BOOTSTRAP="$(cat "$BOOTSTRAP_TEMPLATE")"
HOMEEDGE_B64="$(b64_file "$HOMEEDGE_PATH")"

replace_token "__EXT_IF_B64__" "$(b64 "$ExtIf")"
replace_token "__VPS_PUBLIC_HOST_B64__" "$(b64 "$VpsPublicHost")"
replace_token "__SSH_PORT_B64__" "$(b64 "$SshPortFinal")"
replace_token "__WG_IF_B64__" "$(b64 "$WgIf")"
replace_token "__WG_PORT_B64__" "$(b64 "$WgPort")"
replace_token "__VPS_WG_ADDR_B64__" "$(b64 "$VpsWgAddr")"
replace_token "__CLIENT_WG_ADDR_B64__" "$(b64 "$ClientWgAddr")"
replace_token "__HOME_SUBNET_B64__" "$(b64 "$HomeSubnet")"
replace_token "__ACME_EMAIL_B64__" "$(b64 "$AcmeEmail")"
replace_token "__CF_TOKEN_B64__" "$(b64 "$CfToken")"
replace_token "__USE_PSK_B64__" "$(b64 "$UsePsk")"
replace_token "__CADDY_FAIL2BAN_B64__" "$(b64 "$EnableCaddyFail2ban")"
replace_token "__CLIENT_PUBLIC_KEY_B64__" "$(b64 "$ClientPublicKey")"
replace_token "__SERVICES_TSV_B64__" "$(b64 "$ServicesTsv")"
replace_token "__SWAP_MB_B64__" "$(b64 "$SwapMb")"
replace_token "__CREATE_ADMIN_B64__" "$(b64 "$CreateAdmin")"
replace_token "__ADMIN_USER_B64__" "$(b64 "$AdminUser")"
replace_token "__ADMIN_PUBKEY_B64__" "$(b64 "$AdminPubKey")"
replace_token "__HOMEEDGE_B64__" "$HOMEEDGE_B64"

printf '%s' "$BOOTSTRAP" > /tmp/edge-bootstrap-direct.sh
chmod +x /tmp/edge-bootstrap-direct.sh
bash -lc '/tmp/edge-bootstrap-direct.sh 2>&1 | tee /root/edge-install.log'

echo
echo "Fertig. Menü starten mit: sudo homeedge menu"
