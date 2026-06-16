#!/usr/bin/env bash
set -Eeuo pipefail

# Install-EdgeVps.sh
# Linux/macOS Installer fuer den Edge-VPS.
# Starten mit:
#   chmod +x Install-EdgeVps.sh
#   ./Install-EdgeVps.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${SCRIPT_DIR}/Install-EdgeVps.config.env"

if [[ "${1:-}" == "--config" && -n "${2:-}" ]]; then
  CONFIG_PATH="$2"
fi

HOMEEDGE_PATH="${SCRIPT_DIR}/homeedge.sh"
EDGECTL_PATH="$HOMEEDGE_PATH"
BOOTSTRAP_TEMPLATE="${SCRIPT_DIR}/remote-bootstrap.template.sh"

if [[ ! -f "$EDGECTL_PATH" ]]; then
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

b64() {
  # funktioniert unter Linux und macOS; entfernt Zeilenumbrueche
  printf '%s' "${1:-}" | base64 | tr -d '\n'
}

b64_file() {
  base64 < "$1" | tr -d '\n'
}

cfg_get() {
  local name="$1"
  local default="${2:-}"
  local val="${!name:-}"
  if [[ -n "$val" ]]; then
    printf '%s' "$val"
  else
    printf '%s' "$default"
  fi
}

save_config() {
  local save_token="$1"
  umask 077
  cat > "$CONFIG_PATH" <<EOF
SshHost=$(printf '%q' "$SshHost")
SshUser=$(printf '%q' "$SshUser")
SshPortConnect=$(printf '%q' "$SshPortConnect")
SshKeyPath=$(printf '%q' "$SshKeyPath")
VpsPublicHost=$(printf '%q' "$VpsPublicHost")
ExtIf=$(printf '%q' "$ExtIf")
SshPortFinal=$(printf '%q' "$SshPortFinal")
WgIf=$(printf '%q' "$WgIf")
WgPort=$(printf '%q' "$WgPort")
WgMtu=$(printf '%q' "${WgMtu:-1280}")
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
AdminPubKeyPath=$(printf '%q' "$AdminPubKeyPath")
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

build_ssh_args() {
  SSH_ARGS=()
  if [[ -n "${SshKeyPath:-}" ]]; then
    SSH_ARGS+=("-i" "$SshKeyPath")
  fi
  SSH_ARGS+=("-p" "$SshPortConnect" "${SshUser}@${SshHost}")
}

run_remote_bash() {
  local script_text="$1"
  build_ssh_args
  printf '%s' "$script_text" | ssh "${SSH_ARGS[@]}" "bash -s"
}

select_remote_interface() {
  local default_if="$1"
  # Wichtig: Wird via $(...) aufgerufen. Alle Anzeige-Ausgaben nach stderr (>&2),
  # damit nur der gewaehlte Interface-Name auf stdout zurueckkommt.
  echo >&2
  echo "Netzwerkadapter werden vom VPS ausgelesen..." >&2
  echo "Falls du Passwort-Login nutzt, fragt SSH jetzt ggf. nach dem Passwort." >&2
  echo >&2

  local remote_script
  remote_script=$(cat <<'EOS'
def=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}')
src=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')
echo "__DEFAULT__|${def}|${src}"
for n in $(ls /sys/class/net | sort); do
  state=$(cat /sys/class/net/$n/operstate 2>/dev/null || echo unknown)
  ipv4=$(ip -o -4 addr show dev "$n" scope global 2>/dev/null | awk '{print $4}' | paste -sd ',' -)
  ipv6=$(ip -o -6 addr show dev "$n" scope global 2>/dev/null | awk '{print $4}' | paste -sd ',' -)
  [ -z "$ipv4" ] && ipv4="-"
  [ -z "$ipv6" ] && ipv6="-"
  echo "__IF__|${n}|${state}|${ipv4}|${ipv6}"
done
EOS
)

  local out
  if ! out="$(run_remote_bash "$remote_script")"; then
    echo "Adapter konnten nicht automatisch ausgelesen werden." >&2
    ask "Externes Interface auf dem VPS" "$default_if"
    return
  fi

  local default_name=""
  local default_src=""
  local -a names states ipv4s ipv6s
  while IFS= read -r line; do
    if [[ "$line" == __DEFAULT__\|* ]]; then
      IFS='|' read -r _ default_name default_src <<< "$line"
    elif [[ "$line" == __IF__\|* ]]; then
      local _tag n s i4 i6
      IFS='|' read -r _tag n s i4 i6 <<< "$line"
      names+=("$n")
      states+=("$s")
      ipv4s+=("$i4")
      ipv6s+=("$i6")
    fi
  done <<< "$out"

  if [[ ${#names[@]} -eq 0 ]]; then
    echo "Keine Adapterdaten erhalten. Roh-Ausgabe:" >&2
    echo "$out" >&2
    ask "Externes Interface auf dem VPS" "$default_if"
    return
  fi

  echo "Gefundene Netzwerkadapter:" >&2
  echo >&2
  local default_idx=""
  for i in "${!names[@]}"; do
    local num=$((i+1))
    local hint=""
    if [[ "${names[$i]}" == "$default_name" ]]; then
      hint=" <= Default-Route / Internet"
      default_idx="$num"
    fi
    if [[ "${names[$i]}" == "$default_if" && "$default_if" != "$default_name" ]]; then
      hint="$hint <= Config-Vorschlag"
    fi
    printf "%2d) %-14s Status: %-8s IPv4: %-24s IPv6: %s%s\n" "$num" "${names[$i]}" "${states[$i]}" "${ipv4s[$i]}" "${ipv6s[$i]}" "$hint" >&2
  done
  echo >&2
  if [[ -n "$default_name" ]]; then
    echo "Empfehlung: $default_name" >&2
    [[ -n "$default_src" ]] && echo "Source-IP Richtung Internet: $default_src" >&2
  fi
  echo >&2

  local def_answer="${default_idx:-$default_if}"
  [[ -z "$def_answer" ]] && def_answer="1"
  local choice
  choice="$(ask "Netzwerkadapter auswaehlen (Nummer oder Interface-Name)" "$def_answer")"
  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    local idx=$((choice-1))
    if (( idx >= 0 && idx < ${#names[@]} )); then
      printf '%s' "${names[$idx]}"
      return
    fi
    printf '%s' "$default_if"
    return
  fi
  printf '%s' "$choice"
}

count_services() {
  local tsv="$1"
  if [[ -z "$tsv" ]]; then echo 0; return; fi
  printf '%s' "$tsv" | awk 'NF{c++} END{print c+0}'
}

echo
echo "============================================================"
echo " HomeEdge Installer fuer PIKO/Nano - Linux/macOS"
echo "============================================================"
echo

if [[ -f "$CONFIG_PATH" ]]; then
  echo "Vorhandene Config gefunden: $CONFIG_PATH"
  if yesno "Diese Werte als Vorschlag verwenden?" "y"; then
    # shellcheck disable=SC1090
    source "$CONFIG_PATH"
    echo "Config geladen. Alle Werte koennen trotzdem ueberschrieben werden."
  fi
fi

SshHost="$(ask "VPS IP oder Hostname fuer SSH" "$(cfg_get SshHost "")")"
SshUser="$(ask "SSH Benutzer fuer initialen Login" "$(cfg_get SshUser "root")")"
SshPortConnect="$(ask "SSH Port fuer initialen Login" "$(cfg_get SshPortConnect "22")")"
SshKeyPath="$(ask "SSH Key Pfad optional, leer lassen falls Passwortlogin" "$(cfg_get SshKeyPath "")")"

VpsPublicHost="$(ask "Oeffentliche VPS-IP oder DNS-Name fuer WireGuard Endpoint" "$(cfg_get VpsPublicHost "$SshHost")")"
ExtIfDefault="$(cfg_get ExtIf "eth0")"
if yesno "Netzwerkadapter vom VPS anzeigen und auswaehlen?" "y"; then
  ExtIf="$(select_remote_interface "$ExtIfDefault")"
else
  ExtIf="$(ask "Externes Interface auf dem VPS" "$ExtIfDefault")"
fi
SshPortFinal="$(ask "SSH Port auf dem VPS" "$(cfg_get SshPortFinal "$SshPortConnect")")"

WgIf="$(ask "WireGuard Interface Name" "$(cfg_get WgIf "unifi")")"
WgPort="$(ask "WireGuard UDP Port" "$(cfg_get WgPort "51821")")"
WgMtu="$(ask "WireGuard MTU" "$(cfg_get WgMtu "1280")")"
[[ "$WgMtu" =~ ^[0-9]+$ ]] || WgMtu=1280
VpsWgAddr="$(ask "VPS WireGuard Adresse mit CIDR" "$(cfg_get VpsWgAddr "10.0.1.1/24")")"
ClientWgAddr="$(ask "UniFi/Client WireGuard Adresse mit CIDR" "$(cfg_get ClientWgAddr "10.0.1.2/32")")"
HomeSubnet="$(ask "Heimnetz/Subnetz hinter UniFi" "$(cfg_get HomeSubnet "192.168.10.0/24")")"

AcmeEmail="$(ask "E-Mail fuer Let's Encrypt" "$(cfg_get AcmeEmail "")")"
SavedToken="$(cfg_get CloudflareApiToken "")"
if [[ -n "$SavedToken" ]] && yesno "Gespeicherten Cloudflare API Token verwenden?" "y"; then
  CfToken="$SavedToken"
else
  CfToken="$(ask_secret "Cloudflare API Token")"
fi

if yesno "WireGuard PresharedKey verwenden?" "$( [[ "$(cfg_get UsePsk "1")" == "1" ]] && echo y || echo n )"; then
  UsePsk="1"
else
  UsePsk="0"
fi
echo
echo "Empfohlen: Ja."
echo "Schuetzt gegen viele fehlerhafte Login-/Auth-Versuche (401/403)."
echo "Gebannte IPs koennen spaeter im HomeEdge-Menue wieder entbannt werden."
if yesno "Fail2ban fuer Caddy/Jellyfin 401/403 aktivieren?" "$( [[ "$(cfg_get EnableCaddyFail2ban "1")" == "0" ]] && echo n || echo y )"; then
  EnableCaddyFail2ban="1"
else
  EnableCaddyFail2ban="0"
fi

ClientPublicKey="$(ask "UniFi/Client WireGuard PublicKey optional, leer lassen falls noch nicht vorhanden" "$(cfg_get ClientPublicKey "")")"
SwapMb="$(ask "Swap Groesse in MB" "$(cfg_get SwapMb "2048")")"

ServicesTsv=""
if [[ -n "${ServicesTsvB64:-}" ]]; then
  ServicesTsv="$(printf '%s' "$ServicesTsvB64" | base64 -d 2>/dev/null || true)"
fi
if [[ -n "$ServicesTsv" ]]; then
  echo
  echo "Gespeicherte Dienste:"
  printf '%s' "$ServicesTsv" | nl -w2 -s'. ' | sed $'s/\t/ | /g'
  echo
  if ! yesno "Diese Dienste verwenden?" "y"; then
    ServicesTsv=""
  fi
fi
if [[ -z "$ServicesTsv" ]]; then
  echo
  echo "Externe Dienste erfassen. Beispiel: jellyfin.example.de | http | 192.168.10.99 | 8096"
  ServiceCount="$(ask "Anzahl externe Dienste" "2")"
  [[ "$ServiceCount" =~ ^[0-9]+$ ]] || { echo "Ungueltige Anzahl, nutze 1."; ServiceCount=1; }
  ServicesTsv=""
  for ((i=1; i<=ServiceCount; i++)); do
    echo
    echo "Dienst $i"
    d="$(ask "Domain")"
    s="$(ask "Backend Scheme http/https" "http")"
    ip="$(ask "Backend IP im Heimnetz")"
    p="$(ask "Backend Port")"
    echo "Backend-Profil: 1) Standard  2) Jellyfin  3) Jellyseerr"
    pr="$(ask "Profil" "1")"
    case "$pr" in 2) pr=jellyfin;; 3) pr=jellyseerr;; *) pr=standard;; esac
    ServicesTsv+="${d}"$'\t'"${s}"$'\t'"${ip}"$'\t'"${p}"$'\t'"${pr}"$'\n'
  done
fi

if yesno "Optional: neuen Admin-User mit SSH-Key erstellen und Root/Password-SSH deaktivieren?" "$( [[ "$(cfg_get CreateAdmin "0")" == "1" ]] && echo y || echo n )"; then
  CreateAdmin="1"
  AdminUser="$(ask "Neuer Admin-User" "$(cfg_get AdminUser "admin")")"
  AdminPubKeyPath="$(ask "Pfad zu deiner Public-Key-Datei" "$(cfg_get AdminPubKeyPath "${HOME}/.ssh/id_ed25519.pub")")"
  if [[ ! -f "$AdminPubKeyPath" ]]; then
    echo "FEHLER: Public-Key-Datei nicht gefunden: $AdminPubKeyPath"
    exit 1
  fi
  AdminPubKey="$(cat "$AdminPubKeyPath")"
else
  CreateAdmin="0"
  AdminUser="$(cfg_get AdminUser "")"
  AdminPubKeyPath="$(cfg_get AdminPubKeyPath "")"
  AdminPubKey=""
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

SSH-Ziel:         ${SshUser}@${SshHost}:${SshPortConnect}

VPS:
  Host/IP:        ${VpsPublicHost}
  Interface:      ${ExtIf}
  SSH-Port:       ${SshPortFinal}

WireGuard:
  Interface:      ${WgIf}
  UDP-Port:       ${WgPort}
  VPS WG-IP:      ${VpsWgAddr}
  Client WG-IP:   ${ClientWgAddr}
  Backend-Netze:  ${HomeSubnet}

Dienste:
${SvcPretty}

Security:
  UFW:              wird aktiviert
  Fail2ban SSH:     wird aktiviert
  Fail2ban Caddy:   ${F2bCaddyState}
  Cloudflare Token: ${TokenState}
  SSH Hardening:    ${HardeningState}
============================================================
EOF
echo

if yesno "Eingaben als lokale Config speichern?" "y"; then
  if yesno "Cloudflare API Token in der lokalen Config speichern? Achtung: nur Dateirechte 600, nicht extra verschluesselt." "n"; then
    save_config "1"
  else
    save_config "0"
  fi
fi

echo
echo "Achtung:"
echo "Auf dem VPS werden jetzt Pakete installiert und konfiguriert:"
echo "Docker/Caddy, WireGuard, UFW, Fail2ban, automatische Updates, Swap, HomeEdge-Menue."
echo
if ! yesno "Konfiguration uebernehmen und Installation jetzt starten?" "n"; then
  echo "Installation abgebrochen. Die Konfiguration kann beim naechsten Start wiederverwendet werden."
  exit 0
fi

RemoteScript="$(cat "$BOOTSTRAP_TEMPLATE")"
HOMEEDGE_B64="$(b64_file "$HOMEEDGE_PATH")"

RemoteScript="${RemoteScript//__EXT_IF_B64__/$(b64 "$ExtIf")}"
RemoteScript="${RemoteScript//__VPS_PUBLIC_HOST_B64__/$(b64 "$VpsPublicHost")}"
RemoteScript="${RemoteScript//__SSH_PORT_B64__/$(b64 "$SshPortFinal")}"
RemoteScript="${RemoteScript//__WG_IF_B64__/$(b64 "$WgIf")}"
RemoteScript="${RemoteScript//__WG_PORT_B64__/$(b64 "$WgPort")}"
RemoteScript="${RemoteScript//__WG_MTU_B64__/$(b64 "${WgMtu:-1280}")}"
RemoteScript="${RemoteScript//__VPS_WG_ADDR_B64__/$(b64 "$VpsWgAddr")}"
RemoteScript="${RemoteScript//__CLIENT_WG_ADDR_B64__/$(b64 "$ClientWgAddr")}"
RemoteScript="${RemoteScript//__HOME_SUBNET_B64__/$(b64 "$HomeSubnet")}"
RemoteScript="${RemoteScript//__ACME_EMAIL_B64__/$(b64 "$AcmeEmail")}"
RemoteScript="${RemoteScript//__CF_TOKEN_B64__/$(b64 "$CfToken")}"
RemoteScript="${RemoteScript//__USE_PSK_B64__/$(b64 "$UsePsk")}"
RemoteScript="${RemoteScript//__CADDY_FAIL2BAN_B64__/$(b64 "$EnableCaddyFail2ban")}"
RemoteScript="${RemoteScript//__CLIENT_PUBLIC_KEY_B64__/$(b64 "$ClientPublicKey")}"
RemoteScript="${RemoteScript//__SERVICES_TSV_B64__/$(b64 "$ServicesTsv")}"
RemoteScript="${RemoteScript//__SWAP_MB_B64__/$(b64 "$SwapMb")}"
RemoteScript="${RemoteScript//__CREATE_ADMIN_B64__/$(b64 "$CreateAdmin")}"
RemoteScript="${RemoteScript//__ADMIN_USER_B64__/$(b64 "$AdminUser")}"
RemoteScript="${RemoteScript//__ADMIN_PUBKEY_B64__/$(b64 "$AdminPubKey")}"
RemoteScript="${RemoteScript//__HOMEEDGE_B64__/$HOMEEDGE_B64}"

build_ssh_args
REMOTE_CMD='tmp=/tmp/edge-bootstrap.sh; cat > "$tmp"; sed -i "s/\r$//" "$tmp" 2>/dev/null || true; chmod 700 "$tmp"; if [ "$(id -u)" -eq 0 ]; then bash -lc "$tmp 2>&1 | tee /root/edge-install.log"; else sudo bash -lc "$tmp 2>&1 | tee /root/edge-install.log"; fi'

echo
echo "Verbinde per SSH und starte Installation..."
echo
printf '%s' "$RemoteScript" | ssh "${SSH_ARGS[@]}" "$REMOTE_CMD"

echo
echo "Installation beendet."
echo
if yesno "Direkt jetzt eine SSH-Sitzung zum VPS oeffnen?" "y"; then
  FINAL_USER="$SshUser"
  FINAL_PORT="$SshPortFinal"
  FINAL_KEY="$SshKeyPath"
  if [[ "$CreateAdmin" == "1" && -n "$AdminUser" ]]; then
    FINAL_USER="$AdminUser"
    if [[ "$AdminPubKeyPath" == *.pub ]]; then
      maybe_key="${AdminPubKeyPath%.pub}"
      [[ -f "$maybe_key" ]] && FINAL_KEY="$maybe_key"
    fi
  fi
  SSH_JUMP_ARGS=()
  [[ -n "$FINAL_KEY" ]] && SSH_JUMP_ARGS+=("-i" "$FINAL_KEY")
  SSH_JUMP_ARGS+=("-p" "$FINAL_PORT" "${FINAL_USER}@${SshHost}")
  if yesno "Direkt das homeedge-Menue starten?" "y"; then
    ssh -t "${SSH_JUMP_ARGS[@]}" "sudo homeedge menu"
  else
    ssh -t "${SSH_JUMP_ARGS[@]}"
  fi
fi
