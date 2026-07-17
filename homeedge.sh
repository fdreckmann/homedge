#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="HomeEdge"
APP_CMD="homeedge"
APP_VERSION="0.9.26-homeedge"

CFG_DIR="/etc/homeedge"
EDGE_DIR="/root/homeedge"
CADDY_DIR="/opt/caddy-edge"
# Zentrale Compose-Datei fuer den Caddy-Stack. IMMER mit explizitem -f nutzen,
# nie auf das aktuelle Arbeitsverzeichnis verlassen (sonst "no configuration
# file provided: not found", wenn man nicht in /opt/caddy-edge steht).
CADDY_COMPOSE_FILE="${CADDY_DIR}/docker-compose.yml"
# Log-Verzeichnis fuer HomeEdge (z. B. echter caddy-validate-Output).
HOMEEDGE_LOG_DIR="/var/log/homeedge"
CADDY_VALIDATE_LOG="${HOMEEDGE_LOG_DIR}/caddy-validate.log"
# Explizit getaggtes Caddy-Image. So kann mit "docker run" validiert werden,
# OHNE die Service-Volumes aus docker-compose.yml (insb. den produktiven
# Caddyfile-Mount) mitzuziehen - das ist die Ursache des Fresh-Install-Mountbugs.
CADDY_IMAGE="homeedge-caddy:local"
# Container-Name des Caddy-Stacks (siehe write_caddy_stack: container_name).
CADDY_CONTAINER="caddy-edge"
SERVICES_FILE="${CFG_DIR}/services.tsv"
ENV_FILE="${CFG_DIR}/homeedge.env"
KEY_DIR="${CFG_DIR}/keys"

# Beszel-Agent Monitoring (optional, muss aktiv installiert werden).
# WICHTIG: Der Agent-Port darf NIE oeffentlich (IPv4/IPv6) erreichbar sein -
# ausschliesslich ueber das WireGuard-Interface (${WG_IF}). Kein pauschales
# "ufw allow" auf 0.0.0.0/0 oder ::/0.
BESZEL_ENV="${CFG_DIR}/beszel.env"
BESZEL_BIN="/usr/local/bin/beszel-agent"
BESZEL_UNIT="/etc/systemd/system/beszel-agent.service"
BESZEL_PORT_DEFAULT="45876"
BESZEL_DOWNLOAD_BASE="https://github.com/henrygd/beszel/releases/latest/download"

# CrowdSec (optionales Security-Modul, Phase 1). Ergaenzt Fail2ban + caddy-auth,
# ersetzt sie NICHT. Oeffnet KEINE neuen Ports und aendert KEINE UFW-Regeln;
# der Firewall-Bouncer setzt Decisions ueber EIGENE nft/iptables-Regeln durch
# (IPv4 + IPv6). Nutzt dieselbe Caddy-Access-Logdatei wie Fail2ban. Lokaler
# Schutz funktioniert ohne CrowdSec Console (Console ist optional).
CROWDSEC_ACQUIS_FILE="/etc/crowdsec/acquis.d/homeedge-caddy.yaml"
CROWDSEC_BOUNCER_SVC="crowdsec-firewall-bouncer"
# Whitelist-Parser: eigene Infrastruktur (Loopback, WireGuard, internes LAN,
# explizit konfigurierte IPs) wird NIE gebannt. Keine pauschalen oeffentlichen Netze.
CROWDSEC_WHITELIST_FILE="/etc/crowdsec/parsers/s02-enrich/homeedge-whitelist.yaml"

mkdir -p "$CFG_DIR" "$EDGE_DIR" "$KEY_DIR"

# Migration von alten edgectl-Pfaden, falls vorhanden
if [[ ! -f "$ENV_FILE" && -f "/etc/edgectl/edge.env" ]]; then
  mkdir -p "$CFG_DIR"
  cp -a /etc/edgectl/. "$CFG_DIR"/ 2>/dev/null || true
  [[ -f "$CFG_DIR/edge.env" ]] && mv "$CFG_DIR/edge.env" "$ENV_FILE"
fi
if [[ ! -s "$SERVICES_FILE" && -f "/etc/edgectl/services.tsv" ]]; then
  cp -a /etc/edgectl/services.tsv "$SERVICES_FILE" 2>/dev/null || true
fi
if [[ ! -d "$KEY_DIR" || -z "$(ls -A "$KEY_DIR" 2>/dev/null)" ]]; then
  [[ -d /etc/edgectl/keys ]] && cp -a /etc/edgectl/keys/. "$KEY_DIR"/ 2>/dev/null || true
fi

# services.tsv beim ersten Start sauber initialisieren. Eine fehlende oder leere
# Datei bedeutet "noch keine Dienste" und ist im Erstsetup voellig ok - sie darf
# WireGuard-/Setup-Funktionen nicht blockieren.
if [[ ! -f "$SERVICES_FILE" ]]; then
  touch "$SERVICES_FILE" 2>/dev/null || true
  chmod 600 "$SERVICES_FILE" 2>/dev/null || true
fi

# ------------------------------------------------------------
# UI helpers
# ------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_MAGENTA=$'\033[35m'; C_GRAY=$'\033[90m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_BLUE=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_MAGENTA=""; C_GRAY=""
fi

line() { printf '%b\n' "${C_BLUE}------------------------------------------------------------${C_RESET}"; }
section() { echo; printf '%b\n' "${C_BOLD}${C_CYAN}$1${C_RESET}"; line; }
ok() { printf '%b\n' "${C_GREEN}[OK]${C_RESET} $*"; }
warn() { printf '%b\n' "${C_YELLOW}[WARN]${C_RESET} $*"; }
err() { printf '%b\n' "${C_RED}[ERR]${C_RESET} $*"; }
info() { printf '%b\n' "${C_BLUE}[INFO]${C_RESET} $*"; }
menu_item() { printf '  %b%2s%b) %s\n' "${C_GREEN}" "$1" "${C_RESET}" "$2"; }
menu_head() { clear; printf '%b\n' "${C_BOLD}${C_BLUE}============================================================${C_RESET}"; printf '%b\n' "${C_BOLD}$1${C_RESET}"; printf '%b\n' "${C_BOLD}${C_BLUE}============================================================${C_RESET}"; }

need_root() { if [[ "${EUID}" -ne 0 ]]; then err "Bitte als root ausfuehren: sudo homeedge ..."; exit 1; fi; }
ask() { local p="$1" d="${2:-}" v; if [[ -n "$d" ]]; then read -rp "$p [$d]: " v; echo "${v:-$d}"; else read -rp "$p: " v; echo "$v"; fi; }
# Newline nach der verdeckten Eingabe geht nach stderr; nur der Wert nach stdout.
# Sonst landet ein fuehrender Zeilenumbruch im per $(...) gelesenen Wert (Token-Bug).
ask_secret() { local p="$1" v; read -rsp "$p: " v; echo >&2; printf '%s' "$v"; }
# Entfernt CR/LF und Whitespace aus Secrets (Tokens duerfen nie mehrzeilig sein).
sanitize_token() { printf '%s' "${1:-}" | tr -d '\r\n[:space:]'; }
# Maskiert Secrets in beliebigen Ausgaben/Logs (Tokens, API-Keys, WG-Keys).
mask_secrets() {
  sed -E \
    -e 's/cfut_[A-Za-z0-9_-]+/cfut_***MASKED***/g' \
    -e 's/(CLOUDFLARE_API_TOKEN[=:][[:space:]]*)[^[:space:]]*/\1***MASKED***/g' \
    -e 's/(api_key=)[^&[:space:]"]*/\1MASKED/Ig' \
    -e 's/(X-Emby-Token[":= ]+)[A-Za-z0-9]+/\1MASKED/Ig' \
    -e 's/(X-MediaBrowser-Token[":= ]+)[A-Za-z0-9]+/\1MASKED/Ig' \
    -e 's/(AccessToken[":= ]+)[A-Za-z0-9]+/\1MASKED/Ig' \
    -e 's/(PrivateKey[[:space:]]*=[[:space:]]*).*/\1***MASKED***/g' \
    -e 's/(PresharedKey[[:space:]]*=[[:space:]]*).*/\1***MASKED***/g' \
    -e 's/(BESZEL_TOKEN[=:][[:space:]]*)[^[:space:]]*/\1***MASKED***/g' \
    -e 's/(TOKEN[=:][[:space:]]*)[^[:space:]]{8,}/\1***MASKED***/g' \
    -e 's/(^|[[:space:]])(KEY[=:][[:space:]]*)[^[:space:]]{16,}/\1\2***MASKED***/g' \
    -e 's/(ssh-(ed25519|rsa|dss)[[:space:]]+)[A-Za-z0-9+\/]{20,}(=*)/\1***MASKED***/g'
}
# Zentrale, robuste Laufzeitpruefung fuer den Caddy-Container.
# running=true UND restarting=false -> OK; sonst (fehlt/Restarting) -> Fehler.
caddy_is_running() {
  [[ "$(docker inspect -f '{{.State.Running}} {{.State.Restarting}}' "$CADDY_CONTAINER" 2>/dev/null)" == "true false" ]]
}
# Prueft, ob die letzten Caddy-Logs einen erfolgreichen Reload zeigen (Caddy hat
# die Config geladen, auch wenn der docker-exec-Aufruf nicht sauber zurueckkam).
caddy_recent_reload_ok() {
  command -v docker >/dev/null 2>&1 || return 1
  docker logs --since 20s --tail 80 "$CADDY_CONTAINER" 2>&1 \
    | grep -qiE 'load complete|config is unchanged'
}
# Laedt die aktive Config im LAUFENDEN Container neu - per "docker exec" (NICHT
# "docker compose exec", das nach einem erfolgreichen Caddy-Reload gelegentlich
# im Exec haengt). Hartes Timeout mit --kill-after, damit HomeEdge nie endlos
# haengt. Rueckgabe: 0 = ok, 2 = Timeout, aber Log zeigt Erfolg (Warnung),
# 1 = echter Fehler.
caddy_exec_reload() {
  local rc=0
  timeout --kill-after=5s "${CADDY_RELOAD_TIMEOUT:-20}s" \
    docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1 || rc=$?
  if (( rc == 0 )); then
    return 0
  elif (( rc == 124 || rc == 137 )); then
    # 124 = TERM durch timeout, 137 = KILL nach --kill-after -> beides Timeout.
    # Caddy kann den Reload dennoch verarbeitet haben -> Log der letzten Sek. pruefen.
    if caddy_recent_reload_ok; then return 2; fi
    return 1
  else
    return 1
  fi
}
# docker compose fuer den Caddy-Stack mit explizitem Compose-Pfad (cwd-unabhaengig).
caddy_compose() { docker compose -f "$CADDY_COMPOSE_FILE" "$@"; }
caddy_compose_file_exists() { [[ -f "$CADDY_COMPOSE_FILE" ]]; }
# Prueft, ob das lokale Caddy-Image bereits gebaut vorliegt (OHNE es zu bauen).
# Der normale Reload/Validate darf NIE bauen - nur pruefen.
caddy_image_exists() { docker image inspect "$CADDY_IMAGE" >/dev/null 2>&1; }
# Granulare Zustandspruefung des Caddy-Stacks. Gibt genau einen Status aus:
#   dir_missing | caddyfile_missing | env_missing | compose_missing |
#   compose_invalid | no_container | restarting | exited | running
caddy_stack_state() {
  [[ -d "$CADDY_DIR" ]] || { echo dir_missing; return; }
  [[ -f "${CADDY_DIR}/Caddyfile" ]] || { echo caddyfile_missing; return; }
  [[ -f "${CADDY_DIR}/.env" ]] || { echo env_missing; return; }
  caddy_compose_file_exists || { echo compose_missing; return; }
  caddy_compose config >/dev/null 2>&1 || { echo compose_invalid; return; }
  local line running restarting status
  line="$(docker inspect -f '{{.State.Running}} {{.State.Restarting}} {{.State.Status}}' caddy-edge 2>/dev/null)" || { echo no_container; return; }
  [[ -z "$line" ]] && { echo no_container; return; }
  read -r running restarting status <<<"$line"
  if [[ "$running" == "true" && "$restarting" == "false" ]]; then echo running
  elif [[ "$restarting" == "true" ]]; then echo restarting
  elif [[ "$status" == "exited" ]]; then echo exited
  else echo "${status:-exited}"; fi
}
# Einheitlicher Reparaturhinweis bei fehlendem/defektem Caddy-Stack.
caddy_stack_repair_hint() {
  info "Reparatur:"
  printf '  %s\n' "sudo homeedge apply-all"
  printf '  %s\n' "sudo homeedge caddy-rebuild"
}
# Robuster Check, ob lokal ein UDP-Port lauscht (ss-Filter statt Spalten-Parsing).
udp_port_open() { local p="$1"; ss -H -lun "sport = :${p}" 2>/dev/null | grep -q . ; }
udp443_open() { udp_port_open 443; }
tcp_port_open() { local p="$1"; ss -H -ltn "sport = :${p}" 2>/dev/null | grep -q . ; }
yesno() { local p="$1" d="${2:-n}" a; read -rp "$p [$d]: " a; a="${a:-$d}"; [[ "$a" =~ ^([YyJj]|yes|YES|Yes|ja|JA|Ja)$ ]]; }
q() { printf '%q' "$1"; }
pause() { echo; read -rp "Enter druecken zum Fortfahren..."; }

# Repariert eine beschaedigte Env-Datei VOR dem Sourcen: erkennt einen cfut_-Token,
# der durch alte Bugs in einer Extra-Zeile oder mehrzeilig gespeichert wurde, und
# schreibt ihn als genau eine Zeile "CLOUDFLARE_API_TOKEN=cfut_...". Idempotent.
repair_env_file() {
  local f="$ENV_FILE"
  [[ -f "$f" ]] || return 0
  grep -q 'cfut_' "$f" 2>/dev/null || return 0
  # Bereits korrekt einzeilig? Dann nichts tun.
  if grep -qE "^CLOUDFLARE_API_TOKEN=['\"]?cfut_[A-Za-z0-9_-]+['\"]?$" "$f"; then
    return 0
  fi
  local tok
  tok="$(grep -oE 'cfut_[A-Za-z0-9_-]+' "$f" 2>/dev/null | head -n1 || true)"
  [[ -z "$tok" ]] && return 0
  local tmp; tmp="$(mktemp)"
  # Alle alten Token-/Bare-cfut-Zeilen entfernen, danach eine saubere Zeile setzen.
  grep -vE '^CLOUDFLARE_API_TOKEN=|^[[:space:]]*cfut_[A-Za-z0-9_-]+[[:space:]]*$' "$f" > "$tmp" 2>/dev/null || true
  printf 'CLOUDFLARE_API_TOKEN=%s\n' "$tok" >> "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
  chmod 600 "$f" 2>/dev/null || true
}

load_env() {
  # Defaults immer zuerst setzen (set -u-sicher via :-), danach ggf. aus der
  # Env-Datei ueberschreiben. So fuehrt eine unvollstaendige Datei nie zu
  # "unbound variable" in save_env o. ae.
  EXT_IF="${EXT_IF:-eth0}"; VPS_PUBLIC_HOST="${VPS_PUBLIC_HOST:-}"; SSH_PORT="${SSH_PORT:-22}"
  WG_IF="${WG_IF:-unifi}"; WG_PORT="${WG_PORT:-51821}"
  VPS_WG_ADDR="${VPS_WG_ADDR:-10.0.1.1/24}"; VPS_WG_IP="${VPS_WG_IP:-10.0.1.1}"
  CLIENT_WG_ADDR="${CLIENT_WG_ADDR:-10.0.1.2/32}"; CLIENT_WG_IP="${CLIENT_WG_IP:-10.0.1.2}"
  HOME_SUBNET="${HOME_SUBNET:-192.168.10.0/24}"; ACME_EMAIL="${ACME_EMAIL:-}"
  CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"; USE_PSK="${USE_PSK:-1}"
  CADDY_FAIL2BAN="${CADDY_FAIL2BAN:-0}"; CLIENT_PUBLIC_KEY="${CLIENT_PUBLIC_KEY:-}"
  ENABLE_HTTP3="${ENABLE_HTTP3:-0}"; HOMEEDGE_UPDATE_URL="${HOMEEDGE_UPDATE_URL:-}"
  HOMEEDGE_REPO="${HOMEEDGE_REPO:-fdreckmann/homedge}"; HOMEEDGE_BRANCH="${HOMEEDGE_BRANCH:-main}"
  EXPERT_MODE="${EXPERT_MODE:-0}"; BACKUP_BEHAVIOR="${BACKUP_BEHAVIOR:-ask}"
  WG_MTU="${WG_MTU:-}"; ENABLE_IPV6="${ENABLE_IPV6:-0}"
  MIGRATION_MODE="${MIGRATION_MODE:-0}"
  F2B_CADDY_MAXRETRY="${F2B_CADDY_MAXRETRY:-20}"; F2B_CADDY_FINDTIME="${F2B_CADDY_FINDTIME:-10m}"; F2B_CADDY_BANTIME="${F2B_CADDY_BANTIME:-15m}"
  ENABLE_CROWDSEC="${ENABLE_CROWDSEC:-0}"; CROWDSEC_CONSOLE="${CROWDSEC_CONSOLE:-0}"
  CROWDSEC_CADDY_LOG="${CROWDSEC_CADDY_LOG:-/opt/caddy-edge/logs/access.log}"; CROWDSEC_BOUNCER="${CROWDSEC_BOUNCER:-auto}"
  CROWDSEC_WHITELIST_IPS="${CROWDSEC_WHITELIST_IPS:-}"
  if [[ -f "$ENV_FILE" ]]; then
    # Beschaedigten/mehrzeiligen Token VOR dem Sourcen reparieren.
    repair_env_file
    # Tolerant gegen kaputte Zeilen (z. B. fehlerhaft gespeicherter, mehrzeiliger
    # Token): || true verhindert errexit-Abbruch waehrend des Sourcens.
    # shellcheck disable=SC1090
    source "$ENV_FILE" 2>/dev/null || true
    # Token defensiv bereinigen, falls beschaedigt eingelesen.
    CLOUDFLARE_API_TOKEN="$(sanitize_token "${CLOUDFLARE_API_TOKEN:-}")"
    # Neue Variablen, die in aelteren Env-Dateien fehlen koennen, absichern:
    ENABLE_HTTP3="${ENABLE_HTTP3:-0}"; HOMEEDGE_UPDATE_URL="${HOMEEDGE_UPDATE_URL:-}"
    HOMEEDGE_REPO="${HOMEEDGE_REPO:-fdreckmann/homedge}"; HOMEEDGE_BRANCH="${HOMEEDGE_BRANCH:-main}"
    EXPERT_MODE="${EXPERT_MODE:-0}"; BACKUP_BEHAVIOR="${BACKUP_BEHAVIOR:-ask}"
    WG_MTU="${WG_MTU:-}"; ENABLE_IPV6="${ENABLE_IPV6:-0}"
    MIGRATION_MODE="${MIGRATION_MODE:-0}"
    F2B_CADDY_MAXRETRY="${F2B_CADDY_MAXRETRY:-20}"; F2B_CADDY_FINDTIME="${F2B_CADDY_FINDTIME:-10m}"; F2B_CADDY_BANTIME="${F2B_CADDY_BANTIME:-15m}"
    # CrowdSec-Defaults fuer aeltere Env-Dateien absichern.
    ENABLE_CROWDSEC="${ENABLE_CROWDSEC:-0}"; CROWDSEC_CONSOLE="${CROWDSEC_CONSOLE:-0}"
    CROWDSEC_CADDY_LOG="${CROWDSEC_CADDY_LOG:-/opt/caddy-edge/logs/access.log}"; CROWDSEC_BOUNCER="${CROWDSEC_BOUNCER:-auto}"
    CROWDSEC_WHITELIST_IPS="${CROWDSEC_WHITELIST_IPS:-}"
  fi
}

save_env() {
  umask 077
  # Secrets immer bereinigen, bevor sie geschrieben werden (nie mehrzeilig).
  CLOUDFLARE_API_TOKEN="$(sanitize_token "${CLOUDFLARE_API_TOKEN:-}")"
  cat > "$ENV_FILE" <<EOCFG
EXT_IF=$(q "${EXT_IF}")
VPS_PUBLIC_HOST=$(q "${VPS_PUBLIC_HOST}")
SSH_PORT=$(q "${SSH_PORT}")
WG_IF=$(q "${WG_IF}")
WG_PORT=$(q "${WG_PORT}")
VPS_WG_ADDR=$(q "${VPS_WG_ADDR}")
VPS_WG_IP=$(q "${VPS_WG_IP}")
CLIENT_WG_ADDR=$(q "${CLIENT_WG_ADDR}")
CLIENT_WG_IP=$(q "${CLIENT_WG_IP}")
HOME_SUBNET=$(q "${HOME_SUBNET}")
ACME_EMAIL=$(q "${ACME_EMAIL}")
CLOUDFLARE_API_TOKEN=$(q "${CLOUDFLARE_API_TOKEN}")
USE_PSK=$(q "${USE_PSK}")
CADDY_FAIL2BAN=$(q "${CADDY_FAIL2BAN}")
CLIENT_PUBLIC_KEY=$(q "${CLIENT_PUBLIC_KEY:-}")
ENABLE_HTTP3=$(q "${ENABLE_HTTP3:-0}")
HOMEEDGE_UPDATE_URL=$(q "${HOMEEDGE_UPDATE_URL:-}")
HOMEEDGE_REPO=$(q "${HOMEEDGE_REPO:-fdreckmann/homedge}")
HOMEEDGE_BRANCH=$(q "${HOMEEDGE_BRANCH:-main}")
EXPERT_MODE=$(q "${EXPERT_MODE:-0}")
BACKUP_BEHAVIOR=$(q "${BACKUP_BEHAVIOR:-ask}")
WG_MTU=$(q "${WG_MTU:-}")
ENABLE_IPV6=$(q "${ENABLE_IPV6:-0}")
MIGRATION_MODE=$(q "${MIGRATION_MODE:-0}")
F2B_CADDY_MAXRETRY=$(q "${F2B_CADDY_MAXRETRY:-20}")
F2B_CADDY_FINDTIME=$(q "${F2B_CADDY_FINDTIME:-10m}")
F2B_CADDY_BANTIME=$(q "${F2B_CADDY_BANTIME:-15m}")
ENABLE_CROWDSEC=$(q "${ENABLE_CROWDSEC:-0}")
CROWDSEC_CONSOLE=$(q "${CROWDSEC_CONSOLE:-0}")
CROWDSEC_CADDY_LOG=$(q "${CROWDSEC_CADDY_LOG:-/opt/caddy-edge/logs/access.log}")
CROWDSEC_BOUNCER=$(q "${CROWDSEC_BOUNCER:-auto}")
CROWDSEC_WHITELIST_IPS=$(q "${CROWDSEC_WHITELIST_IPS:-}")
EOCFG
  chmod 600 "$ENV_FILE"
}

# ------------------------------------------------------------
# WireGuard
# ------------------------------------------------------------
generate_keys() {
  load_env; umask 077; mkdir -p "$KEY_DIR"
  [[ -f "${KEY_DIR}/server_private.key" ]] || wg genkey > "${KEY_DIR}/server_private.key"
  wg pubkey < "${KEY_DIR}/server_private.key" > "${KEY_DIR}/server_public.key"
  if [[ "${USE_PSK}" == "1" && ! -f "${KEY_DIR}/preshared.key" ]]; then wg genpsk > "${KEY_DIR}/preshared.key"; fi
}

regenerate_psk() {
  load_env; umask 077; mkdir -p "$KEY_DIR"
  wg genpsk > "${KEY_DIR}/preshared.key"
  USE_PSK="1"; save_env
  write_wg_config; write_unifi_values
  warn "Neuer PresharedKey erzeugt. Du musst diesen auch in UniFi aktualisieren."
}

regenerate_server_keys() {
  load_env
  warn "Das erzeugt neue VPS-WireGuard-Keys. Danach muss der neue VPS PublicKey in UniFi eingetragen werden."
  if ! yesno "VPS WireGuard Keys wirklich neu erzeugen?" "n"; then return; fi
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${KEY_DIR}/backup-${ts}"
  cp -a "${KEY_DIR}/server_private.key" "${KEY_DIR}/server_public.key" "${KEY_DIR}/backup-${ts}/" 2>/dev/null || true
  umask 077; wg genkey > "${KEY_DIR}/server_private.key"; wg pubkey < "${KEY_DIR}/server_private.key" > "${KEY_DIR}/server_public.key"
  write_wg_config; write_unifi_values
  warn "Keys neu erzeugt. UniFi muss den neuen VPS PublicKey bekommen."
}

write_wg_config() {
  load_env; generate_keys; mkdir -p /etc/wireguard
  local wg_conf="/etc/wireguard/${WG_IF}.conf" wg_template="/etc/wireguard/${WG_IF}.conf.template" target key
  target="$wg_conf"; key="${CLIENT_PUBLIC_KEY:-}"
  if [[ -z "$key" ]]; then target="$wg_template"; key="<UNIFI_CLIENT_PUBLIC_KEY_HIER_EINTRAGEN>"; fi
  cat > "$target" <<EOWG
[Interface]
PrivateKey = $(cat "${KEY_DIR}/server_private.key")
Address = ${VPS_WG_ADDR}
ListenPort = ${WG_PORT}
EOWG
  # MTU-Zeile nur schreiben, wenn WG_MTU gesetzt ist. Leer = WireGuard/Linux
  # nutzt den Default (1280 ist nur ein optionaler Troubleshooting-Wert).
  if [[ -n "${WG_MTU:-}" ]]; then echo "MTU = ${WG_MTU}" >> "$target"; fi
  cat >> "$target" <<EOWG

[Peer]
PublicKey = ${key}
EOWG
  if [[ "${USE_PSK}" == "1" ]]; then echo "PresharedKey = $(cat "${KEY_DIR}/preshared.key")" >> "$target"; fi
  cat >> "$target" <<EOWG
AllowedIPs = ${CLIENT_WG_IP}/32, ${HOME_SUBNET}
PersistentKeepalive = 25
EOWG
  chmod 600 "$target"
}

restart_wg() {
  load_env
  if [[ -n "${CLIENT_PUBLIC_KEY:-}" && -f "/etc/wireguard/${WG_IF}.conf" ]]; then
    systemctl enable --now "wg-quick@${WG_IF}" || true
    systemctl restart "wg-quick@${WG_IF}" || true
  else
    warn "WireGuard noch nicht aktivierbar: UniFi/Client PublicKey fehlt. Template: /etc/wireguard/${WG_IF}.conf.template"
  fi
}

stop_wg_if_exists() {
  load_env
  systemctl stop "wg-quick@${WG_IF}" 2>/dev/null || true
}

write_unifi_values() {
  load_env; generate_keys
  local psk="<nicht verwendet>"; [[ "${USE_PSK}" == "1" ]] && psk="$(cat "${KEY_DIR}/preshared.key")"
  cat > "${EDGE_DIR}/unifi-wireguard-werte.txt" <<EOVAL
============================================================
UniFi / WireGuard Client Werte
============================================================
VPS Endpoint / Remote Host: ${VPS_PUBLIC_HOST}
VPS WireGuard Port:         ${WG_PORT}/udp
VPS WireGuard PublicKey:    $(cat "${KEY_DIR}/server_public.key")
PresharedKey:               ${psk}
VPS Tunnel IP:              ${VPS_WG_ADDR}
UniFi/Client Tunnel IP:     ${CLIENT_WG_ADDR}
Allowed IPs Client -> VPS:  ${VPS_WG_IP}/32
Allowed IPs VPS -> UniFi:   ${CLIENT_WG_IP}/32, ${HOME_SUBNET}
Persistent Keepalive:       25

UniFi Firewall-Regeln:
Erlaube von ${VPS_WG_IP} zu deinen Backend-Diensten:
EOVAL
  # Dienstbezogene Firewall-Hinweise sind OPTIONAL: WireGuard-Basiswerte oben
  # haengen NICHT von services.tsv ab. Ist die Datei defekt, nur warnen statt
  # das ganze WireGuard-Menue zu blockieren.
  if [[ -s "$SERVICES_FILE" ]]; then
    if validate_services_file >/dev/null 2>&1; then
      while IFS=$'\t' read -r domain scheme ip port profile || [[ -n "$domain" ]]; do [[ -z "${domain:-}" ]] && continue; echo "  ${VPS_WG_IP} -> ${ip}:${port}/tcp  (${domain})" >> "${EDGE_DIR}/unifi-wireguard-werte.txt"; done < "$SERVICES_FILE"
    else
      echo "  (services.tsv ist ungueltig - dienstbezogene Hinweise ausgelassen. Reparatur: sudo homeedge repair-services)" >> "${EDGE_DIR}/unifi-wireguard-werte.txt"
      warn "services.tsv ist ungueltig. Dienstbezogene Hinweise werden nicht angezeigt." >&2
      info "WireGuard-Basiswerte werden trotzdem angezeigt." >&2
    fi
  fi
  cat >> "${EDGE_DIR}/unifi-wireguard-werte.txt" <<EOVAL

Wenn der UniFi PublicKey noch fehlt:
  sudo homeedge menu  ->  WireGuard konfigurieren  ->  UniFi PublicKey setzen

Pruefen:
  sudo wg show
  sudo homeedge test-backends

Jellyfin Known Proxy:
  ${VPS_WG_IP}

Cloudflare DNS:
  Fuer Jellyfin empfohlen: DNS only / graue Wolke.
  Das Cloudflare Token wird nur fuer Let's Encrypt DNS-Challenge genutzt.
============================================================
EOVAL
  chmod 600 "${EDGE_DIR}/unifi-wireguard-werte.txt" 2>/dev/null || true
}

set_wg_key() {
  load_env
  local newkey; newkey="$(ask "UniFi/Client PublicKey" "${CLIENT_PUBLIC_KEY:-}")"
  maybe_backup_before_change
  CLIENT_PUBLIC_KEY="$newkey"
  save_env; write_wg_config; write_unifi_values; restart_wg
  wg show || true
}

wg_values() { write_unifi_values; cat "${EDGE_DIR}/unifi-wireguard-werte.txt"; }

show_wg_config() {
  load_env
  section "WireGuard Konfiguration"
  echo "Aktive Konfig: /etc/wireguard/${WG_IF}.conf"
  echo "Template:      /etc/wireguard/${WG_IF}.conf.template"
  echo
  if [[ -f "/etc/wireguard/${WG_IF}.conf" ]]; then
    sed -E 's/(PrivateKey|PresharedKey) = .+/\1 = <geheim>/' "/etc/wireguard/${WG_IF}.conf"
  elif [[ -f "/etc/wireguard/${WG_IF}.conf.template" ]]; then
    sed -E 's/(PrivateKey|PresharedKey) = .+/\1 = <geheim>/' "/etc/wireguard/${WG_IF}.conf.template"
  else
    warn "Noch keine WireGuard-Konfig vorhanden."
  fi
}

wg_status() {
  section "WireGuard Status"
  wg show 2>/dev/null || warn "WireGuard laeuft noch nicht oder wg ist nicht verfuegbar."
  echo
  ip -br addr show "${WG_IF}" 2>/dev/null || true
  echo
  ip route | grep -E "${WG_IF}|${HOME_SUBNET%%,*}" || true
}

edit_wg_interface() {
  load_env
  local old_if="$WG_IF"
  WG_IF="$(ask "WireGuard Interface Name" "$WG_IF")"
  save_env; write_wg_config; write_unifi_values
  if [[ "$old_if" != "$WG_IF" ]]; then
    warn "Interface-Name geaendert von ${old_if} auf ${WG_IF}. Alte systemd-Unit ggf. stoppen: sudo systemctl disable --now wg-quick@${old_if}"
  fi
  restart_wg
}

edit_wg_port() {
  load_env
  local _p; _p="$(ask "WireGuard UDP Port" "$WG_PORT")"
  if ! [[ "$_p" =~ ^[0-9]+$ ]] || (( _p < 1 || _p > 65535 )); then err "Ungueltiger Port (1-65535). Unveraendert."; return 1; fi
  WG_PORT="$_p"
  save_env; write_wg_config; write_unifi_values; restart_wg
  warn "Den Port auch in UniFi und ggf. in der Firewall aktualisieren. UFW-Menuepunkt kann die Regel neu setzen."
}

edit_vps_wg_addr() {
  load_env
  VPS_WG_ADDR="$(ask "VPS WireGuard Adresse mit CIDR" "$VPS_WG_ADDR")"
  VPS_WG_IP="${VPS_WG_ADDR%%/*}"
  save_env; write_wg_config; write_unifi_values; restart_wg
  warn "Jellyfin Known Proxy ggf. auf ${VPS_WG_IP} anpassen. UniFi Firewall-Regeln ebenfalls pruefen."
}

edit_client_wg_addr() {
  load_env
  CLIENT_WG_ADDR="$(ask "UniFi/Client WireGuard Adresse mit CIDR" "$CLIENT_WG_ADDR")"
  CLIENT_WG_IP="${CLIENT_WG_ADDR%%/*}"
  save_env; write_wg_config; write_unifi_values; restart_wg
  warn "Client-Adresse auch in UniFi aktualisieren."
}

edit_backend_networks() {
  load_env
  echo "Beispiel: 192.168.10.0/24, 192.168.20.0/24, 192.168.30.0/24"
  HOME_SUBNET="$(ask "Backend-Netze hinter UniFi" "$HOME_SUBNET")"
  save_env; write_wg_config; write_unifi_values; restart_wg
  ok "Backend-Netze aktualisiert."
}

edit_wg_mtu() {
  need_root; load_env
  section "WireGuard MTU anzeigen/aendern"
  echo "Aktuell: $([[ -n "${WG_MTU:-}" ]] && echo "MTU = ${WG_MTU}" || echo "automatisch (keine MTU-Zeile, WireGuard-Default)")"
  echo
  echo "  1) MTU automatisch / WireGuard-Default verwenden (empfohlen)"
  echo "  2) MTU manuell setzen"
  echo "  3) Empfehlung anzeigen"
  echo "  0) Abbruch"
  local c; c="$(ask "Auswahl" "1")"
  case "$c" in
    1)
      maybe_backup_before_change
      WG_MTU=""; save_env; write_wg_config; restart_wg
      ok "WireGuard MTU auf automatisch gesetzt (keine MTU-Zeile in der Konfig)."
      ;;
    2)
      local mtu; mtu="$(ask "WireGuard MTU (numerisch, 1200-1420)" "${WG_MTU:-1280}")"
      if ! [[ "$mtu" =~ ^[0-9]+$ ]] || (( mtu < 1200 || mtu > 1420 )); then err "MTU muss numerisch und zwischen 1200 und 1420 liegen."; return 1; fi
      maybe_backup_before_change
      WG_MTU="$mtu"; save_env; write_wg_config; restart_wg
      ok "WireGuard MTU gesetzt: MTU = ${WG_MTU}"
      warn "Hinweis: MTU ggf. auch auf UniFi-Seite setzen, falls UniFi ein MTU-Feld anbietet."
      ;;
    3)
      info "Empfehlung: Lass die MTU auf automatisch (leer). WireGuard waehlt selbst."
      info "Nur bei Problemen (haengende Verbindungen, Fragmentierung) manuell testen:"
      info "  - 1420 als erster Versuch, sonst schrittweise reduzieren (1380, 1280)."
      info "  - 1280 ist der robusteste Wert, kann aber den Durchsatz leicht senken."
      ;;
    *) warn "Abgebrochen."; return 0 ;;
  esac
}

toggle_psk() {
  load_env
  if [[ "$USE_PSK" == "1" ]]; then
    if yesno "PresharedKey deaktivieren?" "n"; then USE_PSK="0"; save_env; write_wg_config; write_unifi_values; restart_wg; warn "PresharedKey auch in UniFi entfernen."; fi
  else
    if yesno "PresharedKey aktivieren?" "y"; then USE_PSK="1"; generate_keys; save_env; write_wg_config; write_unifi_values; restart_wg; warn "PresharedKey aus wg-values in UniFi eintragen."; fi
  fi
}


# ------------------------------------------------------------
# Caddy / Fail2ban / Services
# ------------------------------------------------------------
# Sichert /opt/caddy-edge/Caddyfile, falls es faelschlich ein Verzeichnis ist
# (kann durch fehlgeschlagene Docker-Mounts entstehen). Nie einfach loeschen.
_ensure_caddyfile_not_dir() {
  local cf="${CADDY_DIR}/Caddyfile"
  if [[ -e "$cf" && ! -f "$cf" ]]; then
    local bad="${cf}.bad-dir.$(date +%Y%m%d-%H%M%S)"
    mv "$cf" "$bad" 2>/dev/null || rm -rf "$cf" 2>/dev/null || true
    warn "${cf} war kein regulaeres File (Verzeichnis?) - gesichert als ${bad}."
  fi
}

write_caddy_stack() {
  load_env; mkdir -p "${CADDY_DIR}/data" "${CADDY_DIR}/config" "${CADDY_DIR}/logs"
  # /opt/caddy-edge/Caddyfile darf NIE ein Verzeichnis sein (Docker legt es sonst
  # beim Mount an, wenn die Quelle fehlt -> "not a directory"-Mountfehler).
  _ensure_caddyfile_not_dir
  # Produktive Caddyfile als regulaeres File sicherstellen, BEVOR ein Mount/up
  # passiert (verhindert Auto-Anlegen als Directory durch Docker).
  [[ -f "${CADDY_DIR}/Caddyfile" ]] || : > "${CADDY_DIR}/Caddyfile"
  CLOUDFLARE_API_TOKEN="$(sanitize_token "${CLOUDFLARE_API_TOKEN:-}")"
  cat > "${CADDY_DIR}/.env" <<EOCADDY
ACME_EMAIL=${ACME_EMAIL}
CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
EOCADDY
  chmod 600 "${CADDY_DIR}/.env"
  # caddy:2-builder/xcaddy bauen die jeweils neueste caddy-dns/cloudflare-Version.
  # Diese akzeptiert die neuen Cloudflare-Tokenformate (Prefix cfut_).
  # Bei Token-Problemen Caddy neu bauen: Menue -> Wartung -> Caddy/Docker neu bauen
  # (docker compose build --pull). Haupt-Ursache fuer "invalid" war bisher ein
  # versehentlicher Zeilenumbruch im Token - das ist jetzt zentral bereinigt.
  cat > "${CADDY_DIR}/Dockerfile" <<'EOCADDY'
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare
FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
EOCADDY
  # image: explizit getaggt -> erlaubt "docker run" zum Validieren OHNE die
  # Service-Volumes (insb. den produktiven Caddyfile-Mount) mitzuziehen.
  cat > "${CADDY_DIR}/docker-compose.yml" <<EOCADDY
services:
  caddy:
    build: .
    image: ${CADDY_IMAGE}
    container_name: caddy-edge
    restart: unless-stopped
    network_mode: host
    env_file:
      - ${CADDY_DIR}/.env
    volumes:
      - ${CADDY_DIR}/Caddyfile:/etc/caddy/Caddyfile:ro
      - ${CADDY_DIR}/data:/data
      - ${CADDY_DIR}/config:/config
      - ${CADDY_DIR}/logs:/var/log/caddy
EOCADDY
}

# Erzeugt das Caddyfile komplett aus der Service-Liste in die Zieldatei $1.
generate_caddyfile_to() {
  local out="$1"
  load_env; mkdir -p "$CADDY_DIR"; touch "$SERVICES_FILE"
  cat > "$out" <<EOCADDY
{
    email {\$ACME_EMAIL}
    auto_https disable_redirects
EOCADDY

  if [[ "${ENABLE_HTTP3:-0}" != "1" ]]; then
    cat >> "$out" <<'EOCADDY'
    servers {
        protocols h1 h2
    }
EOCADDY
  fi

  cat >> "$out" <<'EOCADDY'
}

(common) {
    encode gzip zstd
    tls {
        dns cloudflare {$CLOUDFLARE_API_TOKEN}
    }
    log {
        output file /var/log/caddy/access.log {
            roll_size 10MiB
            roll_keep 5
            roll_keep_for 168h
        }
        format json
    }
}
EOCADDY
  # Hinweis: X-Forwarded-For/Proto/Host setzt Caddy automatisch -> nicht doppeln.
  # Nur X-Real-IP bleibt (optional). Profil "jellyfin" setzt flush_interval -1.
  local domain scheme ip port profile extra
  while IFS=$'\t' read -r domain scheme ip port profile || [[ -n "$domain" ]]; do
    [[ -z "${domain:-}" ]] && continue
    extra=""
    [[ "${profile:-}" == "jellyfin" ]] && extra=$'\n        flush_interval -1'
    cat >> "$out" <<EOCADDY

${domain} {
    import common
EOCADDY
    if [[ "$scheme" == "https" ]]; then
      cat >> "$out" <<EOCADDY
    reverse_proxy https://${ip}:${port} {
        transport http { tls_insecure_skip_verify }
        header_up X-Real-IP {remote_host}${extra}
    }
}
EOCADDY
    else
      cat >> "$out" <<EOCADDY
    reverse_proxy http://${ip}:${port} {
        header_up X-Real-IP {remote_host}${extra}
    }
}
EOCADDY
    fi
  done < "$SERVICES_FILE"
}

generate_caddyfile() { generate_caddyfile_to "${CADDY_DIR}/Caddyfile"; }

# Baut das Caddy-Image (mit caddy-dns/cloudflare) und stellt sicher, dass es als
# ${CADDY_IMAGE} getaggt ist. 0 = ok.
caddy_build_image() {
  caddy_compose_file_exists || return 1
  caddy_compose build >/dev/null 2>&1
}

# Stellt sicher, dass das Caddy-Image existiert. Baut es NUR, wenn es fehlt
# (Erstinstallation / Restore). Der normale Reload/Validate ruft dies NICHT auf -
# dort darf nie gebaut werden. 0 = Image vorhanden (ggf. frisch gebaut).
caddy_ensure_image() {
  caddy_image_exists && return 0
  info "Caddy-Image ${CADDY_IMAGE} fehlt - wird einmalig gebaut (Erstinstallation, das kann dauern)..."
  _ensure_caddyfile_not_dir
  write_caddy_stack
  if caddy_build_image; then ok "Caddy-Image gebaut: ${CADDY_IMAGE}"; return 0; fi
  err "Caddy-Image-Build fehlgeschlagen."
  return 1
}

# Bringt den Caddy-Stack mit HARTEM Timeout hoch (kein Haenger). $1 = "recreate"
# (up -d --force-recreate, Default) oder "up" (up -d). Bei Fehler/Timeout wird
# NICHT still verschluckt: docker compose ps + docker logs (tail 80) werden
# angezeigt. 0 = ok.
caddy_compose_up() {
  local mode="${1:-recreate}" out rc=0
  local -a args
  if [[ "$mode" == "up" ]]; then args=(up -d); else args=(up -d --force-recreate); fi
  out="$(timeout --kill-after=10s "${CADDY_UP_TIMEOUT:-60}s" docker compose -f "$CADDY_COMPOSE_FILE" "${args[@]}" 2>&1)" || rc=$?
  if (( rc == 0 )); then return 0; fi
  if (( rc == 124 || rc == 137 )); then
    err "Caddy-Container-Start Timeout (${CADDY_UP_TIMEOUT:-60}s) - haengt nicht mehr, aber Start unvollstaendig."
  else
    err "Caddy-Container-Start fehlgeschlagen (rc=${rc})."
  fi
  [[ -n "$out" ]] && printf '%s\n' "$out" | mask_secrets | sed 's/^/  /'
  echo "== docker compose ps =="
  docker compose -f "$CADDY_COMPOSE_FILE" ps 2>&1 | mask_secrets | sed 's/^/  /' || true
  echo "== docker logs --tail 80 ${CADDY_CONTAINER} =="
  docker logs --tail 80 "$CADDY_CONTAINER" 2>&1 | mask_secrets | sed 's/^/  /' || true
  return "$rc"
}

# Prueft, ob ${CADDY_IMAGE} das caddy-dns/cloudflare-Modul enthaelt.
caddy_has_cloudflare_module() {
  docker run --rm --entrypoint caddy "$CADDY_IMAGE" list-modules 2>/dev/null \
    | grep -qi 'dns.providers.cloudflare'
}

# Validiert das aktuelle produktive Caddyfile (nur wenn Container laeuft, per exec).
validate_caddyfile() {
  caddy_is_running || return 1
  # docker exec (nicht compose exec) mit hartem Timeout, damit ein haengender
  # Exec HomeEdge nie blockiert.
  timeout --kill-after=5s "${CADDY_VALIDATE_TIMEOUT:-20}s" \
    docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1
}

# Validiert eine beliebige Caddyfile (Host-Pfad) mit "docker run" gegen das
# gebaute Image - OHNE die Service-Volumes aus docker-compose.yml (insb. den
# produktiven Caddyfile-Mount) mitzuziehen. Genau dieser Mount war beim Fresh
# Install die Ursache fuer "not a directory: ... /etc/caddy/Caddyfile".
# Schreibt den echten (maskierten) Output nach CADDY_VALIDATE_LOG und in
# CADDY_VALIDATE_OUTPUT. 0 = gueltig.
# CADDY_VALIDATE_STATUS klassifiziert das Ergebnis fuer aufrufende Funktionen:
#   ok | file_missing | image_missing | module_missing | timeout | aborted | invalid
CADDY_VALIDATE_OUTPUT=""
CADDY_VALIDATE_STATUS=""
CADDY_VALIDATE_TIMEOUT="${CADDY_VALIDATE_TIMEOUT:-20}"
_validate_caddyfile_path() {
  local f="$1" rc envargs=()
  CADDY_VALIDATE_OUTPUT=""
  CADDY_VALIDATE_STATUS=""
  [[ -f "$f" ]] || { CADDY_VALIDATE_OUTPUT="Datei nicht gefunden (oder kein File): $f"; CADDY_VALIDATE_STATUS="file_missing"; return 1; }
  mkdir -p "$HOMEEDGE_LOG_DIR" 2>/dev/null || true
  # WICHTIG: Der Validate-/Reload-Pfad baut NIE ein Image. Ist das Image nicht
  # vorhanden, wird sauber gemeldet (kein "Caddyfile ungueltig") und auf den
  # expliziten Rebuild verwiesen.
  if ! caddy_image_exists; then
    CADDY_VALIDATE_OUTPUT="Caddy-Image ${CADDY_IMAGE} fehlt - einmalig bauen: sudo homeedge caddy-rebuild"
    CADDY_VALIDATE_STATUS="image_missing"
    { echo "[$(date -Is)] ${CADDY_VALIDATE_OUTPUT}"; echo "----"; } >> "$CADDY_VALIDATE_LOG" 2>/dev/null || true
    return 1
  fi
  [[ -f "${CADDY_DIR}/.env" ]] && envargs=(--env-file "${CADDY_DIR}/.env")
  # WICHTIG: NUR die generierte Datei mounten (kein Service-Volume) und
  # --adapter caddyfile erzwingen (sonst wird die Datei als JSON interpretiert).
  # timeout schuetzt einen kleinen VPS vor Haengern; rc defensiv erfassen, da
  # eine Befehlssubstitutions-Zuweisung unter set -e sonst das Script beendet.
  rc=0
  CADDY_VALIDATE_OUTPUT="$(timeout "${CADDY_VALIDATE_TIMEOUT}" docker run --rm "${envargs[@]}" \
    -v "${f}:/etc/caddy/Caddyfile:ro" --entrypoint caddy "$CADDY_IMAGE" \
    validate --adapter caddyfile --config /etc/caddy/Caddyfile 2>&1)" || rc=$?
  if (( rc == 0 )); then
    CADDY_VALIDATE_STATUS="ok"
  elif (( rc == 124 )); then
    CADDY_VALIDATE_STATUS="timeout"
    CADDY_VALIDATE_OUTPUT="Validate-Timeout nach ${CADDY_VALIDATE_TIMEOUT}s (Docker/VPS ueberlastet?). ${CADDY_VALIDATE_OUTPUT}"
  elif (( rc == 130 || rc == 137 || rc == 143 )); then
    CADDY_VALIDATE_STATUS="aborted"
  elif grep -qiE 'module not registered|getting dns provider module|unknown dns provider|not registered:[[:space:]]*dns\.providers' <<<"${CADDY_VALIDATE_OUTPUT}"; then
    # Nur ECHTES Fehlen des DNS-Moduls (Image ohne caddy-dns/cloudflare). Das
    # blosse Wort "cloudflare" wuerde sonst jeden ungueltigen/token-losen Fehler
    # faelschlich als "Modul fehlt" einstufen (Caddyfile enthaelt immer "dns cloudflare").
    CADDY_VALIDATE_STATUS="module_missing"
  else
    CADDY_VALIDATE_STATUS="invalid"
  fi
  {
    echo "[$(date -Is)] caddy validate (rc=${rc}, status=${CADDY_VALIDATE_STATUS}) fuer ${f}"
    printf '%s\n' "$CADDY_VALIDATE_OUTPUT"
    echo "----"
  } 2>/dev/null | mask_secrets >> "$CADDY_VALIDATE_LOG" 2>/dev/null || true
  return $rc
}

# Prueft, ob fuer eine Domain lokal (per SNI auf 127.0.0.1) ein Zertifikat ausgeliefert wird.
cert_ready() {
  local domain="$1"
  command -v openssl >/dev/null 2>&1 || return 0
  echo | timeout 8 openssl s_client -servername "$domain" -connect 127.0.0.1:443 2>/dev/null \
    | openssl x509 -noout -subject >/dev/null 2>&1
}

# Sucht in den letzten Caddy-Logs nach einem ECHTEN ACME-/Zertifikatsfehler fuer
# die Domain (z. B. falscher Cloudflare Token). 0 = Fehler gefunden.
caddy_acme_error_for_domain() {
  local domain="$1" logs
  command -v docker >/dev/null 2>&1 || return 1
  logs="$(docker logs --since 30m --tail 800 caddy-edge 2>&1 || true)"
  grep -iF "$domain" <<<"$logs" \
    | grep -qiE 'could not get certificate|obtain(ing)? certificate.*(fail|error)|challenge failed|authorization (failed|error)|"level":"error"|invalid (api )?token|unauthorized|no solvers|acme.*error'
}

# Wartet nach einem Reload, bis Zertifikate aktiv sind (DNS-01 dauert).
# $1 = maximale Wartezeit in Sekunden (Default 120). Beim normalen Reload wird
# ein KURZER Check (15s) genutzt; der lange Check (120s) nur nach explizitem
# Rebuild/Update oder ueber den Menuepunkt "Zertifikate pruefen".
wait_for_certs() {
  load_env
  [[ -s "$SERVICES_FILE" ]] || return 0
  if ! command -v openssl >/dev/null 2>&1; then info "openssl fehlt - Zertifikatscheck uebersprungen."; return 0; fi
  local max="${1:-120}"
  local deadline=$((SECONDS+max)) domain _s _i _p pending
  info "Pruefe Zertifikate lokal per SNI (bis zu ${max}s, DNS-01 kann dauern)..."
  while :; do
    pending=0
    while IFS=$'\t' read -r domain _s _i _p _pr || [[ -n "$domain" ]]; do
      [[ -z "$domain" ]] && continue
      cert_ready "$domain" || pending=$((pending+1))
    done < "$SERVICES_FILE"
    (( pending == 0 )) && break
    (( SECONDS >= deadline )) && break
    sleep 5
  done
  # Endbewertung: GRUEN ok, GELB "wartet noch" (kein Fehler im Log), ROT echter
  # ACME-/Cloudflare-/DNS-Fehler. Rueckgabe 1, sobald mind. eine Domain einen
  # eindeutigen ACME-Fehler hat (damit reload/apply Exitcode != 0 liefern).
  local rc=0
  while IFS=$'\t' read -r domain _s _i _p _pr || [[ -n "$domain" ]]; do
    [[ -z "$domain" ]] && continue
    if cert_ready "$domain"; then
      ok "Zertifikat aktiv (SNI ok): ${domain}"
    elif caddy_acme_error_for_domain "$domain"; then
      err "TLS ${domain} fehlgeschlagen - eindeutiger ACME-/Cloudflare-/DNS-01-Fehler in den Caddy-Logs."
      rc=1
    else
      warn "Warte auf Zertifikat fuer ${domain} (noch ausstehend, kein Fehler im Log) - spaeter testen: homeedge test-domain ${domain}"
    fi
  done < "$SERVICES_FILE"
  if (( rc != 0 )); then
    err "Cloudflare Token / DNS-01 / ACME pruefen (sudo homeedge caddy-logs ; sudo homeedge set-token)."
  fi
  return $rc
}

# Schreibt Stack, generiert das Caddyfile atomar aus der Service-Liste, prueft
# Vollstaendigkeit und validiert. 0 = ok (neues Caddyfile aktiv), 1 = Fehler
# (auf vorherige Version zurueckgerollt, nichts kaputt).
# CADDY_PREPARE_STATUS teilt Aufrufern mit, WARUM die Vorbereitung fehlschlug:
#   ok | services_invalid | gen_failed | incomplete | validate_invalid | validate_env
# "validate_env" = umgebungsbedingt (Image fehlt / Timeout / Abbruch) - die
# produktive Config ist NICHT kaputt, daher kein harter Migrationsfehler.
CADDY_PREPARE_STATUS=""
_caddy_prepare_config() {
  load_env
  CADDY_PREPARE_STATUS=""
  # services.tsv ZWINGEND validieren, bevor irgendetwas generiert wird.
  if ! validate_services_file; then
    err "services.tsv ist ungueltig - Caddyfile wird NICHT neu erzeugt, letzte Version bleibt aktiv."
    err "Bitte ausfuehren: sudo homeedge repair-services"
    CADDY_PREPARE_STATUS="services_invalid"
    return 1
  fi
  # Falsch angelegtes Caddyfile-Verzeichnis sichern, dann Stack schreiben.
  _ensure_caddyfile_not_dir
  write_caddy_stack
  mkdir -p "$CADDY_DIR"
  # In die GENERATED-Datei erzeugen (nicht in die produktive Caddyfile!) und
  # genau diese validieren. So wird beim Mount nie die produktive Datei beruehrt.
  local cf="${CADDY_DIR}/Caddyfile" gen="${CADDY_DIR}/Caddyfile.generated"
  generate_caddyfile_to "$gen"
  # Datei-Sanity: existiert, ist Datei, nicht leer, lesbar.
  if [[ ! -s "$gen" || -d "$gen" ]]; then err "Caddyfile.generated konnte nicht sauber erzeugt werden."; rm -f "$gen" 2>/dev/null || true; CADDY_PREPARE_STATUS="gen_failed"; return 1; fi
  chmod 644 "$gen" 2>/dev/null || true
  # Vollstaendigkeit pruefen: grep -F (Fixstring), KEIN Regex mit Domain-Inhalt,
  # damit Wildcard-Domains wie *.example.de sicher gematcht werden (Bug P2).
  local missing=0 d _s _i _p _pr
  if [[ -s "$SERVICES_FILE" ]]; then
    while IFS=$'\t' read -r d _s _i _p _pr || [[ -n "$d" ]]; do
      [[ -z "$d" ]] && continue
      grep -Fq "${d} {" "$gen" || { err "Domain fehlt im generierten Caddyfile: $d"; missing=1; }
    done < "$SERVICES_FILE"
  fi
  if (( missing )); then rm -f "$gen"; err "Abbruch: Caddyfile unvollstaendig, nichts geaendert."; CADDY_PREPARE_STATUS="incomplete"; return 1; fi
  # GENERATED-Datei VOR dem produktiven Ersetzen validieren. Nur bei OK ersetzen.
  # WICHTIG: Sauber unterscheiden zwischen einer WIRKLICH ungueltigen Caddyfile
  # und umgebungsbedingten Fehlern (Image fehlt / Modul fehlt / Timeout / Abbruch).
  # Nur bei "invalid" wird die generierte Datei als .failed gesichert.
  if ! _validate_caddyfile_path "$gen"; then
    case "${CADDY_VALIDATE_STATUS}" in
      image_missing)
        rm -f "$gen"
        err "Caddy-Image ${CADDY_IMAGE} fehlt - Validierung/Reload nicht moeglich (es wird NICHT automatisch gebaut)."
        info "Einmalig bauen: sudo homeedge caddy-rebuild"
        info "Die produktive Caddyfile bleibt unveraendert aktiv."
        CADDY_PREPARE_STATUS="validate_env"
        return 1 ;;
      module_missing)
        rm -f "$gen"
        err "Caddy Cloudflare DNS Modul fehlt im Image ${CADDY_IMAGE}."
        info "Caddy Image neu bauen: sudo homeedge caddy-rebuild"
        info "Die produktive Caddyfile bleibt unveraendert aktiv."
        CADDY_PREPARE_STATUS="validate_env"
        return 1 ;;
      timeout)
        rm -f "$gen"
        err "Caddy validate hat das Zeitlimit (${CADDY_VALIDATE_TIMEOUT}s) ueberschritten - Docker/VPS ueberlastet?"
        info "Spaeter erneut: sudo homeedge reload   |   Neu bauen: sudo homeedge caddy-rebuild"
        info "Die produktive Caddyfile bleibt unveraendert aktiv."
        CADDY_PREPARE_STATUS="validate_env"
        return 1 ;;
      aborted)
        rm -f "$gen"
        warn "Caddy validate wurde abgebrochen (CTRL+C) - keine Aenderung vorgenommen."
        info "Die produktive Caddyfile bleibt unveraendert aktiv."
        CADDY_PREPARE_STATUS="validate_env"
        return 1 ;;
      *)
        # Wirklich ungueltige Caddyfile: zur Analyse sichern und hart melden.
        cp -a "$gen" "${CADDY_DIR}/Caddyfile.failed" 2>/dev/null || true
        rm -f "$gen"
        err "Neue Caddyfile ist ungueltig - die produktive Caddyfile bleibt unveraendert."
        err "Caddy validate:"
        printf '%s\n' "${CADDY_VALIDATE_OUTPUT:-(kein Output)}" | mask_secrets | sed 's/^/    /'
        info "Fehlerhafte Datei gespeichert: ${CADDY_DIR}/Caddyfile.failed"
        info "Log: ${CADDY_VALIDATE_LOG}"
        CADDY_PREPARE_STATUS="validate_invalid"
        return 1 ;;
    esac
  fi
  ok "Config validiert"
  # Formatieren und DANACH erneut validieren (caddy fmt sollte nie etwas kaputt
  # machen - vor Release pruefen wir es trotzdem). Schlaegt das Re-Validate fehl,
  # wird die unformatierte (bereits validierte) Datei genutzt.
  if timeout "${CADDY_FMT_TIMEOUT:-20}" docker run --rm -v "${gen}:/etc/caddy/Caddyfile" --entrypoint caddy "$CADDY_IMAGE" fmt --overwrite /etc/caddy/Caddyfile >/dev/null 2>&1; then
    if _validate_caddyfile_path "$gen"; then
      ok "Re-Validate nach caddy fmt ok"
    else
      warn "Re-Validate nach caddy fmt fehlgeschlagen - regeneriere unformatierte, bereits validierte Version."
      generate_caddyfile_to "$gen"; chmod 644 "$gen" 2>/dev/null || true
    fi
  fi
  # Gueltig: produktiv ersetzen (cp, damit Caddyfile.generated als Referenz bleibt).
  cp -a "$gen" "$cf"
  chmod 644 "$cf" 2>/dev/null || true
  # Erfolgreich -> alten Fehlerstand aufraeumen, damit health/verify nicht weiter warnen.
  rm -f "${CADDY_DIR}/Caddyfile.failed" 2>/dev/null || true
  ok "Caddyfile generiert (alle Dienste enthalten)"
  CADDY_PREPARE_STATUS="ok"
  return 0
}

reload_caddy() {
  section "Caddy neu laden"
  require_valid_services || return 1
  _caddy_prepare_config || return 1
  caddy_compose_file_exists || { err "Caddy Compose-Datei fehlt: $CADDY_COMPOSE_FILE"; caddy_stack_repair_hint; return 1; }
  # Reload baut NIE ein Image - _caddy_prepare_config hat bereits gegen ein
  # vorhandenes Image validiert (sonst waeren wir hier nicht angekommen).
  # Reload erfolgt per "docker exec" direkt im laufenden Container. Bei Timeout
  # wird KEIN stiller force-recreate ausgefuehrt - der Benutzer wird gefragt.
  if caddy_is_running; then
    info "Lade aktive Caddy-Konfiguration im laufenden Container neu..."
    local reload_rc=0; caddy_exec_reload || reload_rc=$?
    case "$reload_rc" in
      0) ok "Reload erfolgreich." ;;
      2) warn "Reload-Befehl Timeout - pruefe Caddy-Status..."
         ok "Caddy hat die Konfiguration geladen (Log: 'load complete'/'config is unchanged'), aber der Docker-Exec-Befehl kam nicht sauber zurueck." ;;
      *) err "Caddy-Reload fehlgeschlagen - der Container wird NICHT automatisch neu erzeugt."
         if [[ -t 0 ]] && yesno "Caddy-Container neu erzeugen?" "n"; then
           info "Erzeuge Caddy-Container neu (up -d --force-recreate, Timeout)..."
           caddy_compose_up recreate || true
         else
           info "Container NICHT neu erzeugt. Manuell moeglich: sudo homeedge restart | sudo homeedge caddy-logs"
           return 1
         fi ;;
    esac
  else
    # Container laeuft nicht: nur starten (up -d), KEIN force-recreate.
    warn "Caddy-Container laeuft nicht - starte Stack (up -d)..."
    caddy_compose_up up || true
  fi
  if caddy_is_running; then ok "Container laeuft"; else err "Container laeuft nicht"; caddy_stack_repair_hint; return 1; fi
  # Nur "Container laeuft" reicht nicht: KURZER lokaler SNI-Check (max 15s), damit
  # der normale Reload nicht bis zu 120s blockiert. Der lange Check (120s) laeuft
  # nur nach Rebuild/Update oder ueber den Menuepunkt "Zertifikate pruefen".
  # wait_for_certs liefert 1 NUR bei eindeutigem ACME-Fehler -> dann auch hier 1
  # (Exitcode != 0), aber der Container/die Config bleiben aktiv.
  local cert_rc=0; wait_for_certs "${CADDY_RELOAD_CERT_WAIT:-15}" || cert_rc=$?
  echo
  info "Zertifikate koennen per DNS-01 laenger dauern - vollstaendig pruefen: sudo homeedge certs"
  info "Test einer Domain: sudo homeedge test-domain DEINE.DOMAIN"
  return $cert_rc
}

# Wie reload, aber baut das Image explizit neu (build) - mit gleicher
# Validierung/Rollback. Dies ist ein AUSDRUECKLICHER Build-Pfad, daher wird das
# Image hier ZUERST gebaut, bevor validiert wird. Mit "--skip-build" wird NICHT
# gebaut (der Aufrufer, z. B. caddy_rebuild, hat das Image bereits gebaut) -
# so wird ein doppelter Build vermieden.
restart_caddy() {
  local skip_build=0
  [[ "${1:-}" == "--skip-build" ]] && skip_build=1
  section "Caddy neu starten / neu bauen"
  load_env
  _ensure_caddyfile_not_dir
  write_caddy_stack
  caddy_compose_file_exists || { err "Caddy Compose-Datei fehlt: $CADDY_COMPOSE_FILE"; caddy_stack_repair_hint; return 1; }
  if (( skip_build )); then
    # Kein Build: das Image MUSS bereits vorhanden sein.
    caddy_image_exists || { err "Caddy-Image ${CADDY_IMAGE} fehlt - erst bauen: sudo homeedge caddy-rebuild"; return 1; }
  else
    # Image zuerst bauen (expliziter Build-Pfad), dann gegen das frische Image validieren.
    if ! caddy_build_image; then err "Caddy-Image-Build fehlgeschlagen."; return 1; fi
  fi
  _caddy_prepare_config || return 1
  # --force-recreate erzwingt den Neustart mit der aktuellen Caddyfile (mit Timeout+Diagnose).
  if ! caddy_compose_up recreate; then
    err "Caddy-Start fehlgeschlagen."; return 1
  fi
  if caddy_is_running; then ok "Container laeuft"; else err "Container laeuft nicht"; caddy_stack_repair_hint; return 1; fi
  # Nach explizitem Rebuild: langer Zertifikatscheck (bis 120s).
  local cert_rc=0; wait_for_certs 120 || cert_rc=$?
  return $cert_rc
}

# Erzwingt das Neuschreiben des kompletten Caddy-Stacks und baut/startet ihn neu.
# Fuer die "Caddy Stack fehlt/kaputt"-Reparatur (sudo homeedge caddy-rebuild).
caddy_rebuild() {
  need_root; load_env
  section "Caddy Stack neu erstellen / neu bauen"
  require_valid_services || { err "services.tsv ungueltig - bitte zuerst: sudo homeedge repair-services"; return 1; }
  # Falsch angelegtes Caddyfile-Verzeichnis sichern (Mountbug-Folge).
  _ensure_caddyfile_not_dir
  # Stack-Dateien (Dockerfile, docker-compose.yml, .env, Verzeichnisse) sicher
  # anlegen, BEVOR validiert/gebaut wird - auch wenn vorher gar nichts da war.
  write_caddy_stack
  mkdir -p "${CADDY_DIR}/data" "${CADDY_DIR}/config" "${CADDY_DIR}/logs"
  caddy_compose_file_exists || { err "Compose-Datei konnte nicht geschrieben werden: $CADDY_COMPOSE_FILE"; return 1; }
  ok "Caddy-Stack-Dateien geschrieben (Dockerfile, docker-compose.yml, .env, data/config/logs)"
  # Image bauen (mit caddy-dns/cloudflare) und Modul verifizieren.
  if ! caddy_build_image; then err "Caddy-Image-Build fehlgeschlagen."; return 1; fi
  if caddy_has_cloudflare_module; then
    ok "Caddy Cloudflare DNS Modul im Image vorhanden."
  else
    err "Caddy Cloudflare DNS Modul fehlt im Image."
    info "Bitte Image neu bauen: sudo homeedge caddy-rebuild"
    return 1
  fi
  # Caddyfile generieren/validieren + Container starten. Das Image wurde OBEN
  # bereits gebaut -> --skip-build vermeidet einen zweiten (doppelten) Build.
  restart_caddy --skip-build || return 1
  # Lokaler SNI-Test je Domain (Abschlusskontrolle).
  if [[ -s "$SERVICES_FILE" ]]; then
    local d _s _i _p _pr
    while IFS=$'\t' read -r d _s _i _p _pr || [[ -n "$d" ]]; do
      [[ -z "$d" ]] && continue
      if cert_ready "$d"; then ok "SNI/TLS lokal ok: ${d}"; else warn "Zertifikat fuer ${d} noch nicht aktiv (DNS-01 kann dauern): sudo homeedge test-domain ${d}"; fi
    done < "$SERVICES_FILE"
  fi
}

install_fail2ban() {
  load_env; mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/filter.d
  # SSH_PORT muss numerisch sein, sonst vergiftet ein kaputter Wert die sshd-Jail
  # (fail2ban-client -t schlaegt fehl). Defensiver Fallback auf 22.
  if ! [[ "${SSH_PORT:-}" =~ ^[0-9]+$ ]]; then
    warn "SSH_PORT='${SSH_PORT:-}' ist nicht numerisch - nutze 22 fuer die Fail2ban sshd-Jail."
    SSH_PORT=22
  fi
  # Caddy-Access-Log muss existieren, bevor Fail2ban startet (sonst Jail-Fehler).
  mkdir -p "${CADDY_DIR}/logs"; touch "${CADDY_DIR}/logs/access.log"

  # Vorherige caddy-Konfig sichern, um bei fehlerhaftem Test zurueckzurollen.
  local bdir; bdir="$(mktemp -d)"
  cp -a /etc/fail2ban/jail.d/caddy-auth.local "${bdir}/" 2>/dev/null || true
  cp -a /etc/fail2ban/filter.d/caddy-auth.conf "${bdir}/" 2>/dev/null || true

  cat > /etc/fail2ban/jail.d/sshd-local.conf <<EOF2
[sshd]
enabled = true
port = ${SSH_PORT}
filter = sshd
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF2
  if [[ "${CADDY_FAIL2BAN}" == "1" ]]; then
    cat > /etc/fail2ban/filter.d/caddy-auth.conf <<'EOF2'
[Definition]
failregex = ^.*"remote_ip":"<HOST>".*"status":(401|403).*
ignoreregex =
EOF2
    cat > /etc/fail2ban/jail.d/caddy-auth.local <<EOF2
[caddy-auth]
enabled = true
filter = caddy-auth
logpath = ${CADDY_DIR}/logs/access.log
maxretry = ${F2B_CADDY_MAXRETRY}
findtime = ${F2B_CADDY_FINDTIME}
bantime = ${F2B_CADDY_BANTIME}
backend = auto
port = https
EOF2
  else
    rm -f /etc/fail2ban/jail.d/caddy-auth.local
  fi

  systemctl enable fail2ban >/dev/null 2>&1 || true
  # Konfiguration testen, bevor neu gestartet wird.
  if fail2ban-client -t >/dev/null 2>&1; then
    systemctl restart fail2ban && ok "Fail2ban konfiguriert und neu gestartet."
  else
    err "Fail2ban-Konfigtest fehlgeschlagen - stelle vorherige caddy-auth-Konfig wieder her."
    rm -f /etc/fail2ban/jail.d/caddy-auth.local /etc/fail2ban/filter.d/caddy-auth.conf
    cp -a "${bdir}/caddy-auth.local" /etc/fail2ban/jail.d/ 2>/dev/null || true
    cp -a "${bdir}/caddy-auth.conf" /etc/fail2ban/filter.d/ 2>/dev/null || true
    # Nur neu starten, wenn die wiederhergestellte Konfig den Test besteht.
    if fail2ban-client -t >/dev/null 2>&1; then
      systemctl restart fail2ban 2>/dev/null || true
    else
      err "Auch die wiederhergestellte Fail2ban-Konfig ist fehlerhaft - Fail2ban NICHT neu gestartet."
      err "Bitte manuell pruefen: sudo fail2ban-client -t"
    fi
    rm -rf "$bdir"
    return 1
  fi
  rm -rf "$bdir"
}

# Fail2ban-Konfiguration testen (fail2ban-client -t).
f2b_test_config() {
  section "Fail2ban Config testen"
  if fail2ban-client -t; then ok "Konfiguration ist gueltig."; else err "Konfiguration fehlerhaft (siehe oben)."; fi
}

# caddy-auth Jail temporaer deaktivieren bzw. wieder aktivieren.
f2b_caddy_disable() {
  need_root; load_env
  section "caddy-auth deaktivieren"
  CADDY_FAIL2BAN="0"; save_env; install_fail2ban
  ok "caddy-auth deaktiviert."
}
f2b_caddy_enable() {
  need_root; load_env
  section "caddy-auth aktivieren"
  CADDY_FAIL2BAN="1"; save_env; install_fail2ban
}

# Schwellenwerte fuer caddy-auth anzeigen/aendern.
f2b_thresholds() {
  need_root; load_env
  section "caddy-auth Schwellenwerte"
  echo "Aktuell: maxretry=${F2B_CADDY_MAXRETRY}  findtime=${F2B_CADDY_FINDTIME}  bantime=${F2B_CADDY_BANTIME}"
  if ! yesno "Werte aendern?" "n"; then return; fi
  local mr ft bt
  mr="$(ask "maxretry" "${F2B_CADDY_MAXRETRY}")"
  ft="$(ask "findtime (z.B. 10m)" "${F2B_CADDY_FINDTIME}")"
  bt="$(ask "bantime (z.B. 15m)" "${F2B_CADDY_BANTIME}")"
  [[ "$mr" =~ ^[0-9]+$ ]] || { err "maxretry muss eine Zahl sein."; return 1; }
  # findtime/bantime muessen ein gueltiges Fail2ban-Zeitformat sein (z. B. 10m,
  # 1h, 600). Sonst schlaegt spaeter JEDER "fail2ban-client -t" fehl und rollt
  # caddy-auth still zurueck - deshalb VOR dem Speichern pruefen.
  [[ "$ft" =~ ^[0-9]+[smhdw]?$ ]] || { err "findtime ungueltig (z. B. 600, 10m, 1h)."; return 1; }
  [[ "$bt" =~ ^[0-9]+[smhdw]?$ ]] || { err "bantime ungueltig (z. B. 900, 15m, 1h)."; return 1; }
  F2B_CADDY_MAXRETRY="$mr"; F2B_CADDY_FINDTIME="$ft"; F2B_CADDY_BANTIME="$bt"
  save_env; install_fail2ban
  ok "Schwellenwerte gespeichert: maxretry=${mr} findtime=${ft} bantime=${bt}"
}

# ------------------------------------------------------------
# Fail2ban Verwaltung
# ------------------------------------------------------------
f2b_jails() {
  fail2ban-client status 2>/dev/null \
    | sed -n 's/.*Jail list:[[:space:]]*//p' \
    | tr ',' '\n' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | grep -v '^$' || true
}

f2b_banned_ips_for_jail() {
  local jail="$1" ips=""
  ips="$(fail2ban-client get "$jail" banip 2>/dev/null || true)"
  if [[ -z "$ips" || "$ips" == "[]" ]]; then
    ips="$(fail2ban-client status "$jail" 2>/dev/null | sed -n 's/.*Banned IP list:[[:space:]]*//p' || true)"
  fi
  ips="$(echo "$ips" | tr -d '[],' | xargs 2>/dev/null || true)"
  [[ -n "$ips" ]] && printf '%s\n' $ips
}

f2b_status_overview() {
  section "Fail2ban Uebersicht"
  if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
    err "Fail2ban laeuft nicht."
  else
    ok "Fail2ban Service laeuft."
  fi
  echo
  fail2ban-client status 2>/dev/null || { err "fail2ban-client nicht erreichbar."; return 1; }
  echo
  local jail
  while read -r jail; do
    [[ -z "$jail" ]] && continue
    printf '%b\n' "${C_BOLD}Jail: ${jail}${C_RESET}"
    fail2ban-client status "$jail" 2>/dev/null | sed -n '/Currently failed:/p;/Total failed:/p;/Currently banned:/p;/Total banned:/p;/Banned IP list:/p' || true
    echo
  done < <(f2b_jails)
}

f2b_show_banned_ips() {
  section "Gebannte IPs"
  local found=0 jail ips ip
  while read -r jail; do
    [[ -z "$jail" ]] && continue
    mapfile -t ips < <(f2b_banned_ips_for_jail "$jail")
    if (( ${#ips[@]} == 0 )); then
      printf '%-14s %s\n' "$jail" "keine"
    else
      for ip in "${ips[@]}"; do
        printf '%-14s %s\n' "$jail" "$ip"
        found=1
      done
    fi
  done < <(f2b_jails)
  echo
  (( found == 0 )) && ok "Aktuell sind keine IPs gebannt."
}

f2b_unban_select() {
  section "IP aus Liste entbannen"
  local entries=() jail ips ip i choice entry

  while read -r jail; do
    [[ -z "$jail" ]] && continue
    mapfile -t ips < <(f2b_banned_ips_for_jail "$jail")
    for ip in "${ips[@]}"; do
      [[ -z "$ip" ]] && continue
      entries+=("${jail}|${ip}")
    done
  done < <(f2b_jails)

  if (( ${#entries[@]} == 0 )); then
    ok "Keine gebannten IPs vorhanden."
    return 0
  fi

  for i in "${!entries[@]}"; do
    IFS='|' read -r jail ip <<< "${entries[$i]}"
    printf '  %b%2d%b) %-14s %s\n' "$C_GREEN" "$((i+1))" "$C_RESET" "$jail" "$ip"
  done
  echo
  choice="$(ask "Welche Nummer entbannen? 0 = Abbruch" "0")"
  [[ "$choice" =~ ^[0-9]+$ ]] || { err "Ungueltige Eingabe."; return 1; }
  (( choice == 0 )) && return 0
  if (( choice < 1 || choice > ${#entries[@]} )); then err "Ungueltige Nummer."; return 1; fi

  entry="${entries[$((choice-1))]}"
  IFS='|' read -r jail ip <<< "$entry"
  warn "Entbanne ${ip} aus Jail ${jail}."
  if yesno "Fortfahren?" "y"; then
    fail2ban-client set "$jail" unbanip "$ip" >/dev/null
    ok "${ip} wurde aus ${jail} entbannt."
  fi
}

f2b_select_jail() {
  local jails=() i choice
  mapfile -t jails < <(f2b_jails)
  if (( ${#jails[@]} == 0 )); then err "Keine Fail2ban-Jails gefunden."; return 1; fi
  for i in "${!jails[@]}"; do printf '  %b%2d%b) %s\n' "$C_GREEN" "$((i+1))" "$C_RESET" "${jails[$i]}"; done
  choice="$(ask "Jail auswaehlen" "1")"
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  (( choice >= 1 && choice <= ${#jails[@]} )) || return 1
  printf '%s\n' "${jails[$((choice-1))]}"
}

f2b_unban_manual() {
  section "IP manuell entbannen"
  local jail ip
  jail="$(f2b_select_jail)" || { err "Keine gueltige Jail-Auswahl."; return 1; }
  ip="$(ask "IP-Adresse entbannen")"
  [[ -n "$ip" ]] || { err "Keine IP angegeben."; return 1; }
  fail2ban-client set "$jail" unbanip "$ip" >/dev/null
  ok "${ip} wurde aus ${jail} entbannt."
}

f2b_show_log() {
  section "Fail2ban Log"
  echo "1) Letzte 100 Zeilen"
  echo "2) Nur Ban/Unban anzeigen"
  echo "3) Live verfolgen"
  echo "0) Zurueck"
  echo
  local c; c="$(ask "Auswahl" "1")"
  case "$c" in
    1) tail -100 /var/log/fail2ban.log 2>/dev/null || journalctl -u fail2ban -n 100 --no-pager ;;
    2) grep -Ei "(Ban |Unban )" /var/log/fail2ban.log 2>/dev/null | tail -100 || journalctl -u fail2ban --no-pager | grep -Ei "(Ban |Unban )" | tail -100 ;;
    3) tail -f /var/log/fail2ban.log 2>/dev/null || journalctl -u fail2ban -f ;;
    0) return ;;
    *) err "Ungueltige Auswahl." ;;
  esac
}

f2b_test_filter() {
  section "Fail2ban Filter testen"
  echo "1) caddy-auth gegen Caddy Access Log"
  echo "2) sshd gegen systemd Journal"
  echo "0) Zurueck"
  echo
  local c; c="$(ask "Auswahl" "1")"
  case "$c" in
    1)
      if [[ ! -f /etc/fail2ban/filter.d/caddy-auth.conf ]]; then err "Filter caddy-auth fehlt."; return 1; fi
      if [[ ! -f "${CADDY_DIR}/logs/access.log" ]]; then err "Caddy Access Log fehlt: ${CADDY_DIR}/logs/access.log"; return 1; fi
      fail2ban-regex "${CADDY_DIR}/logs/access.log" /etc/fail2ban/filter.d/caddy-auth.conf || true
      ;;
    2)
      fail2ban-regex systemd-journal /etc/fail2ban/filter.d/sshd.conf systemd-journal[journalmatch='_SYSTEMD_UNIT=ssh.service + _COMM=sshd'] || true
      ;;
    0) return ;;
    *) err "Ungueltige Auswahl." ;;
  esac
}

f2b_reconfigure() {
  section "Fail2ban neu konfigurieren"
  install_fail2ban
  ok "Fail2ban wurde neu konfiguriert und neu gestartet."
  fail2ban-client status || true
}

f2b_just_restart() {
  section "Fail2ban neu starten"
  systemctl restart fail2ban && ok "Fail2ban neu gestartet." || err "Neustart fehlgeschlagen."
  fail2ban-client status || true
}


# ------------------------------------------------------------
# CrowdSec (optionales Security-Modul, Phase 1)
# ------------------------------------------------------------
# Grundsaetze: ergaenzt Fail2ban + caddy-auth (ersetzt sie NICHT), oeffnet KEINE
# neuen Ports, aendert KEINE UFW-Regeln, kein Geo-Blocking, kein WAF/AppSec,
# keine Jellyfin-spezifischen Login-Bans. Der lokale Schutz funktioniert ohne
# CrowdSec Console; die Console ist optional und wird nie automatisch verbunden.
#
# SSH-DOPPELABDECKUNG (bewusst): SSH wird aktuell parallel von Fail2ban
# (sshd-Jail) UND CrowdSec (crowdsecurity/sshd-Collection) geschuetzt. Das ist
# gewollte Defense-in-Depth - beide bannen unabhaengig voneinander. HomeEdge
# deaktiviert NICHTS automatisch. Wer nur eine Ebene will, kann die Fail2ban
# sshd-Jail bzw. die CrowdSec-sshd-Collection manuell entfernen.

# 0 = cscli/crowdsec vorhanden.
crowdsec_installed() { command -v cscli >/dev/null 2>&1; }

# Reload (bevorzugt) bzw. Restart von crowdsec - errexit-sicher.
_crowdsec_reload() { systemctl reload crowdsec 2>/dev/null || systemctl restart crowdsec 2>/dev/null || true; }

# Gueltiger Whitelist-Eintrag? IPv4/IPv6 mit optionalem /prefix. Lehnt pauschale
# oeffentliche Netze (0.0.0.0/0, ::/0) und leere Eingaben ab.
_crowdsec_valid_wl_entry() {
  local e="${1:-}"
  [[ -z "$e" ]] && return 1
  case "$e" in 0.0.0.0/0|::/0|0.0.0.0|::|*/0) return 1 ;; esac
  [[ "$e" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]] && return 0
  [[ "$e" == *:* && "$e" =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]] && return 0
  return 1
}

# Erkennt das passende Firewall-Bouncer-Backend: "nftables" oder "iptables".
# CROWDSEC_BOUNCER kann das erzwingen (nftables|iptables), sonst Auto-Erkennung
# ueber das iptables-Backend (nf_tables vs. legacy). Gibt genau ein Wort aus.
crowdsec_detect_bouncer() {
  load_env
  case "${CROWDSEC_BOUNCER:-auto}" in
    nftables|nft) echo "nftables"; return 0 ;;
    iptables|legacy) echo "iptables"; return 0 ;;
  esac
  # Auto: primaeres Signal ist der iptables-Backend-Tag.
  local ver; ver="$(iptables -V 2>/dev/null || true)"
  if grep -qi 'nf_tables' <<<"$ver"; then echo "nftables"; return 0; fi
  if grep -qi 'legacy'    <<<"$ver"; then echo "iptables"; return 0; fi
  # Kein eindeutiger Tag: nft nutzbar -> nftables, sonst iptables.
  if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then echo "nftables"; return 0; fi
  echo "iptables"
}

# Schreibt die Acquisition-Datei fuer das Caddy-Access-Log und stellt die
# Logdatei sicher (wie Fail2ban), damit die Acquisition nicht mit Fehler startet.
crowdsec_write_acquis() {
  load_env
  local log="${CROWDSEC_CADDY_LOG:-/opt/caddy-edge/logs/access.log}"
  mkdir -p "$(dirname "$log")"; touch "$log"
  mkdir -p /etc/crowdsec/acquis.d
  cat > "$CROWDSEC_ACQUIS_FILE" <<EOF
filenames:
  - ${log}
labels:
  type: caddy
EOF
  ok "Acquisition geschrieben: ${CROWDSEC_ACQUIS_FILE} -> ${log}"
}

# Schreibt die Whitelist-Parser-Datei aus: Loopback + WireGuard-Endpunkte +
# internes LAN (HOME_SUBNET) + explizit konfigurierte CROWDSEC_WHITELIST_IPS.
# So bannt CrowdSec NIE die eigene Infrastruktur. Keine pauschalen oeff. Netze.
crowdsec_write_whitelist() {
  load_env
  mkdir -p "$(dirname "$CROWDSEC_WHITELIST_FILE")"
  local -a ips=() cidrs=()
  # Loopback (immer).
  cidrs+=("127.0.0.0/8"); ips+=("::1")
  # WireGuard-Endpunkte + internes LAN.
  [[ -n "${VPS_WG_IP:-}" ]]    && ips+=("$VPS_WG_IP")
  [[ -n "${CLIENT_WG_IP:-}" ]] && ips+=("$CLIENT_WG_IP")
  [[ -n "${HOME_SUBNET:-}" ]]  && cidrs+=("$HOME_SUBNET")
  # Explizite Zusatz-IPs (Komma- oder Space-getrennt), streng validiert.
  local e
  for e in ${CROWDSEC_WHITELIST_IPS//,/ }; do
    if ! _crowdsec_valid_wl_entry "$e"; then
      warn "Whitelist-Eintrag ignoriert (ungueltig oder pauschales oeff. Netz): ${e}"
      continue
    fi
    if [[ "$e" == */* ]]; then cidrs+=("$e"); else ips+=("$e"); fi
  done
  {
    echo "name: homeedge/trusted"
    echo 'description: "HomeEdge: eigene Infrastruktur nie bannen (loopback, WireGuard, LAN, explizit)"'
    echo "whitelist:"
    echo '  reason: "HomeEdge trusted networks"'
    if (( ${#ips[@]} )); then
      echo "  ip:"
      for e in "${ips[@]}"; do echo "    - \"${e}\""; done
    fi
    if (( ${#cidrs[@]} )); then
      echo "  cidr:"
      for e in "${cidrs[@]}"; do echo "    - \"${e}\""; done
    fi
  } > "$CROWDSEC_WHITELIST_FILE"
  chmod 0644 "$CROWDSEC_WHITELIST_FILE"
  ok "Whitelist geschrieben: ${CROWDSEC_WHITELIST_FILE} (ip=${#ips[@]}, cidr=${#cidrs[@]})."
}

crowdsec_whitelist_show() {
  load_env
  section "CrowdSec Whitelist (eigene IPs)"
  info "Immer vertraut: Loopback, WireGuard-Endpunkte (${VPS_WG_IP:-?}, ${CLIENT_WG_IP:-?}), internes LAN (${HOME_SUBNET:-?})."
  echo "Explizite Zusatz-IPs (CROWDSEC_WHITELIST_IPS): ${CROWDSEC_WHITELIST_IPS:-<leer>}"
  if [[ -f "$CROWDSEC_WHITELIST_FILE" ]]; then
    echo; echo "Aktive Whitelist-Datei (${CROWDSEC_WHITELIST_FILE}):"
    sed 's/^/  /' "$CROWDSEC_WHITELIST_FILE"
  else
    warn "Whitelist-Datei noch nicht geschrieben (entsteht bei crowdsec-install oder beim Speichern)."
  fi
}

# Fuegt eine explizite IP/CIDR hinzu (validiert, dedupliziert), schreibt Datei neu.
crowdsec_whitelist_add() {
  load_env
  local e; e="$(ask "IP oder CIDR hinzufuegen (z. B. 10.0.1.5 oder 192.168.20.0/24)")"
  if ! _crowdsec_valid_wl_entry "$e"; then err "Ungueltig oder pauschales oeff. Netz nicht erlaubt: ${e:-<leer>}"; return 1; fi
  local cur=" ${CROWDSEC_WHITELIST_IPS//,/ } "
  if [[ "$cur" == *" $e "* ]]; then warn "Bereits enthalten: ${e}"; return 0; fi
  CROWDSEC_WHITELIST_IPS="${CROWDSEC_WHITELIST_IPS:+${CROWDSEC_WHITELIST_IPS},}${e}"
  save_env
  crowdsec_installed && { crowdsec_write_whitelist; _crowdsec_reload; } || info "Gespeichert. Wird bei crowdsec-install aktiv."
  ok "Hinzugefuegt: ${e}"
}

# Entfernt eine explizite IP/CIDR aus CROWDSEC_WHITELIST_IPS.
crowdsec_whitelist_remove() {
  load_env
  if [[ -z "${CROWDSEC_WHITELIST_IPS:-}" ]]; then warn "Keine expliziten Zusatz-IPs vorhanden."; return 0; fi
  echo "Aktuell: ${CROWDSEC_WHITELIST_IPS}"
  local e; e="$(ask "Welchen Eintrag entfernen? (exakt wie oben)")"
  [[ -z "$e" ]] && { warn "Nichts eingegeben."; return 0; }
  local -a keep=() x; local found=0
  for x in ${CROWDSEC_WHITELIST_IPS//,/ }; do
    if [[ "$x" == "$e" ]]; then found=1; continue; fi
    keep+=("$x")
  done
  if (( ! found )); then err "Nicht gefunden: ${e}"; return 1; fi
  CROWDSEC_WHITELIST_IPS="$(IFS=,; echo "${keep[*]:-}")"
  save_env
  crowdsec_installed && { crowdsec_write_whitelist; _crowdsec_reload; } || info "Gespeichert."
  ok "Entfernt: ${e}"
}

# Aktuelle oeffentliche SSH-Quell-IP NUR nach ausdruecklicher Bestaetigung
# dauerhaft whitelisten (nie automatisch - oeffentliche IPs sind oft dynamisch).
crowdsec_whitelist_add_ssh() {
  load_env
  local ip; ip="$(awk '{print $1}' <<<"${SSH_CONNECTION:-}")"
  if [[ -z "$ip" ]]; then warn "Keine SSH-Quell-IP ermittelbar (SSH_CONNECTION leer - lokale Sitzung?)."; return 0; fi
  warn "Aktuelle SSH-Quell-IP: ${ip}"
  warn "Oeffentliche IPs aendern sich oft (DHCP/Mobilfunk). Dauerhaft whitelisten NUR wenn statisch."
  if ! yesno "IP ${ip} DAUERHAFT zur Whitelist hinzufuegen?" "n"; then info "Abgebrochen - nichts geaendert."; return 0; fi
  if ! _crowdsec_valid_wl_entry "$ip"; then err "IP ${ip} ungueltig/nicht erlaubt."; return 1; fi
  local cur=" ${CROWDSEC_WHITELIST_IPS//,/ } "
  if [[ "$cur" == *" $ip "* ]]; then warn "Bereits enthalten: ${ip}"; return 0; fi
  CROWDSEC_WHITELIST_IPS="${CROWDSEC_WHITELIST_IPS:+${CROWDSEC_WHITELIST_IPS},}${ip}"
  save_env
  crowdsec_installed && { crowdsec_write_whitelist; _crowdsec_reload; } || info "Gespeichert."
  ok "SSH-Quell-IP ${ip} dauerhaft whitelistet."
}

crowdsec_whitelist_menu() {
  need_root; set +e
  while true; do
    hmenu_head "Sicherheit > CrowdSec > Whitelist"
    crowdsec_whitelist_show
    line
    menu_item 1 "IP/CIDR hinzufuegen"
    menu_item 2 "IP/CIDR entfernen"
    menu_item 3 "Aktuelle SSH-Quell-IP hinzufuegen (nach Bestaetigung)"
    menu_item 4 "Whitelist-Datei neu schreiben & CrowdSec neu laden"
    menu_back
    read -rp "Auswahl: " c
    case "$c" in
      1) crowdsec_whitelist_add; pause ;;
      2) crowdsec_whitelist_remove; pause ;;
      3) crowdsec_whitelist_add_ssh; pause ;;
      4) if crowdsec_installed; then crowdsec_write_whitelist; _crowdsec_reload; else warn "CrowdSec nicht installiert."; fi; pause ;;
      b|B) return ;; 0) exit 0 ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}

# Richtet das offizielle CrowdSec-APT-Repo OHNE "curl | bash" ein: Keyring in
# /usr/share/keyrings + signed-by sources.list.d-Eintrag. Idempotent (erkennt
# vorhandenes Repo) und beschaedigt bestehende Installationen nicht.
_crowdsec_setup_repo() {
  local list=/etc/apt/sources.list.d/crowdsec_crowdsec.list
  local keyring=/usr/share/keyrings/crowdsec_crowdsec-archive-keyring.gpg
  if [[ -f "$list" ]]; then info "CrowdSec-APT-Repo bereits eingerichtet (${list}) - unveraendert."; return 0; fi
  command -v curl >/dev/null 2>&1 || { err "curl fehlt: sudo apt-get install -y curl"; return 1; }
  command -v gpg  >/dev/null 2>&1 || { err "gpg fehlt: sudo apt-get install -y gnupg"; return 1; }
  # Distribution/Architektur bestimmen.
  local dist="debian" codename="" arch=""
  # shellcheck disable=SC1091
  [[ -r /etc/os-release ]] && . /etc/os-release 2>/dev/null || true
  case "${ID:-debian}" in ubuntu) dist="ubuntu" ;; *) dist="debian" ;; esac
  codename="${VERSION_CODENAME:-}"
  [[ -z "$codename" ]] && codename="$(lsb_release -cs 2>/dev/null || true)"
  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  [[ -z "$codename" ]] && { err "Distributions-Codename nicht ermittelbar (VERSION_CODENAME/lsb_release)."; return 1; }
  info "Repo fuer ${dist}/${codename} (${arch})."
  mkdir -p /usr/share/keyrings /etc/apt/sources.list.d
  local tmpkey; tmpkey="$(mktemp)"
  if ! curl -fsSL "https://packagecloud.io/crowdsec/crowdsec/gpgkey" -o "$tmpkey"; then
    err "GPG-Key konnte nicht geladen werden (packagecloud)."; rm -f "$tmpkey"; return 1
  fi
  if ! gpg --dearmor < "$tmpkey" > "$keyring" 2>/dev/null; then
    err "Keyring konnte nicht erstellt werden."; rm -f "$tmpkey"; return 1
  fi
  rm -f "$tmpkey"; chmod 0644 "$keyring"
  cat > "$list" <<EOF
deb [signed-by=${keyring} arch=${arch}] https://packagecloud.io/crowdsec/crowdsec/${dist}/ ${codename} main
deb-src [signed-by=${keyring}] https://packagecloud.io/crowdsec/crowdsec/${dist}/ ${codename} main
EOF
  chmod 0644 "$list"
  if ! DEBIAN_FRONTEND=noninteractive apt-get update >/dev/null 2>&1; then
    err "apt-get update nach Repo-Setup fehlgeschlagen - Eintrag pruefen: ${list}"; return 1
  fi
  ok "CrowdSec-APT-Repo eingerichtet (Keyring ${keyring})."
  return 0
}

# Interner Helfer: Firewall-Bouncer passend zum Backend installieren/aktivieren.
# Nutzt ausschliesslich CrowdSec-eigene Regeln (kein UFW-Eingriff), IPv4 + IPv6.
_crowdsec_install_bouncer() {
  local backend pkg
  backend="$(crowdsec_detect_bouncer)"
  case "$backend" in
    nftables) pkg="crowdsec-firewall-bouncer-nftables" ;;
    *)        pkg="crowdsec-firewall-bouncer-iptables" ;;
  esac
  info "Firewall-Bouncer-Backend: ${backend} (Paket ${pkg})."
  if systemctl list-unit-files 2>/dev/null | grep -q "^${CROWDSEC_BOUNCER_SVC}"; then
    info "Firewall-Bouncer bereits vorhanden - aktiviere/starte neu."
  else
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then return 1; fi
  fi
  systemctl enable "$CROWDSEC_BOUNCER_SVC" >/dev/null 2>&1 || true
  systemctl restart "$CROWDSEC_BOUNCER_SVC" >/dev/null 2>&1 || true
  ok "Firewall-Bouncer aktiv (IPv4 + IPv6, eigene ${backend}-Regeln - UFW unveraendert)."
  return 0
}

crowdsec_install() {
  need_root; load_env
  section "CrowdSec installieren / aktivieren"
  info "CrowdSec ergaenzt Fail2ban und caddy-auth - beide bleiben unveraendert aktiv."
  info "Es werden KEINE neuen Ports geoeffnet und KEINE UFW-Regeln geaendert."

  # 1) Offizielles APT-Repo einrichten (Keyring + sources.list.d, KEIN curl|bash).
  if ! crowdsec_installed; then
    _crowdsec_setup_repo || return 1
  fi

  # 2) Paket installieren (nur wenn noch nicht vorhanden).
  if ! crowdsec_installed; then
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y crowdsec; then
      err "apt-get install crowdsec fehlgeschlagen."; return 1
    fi
  else
    info "CrowdSec ist bereits installiert - aktualisiere nur Konfiguration/Collections."
  fi
  crowdsec_installed || { err "cscli nach der Installation nicht gefunden."; return 1; }

  # 3) Acquisition fuer das Caddy-Access-Log + Whitelist der eigenen Infrastruktur.
  crowdsec_write_acquis
  crowdsec_write_whitelist

  # 4) Collections (idempotent): Linux-Basis, SSH und Caddy.
  info "Installiere Collections (linux, sshd, caddy) ..."
  cscli collections install crowdsecurity/linux crowdsecurity/sshd crowdsecurity/caddy 2>/dev/null || true

  # 5) Firewall-Bouncer (eigene nft/iptables-Regeln, kein UFW-Eingriff).
  _crowdsec_install_bouncer || warn "Firewall-Bouncer nicht automatisch installiert - Decisions werden erkannt, aber evtl. nicht durchgesetzt."

  # 6) Dienst aktivieren und mit neuer Acquisition/Collections neu starten.
  systemctl enable crowdsec >/dev/null 2>&1 || true
  systemctl restart crowdsec >/dev/null 2>&1 || true

  ENABLE_CROWDSEC=1; save_env
  ok "CrowdSec ist aktiviert (ENABLE_CROWDSEC=1)."
  echo
  info "Lokaler Schutz laeuft jetzt ohne CrowdSec Console."
  info "Optional: Console verbinden ueber 'sudo homeedge crowdsec-console' (Enrollment-Key noetig)."
  info "Hinweis: SSH bleibt bewusst DOPPELT geschuetzt (Fail2ban sshd-Jail + CrowdSec sshd-Collection) - nichts wird automatisch deaktiviert."
  info "Empfehlung: 'sudo homeedge crowdsec-selftest' zur End-to-End-Pruefung."
  crowdsec_status
}

crowdsec_status() {
  load_env
  section "CrowdSec Status"
  if ! crowdsec_installed; then
    warn "CrowdSec ist nicht installiert. Installation: sudo homeedge crowdsec-install"
    return 0
  fi
  local log="${CROWDSEC_CADDY_LOG:-/opt/caddy-edge/logs/access.log}"
  printf '  %-28s %s\n' "ENABLE_CROWDSEC:" "${ENABLE_CROWDSEC:-0}"
  printf '  %-28s %s\n' "CROWDSEC_CONSOLE:" "${CROWDSEC_CONSOLE:-0}"
  systemctl is-active --quiet crowdsec 2>/dev/null && ok "crowdsec Dienst aktiv" || warn "crowdsec Dienst NICHT aktiv"
  if systemctl is-active --quiet "$CROWDSEC_BOUNCER_SVC" 2>/dev/null; then ok "Firewall-Bouncer aktiv (${CROWDSEC_BOUNCER_SVC})"; else warn "Firewall-Bouncer NICHT aktiv"; fi
  [[ -f "$CROWDSEC_ACQUIS_FILE" ]] && ok "Acquisition vorhanden: ${CROWDSEC_ACQUIS_FILE}" || warn "Acquisition fehlt: ${CROWDSEC_ACQUIS_FILE}"
  [[ -f "$log" ]] && ok "Caddy-Log vorhanden: ${log}" || warn "Caddy-Log fehlt: ${log}"
  echo; info "Registrierte Bouncer:"; cscli bouncers list 2>/dev/null || true
  echo; info "Console-Status:"; cscli console status 2>/dev/null || true
}

# Prueft, ob eine IP in der Dataplane (nftables-Ruleset oder ipset) auftaucht.
_crowdsec_ip_in_dataplane() {
  local ip="$1"
  if command -v nft >/dev/null 2>&1 && nft list ruleset 2>/dev/null | grep -qF "$ip"; then return 0; fi
  if command -v ipset >/dev/null 2>&1 && ipset list 2>/dev/null | grep -qF "$ip"; then return 0; fi
  return 1
}

# End-to-End-Selbsttest. Exitcode: 0 = alles OK, 1 = Warnungen, 2 = kritisch.
# Nutzt die reservierte Doku-IP 203.0.113.10 (RFC 5737 TEST-NET-3) und loescht
# die Test-Decision IMMER wieder. Aendert UFW nicht.
crowdsec_selftest() {
  need_root; load_env
  section "CrowdSec Selbsttest"
  crowdsec_installed || { err "CrowdSec ist nicht installiert. Zuerst: sudo homeedge crowdsec-install"; return 2; }
  local rc=0 testip="203.0.113.10"
  local log="${CROWDSEC_CADDY_LOG:-/opt/caddy-edge/logs/access.log}"
  local ufw_before ufw_after
  ufw_before="$(ufw status 2>/dev/null | grep -c . || true)"

  # 1) crowdsec-Dienst aktiv
  if systemctl is-active --quiet crowdsec 2>/dev/null; then ok "crowdsec Dienst aktiv"; else err "crowdsec Dienst NICHT aktiv"; rc=2; fi
  # 2) LAPI erreichbar
  if cscli lapi status >/dev/null 2>&1; then ok "LAPI erreichbar"; else err "LAPI NICHT erreichbar (cscli lapi status)"; rc=2; fi
  # 3) Bouncer registriert + Dienst aktiv
  if cscli bouncers list -o raw 2>/dev/null | grep -q .; then ok "Bouncer registriert (cscli bouncers list)"; else warn "Kein Bouncer registriert"; rc=$(( rc<1?1:rc )); fi
  if systemctl is-active --quiet "$CROWDSEC_BOUNCER_SVC" 2>/dev/null; then ok "Firewall-Bouncer Dienst aktiv"; else warn "Firewall-Bouncer NICHT aktiv (Durchsetzung evtl. inaktiv)"; rc=$(( rc<1?1:rc )); fi
  # 4) Acquisition vorhanden
  if [[ -f "$CROWDSEC_ACQUIS_FILE" ]]; then ok "Caddy-Acquisition vorhanden"; else err "Acquisition fehlt: ${CROWDSEC_ACQUIS_FILE}"; rc=2; fi
  # 5) Caddy-Log wird gelesen/geparst (Acquisition-Metriken zeigen die Logdatei)
  if cscli metrics 2>/dev/null | grep -qF "$log"; then ok "Caddy-Log wird gelesen (in Acquisition-Metriken sichtbar)"; else warn "Caddy-Log noch nicht in Metriken (evtl. keine Zeilen gelesen/geparst)"; rc=$(( rc<1?1:rc )); fi
  # 6) Collections linux/sshd/caddy installiert
  local col; for col in crowdsecurity/linux crowdsecurity/sshd crowdsecurity/caddy; do
    if cscli collections list 2>/dev/null | grep -q "$col"; then ok "Collection ${col}"; else warn "Collection ${col} fehlt"; rc=$(( rc<1?1:rc )); fi
  done

  # 7) Test-Decision mit reservierter IP hinzufuegen
  local added=0
  if cscli decisions add --ip "$testip" --duration 2m --type ban --reason "homeedge-selftest" >/dev/null 2>&1; then
    added=1; ok "Test-Decision gesetzt (${testip}, 2m, ban)"
  else
    warn "Test-Decision konnte nicht gesetzt werden (cscli decisions add)"; rc=$(( rc<1?1:rc ))
  fi
  if (( added )); then
    if cscli decisions list -o raw 2>/dev/null | grep -qF "$testip"; then ok "Test-Decision in LAPI aktiv"; else warn "Test-Decision nicht in 'decisions list'"; rc=$(( rc<1?1:rc )); fi
    # 8) Uebernahme in nftables/ipset (Bouncer-Pull-Intervall abwarten)
    sleep 3
    if _crowdsec_ip_in_dataplane "$testip"; then ok "Test-Decision in nftables/ipset uebernommen"; else warn "Test-Decision (noch) nicht in nftables/ipset - Bouncer-Pull-Intervall abwarten und erneut pruefen"; rc=$(( rc<1?1:rc )); fi
    # 9) Test-Decision sicher wieder loeschen (IMMER)
    if cscli decisions delete --ip "$testip" >/dev/null 2>&1; then ok "Test-Decision wieder geloescht"; else err "Test-Decision konnte NICHT geloescht werden - manuell: sudo cscli decisions delete --ip ${testip}"; rc=2; fi
  fi

  # 10) UFW unveraendert + aktiv
  ufw_after="$(ufw status 2>/dev/null | grep -c . || true)"
  if ufw status 2>/dev/null | grep -qiE '^Status: (active|aktiv)'; then ok "UFW weiterhin aktiv"; else warn "UFW ist nicht aktiv"; rc=$(( rc<1?1:rc )); fi
  if [[ "$ufw_before" == "$ufw_after" ]]; then ok "UFW unveraendert (Statuszeilen: ${ufw_after})"; else warn "UFW-Statuszeilen geaendert (${ufw_before} -> ${ufw_after}) - bitte pruefen"; rc=$(( rc<1?1:rc )); fi

  echo
  case "$rc" in
    0) ok  "Selbsttest bestanden - alle Checks OK." ;;
    1) warn "Selbsttest mit Warnungen abgeschlossen (Details oben)." ;;
    *) err "Selbsttest FEHLGESCHLAGEN - kritische Punkte (Details oben)." ;;
  esac
  return "$rc"
}

crowdsec_alerts()          { load_env; crowdsec_installed || { warn "CrowdSec nicht installiert."; return 0; }; section "CrowdSec Alerts";      cscli alerts list 2>/dev/null || true; }
crowdsec_decisions()       { load_env; crowdsec_installed || { warn "CrowdSec nicht installiert."; return 0; }; section "CrowdSec Decisions";   cscli decisions list 2>/dev/null || true; }
crowdsec_metrics()         { load_env; crowdsec_installed || { warn "CrowdSec nicht installiert."; return 0; }; section "CrowdSec Metrics";     cscli metrics 2>/dev/null || true; }
crowdsec_collections()     { load_env; crowdsec_installed || { warn "CrowdSec nicht installiert."; return 0; }; section "CrowdSec Collections"; cscli collections list 2>/dev/null || true; }
crowdsec_console_status()  { load_env; crowdsec_installed || { warn "CrowdSec nicht installiert."; return 0; }; section "CrowdSec Console Status"; cscli console status 2>/dev/null || true; }

# IP entbannen: loescht die aktive Decision fuer die IP.
crowdsec_unban() {
  need_root; load_env
  crowdsec_installed || { err "CrowdSec ist nicht installiert."; return 1; }
  local ip="${1:-}"
  [[ -z "$ip" ]] && ip="$(ask "IP zum Entbannen")"
  if ! [[ "$ip" =~ ^[0-9A-Fa-f:.]+(/[0-9]+)?$ ]]; then err "Ungueltige IP: ${ip}"; return 1; fi
  section "CrowdSec Decision loeschen: ${ip}"
  if cscli decisions delete --ip "$ip"; then ok "Decision(s) fuer ${ip} geloescht."; else err "Loeschen fehlgeschlagen (evtl. keine aktive Decision fuer ${ip})."; return 1; fi
}

# Hub/Collections aktualisieren (kein Dienst-Bruch: reload bevorzugt).
crowdsec_update() {
  need_root; load_env
  crowdsec_installed || { err "CrowdSec ist nicht installiert."; return 1; }
  section "CrowdSec Hub / Collections aktualisieren"
  cscli hub update || true
  cscli hub upgrade || true
  systemctl reload crowdsec 2>/dev/null || systemctl restart crowdsec 2>/dev/null || true
  ok "CrowdSec Hub/Collections aktualisiert."
}

# Console optional verbinden. Wird NIE automatisch aufgerufen; Key wird abgefragt.
crowdsec_console_enroll() {
  need_root; load_env
  crowdsec_installed || { err "CrowdSec ist nicht installiert. Zuerst: sudo homeedge crowdsec-install"; return 1; }
  section "CrowdSec Console verbinden"
  info "Die Console ist optional - der lokale Schutz funktioniert auch ohne."
  local key="${1:-}"
  [[ -z "$key" ]] && key="$(ask "CrowdSec Console Enrollment-Key")"
  [[ -z "$key" ]] && { err "Kein Enrollment-Key angegeben - abgebrochen."; return 1; }
  if cscli console enroll "$key" --name homeedge-vps --tags homeedge --tags jellyfin --tags vps; then
    CROWDSEC_CONSOLE=1; save_env
    systemctl reload crowdsec 2>/dev/null || systemctl restart crowdsec 2>/dev/null || true
    ok "Enrollment gesendet."
    warn "Bitte die Instanz jetzt in der CrowdSec Console bestaetigen (Approve)."
  else
    err "Console-Enrollment fehlgeschlagen - Key pruefen."
    return 1
  fi
}

# Rollback: CrowdSec + Bouncer stoppen/deaktivieren, ENABLE_CROWDSEC=0. Ruehrt
# Fail2ban, Caddy, UFW und WireGuard NICHT an und deinstalliert NICHTS (kein apt purge).
crowdsec_disable() {
  need_root; load_env
  section "CrowdSec deaktivieren"
  warn "Deaktiviert CrowdSec + Firewall-Bouncer. Fail2ban, caddy-auth, Caddy, UFW und WireGuard bleiben UNVERAENDERT."
  info "Es wird KEIN 'apt purge' ausgefuehrt - die Pakete bleiben installiert."
  systemctl stop "$CROWDSEC_BOUNCER_SVC" 2>/dev/null || true
  systemctl disable "$CROWDSEC_BOUNCER_SVC" 2>/dev/null || true
  systemctl stop crowdsec 2>/dev/null || true
  systemctl disable crowdsec 2>/dev/null || true
  ENABLE_CROWDSEC=0; save_env
  ok "CrowdSec deaktiviert (ENABLE_CROWDSEC=0). Dienste gestoppt/disabled, nichts deinstalliert."
  info "Wieder aktivieren: sudo homeedge crowdsec-install"
}

sm_crowdsec() {
  need_root; set +e
  while true; do
    hmenu_head "Sicherheit > CrowdSec"
    load_env
    if crowdsec_installed; then
      echo "   Status: installiert   ENABLE_CROWDSEC=${ENABLE_CROWDSEC:-0}   Console=${CROWDSEC_CONSOLE:-0}"
    else
      echo "   Status: NICHT installiert"
    fi
    info "Ergaenzt Fail2ban + caddy-auth (ersetzt sie nicht). Keine neuen Ports, kein UFW-Eingriff."
    line
    menu_item 1 "CrowdSec installieren / aktivieren"
    menu_item 2 "Status anzeigen"
    menu_item 3 "Selbsttest ausfuehren"
    menu_item 4 "Whitelist (eigene IPs) verwalten"
    menu_item 5 "Alerts anzeigen"
    menu_item 6 "Decisions anzeigen"
    menu_item 7 "Metrics anzeigen"
    menu_item 8 "Collections anzeigen"
    menu_item 9 "IP entbannen (Decision loeschen)"
    menu_item 10 "Collections / Hub aktualisieren"
    menu_item 11 "CrowdSec Console verbinden"
    menu_item 12 "CrowdSec Console Status"
    menu_item 13 "CrowdSec deaktivieren"
    menu_back
    read -rp "Auswahl: " c
    case "$c" in
      1) crowdsec_install; pause ;;
      2) crowdsec_status; pause ;;
      3) crowdsec_selftest; pause ;;
      4) crowdsec_whitelist_menu ;;
      5) crowdsec_alerts; pause ;;
      6) crowdsec_decisions; pause ;;
      7) crowdsec_metrics; pause ;;
      8) crowdsec_collections; pause ;;
      9) crowdsec_unban; pause ;;
      10) crowdsec_update; pause ;;
      11) crowdsec_console_enroll; pause ;;
      12) crowdsec_console_status; pause ;;
      13) crowdsec_disable; pause ;;
      b|B) return ;; 0) exit 0 ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}


# ------------------------------------------------------------
# IPv6-Helfer (nur externer Zugriff Client -> VPS/Caddy)
# ------------------------------------------------------------
# Erste globale IPv6-Adresse des VPS (leer wenn keine). errexit-sicher.
vps_ipv6() {
  command -v ip >/dev/null 2>&1 || return 0
  ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2; exit}' | cut -d/ -f1 2>/dev/null || true
}
vps_has_global_ipv6() { [[ -n "$(vps_ipv6)" ]]; }
ufw_ipv6_enabled() { [[ -f /etc/default/ufw ]] && grep -qiE '^IPV6=yes' /etc/default/ufw; }
# Lauscht Caddy lokal auf IPv6 :443 (TCP oder UDP/HTTP3)?
# Robust: ss-Portfilter + -6, TCP und UDP getrennt abgefragt. Meldet nur OK, wenn
# eine Zeile ZUGLEICH einen v6-/Wildcard-Listener auf :443 UND den Prozess caddy
# zeigt. Unterstuetzte Adressformen: *:443, [::]:443/[<v6>]:443 und :::443
# (frueher wurde *:443 faelschlich nicht erkannt, und UDP/HTTP3 gar nicht geprueft).
caddy_listens_ipv6_443() {
  command -v ss >/dev/null 2>&1 || return 1
  { ss -H -6 -ltnp 'sport = :443' 2>/dev/null; ss -H -6 -lunp 'sport = :443' 2>/dev/null; } \
    | grep -E '\*:443|\]:443|:::443' | grep -q 'caddy'
}
# Stellt sicher, dass UFW IPv6 verwaltet (IPV6=yes), damit v6 kontrolliert (default deny) ist.
ensure_ufw_ipv6_yes() {
  [[ -f /etc/default/ufw ]] || return 0
  if grep -qE '^IPV6=' /etc/default/ufw; then
    grep -qiE '^IPV6=yes' /etc/default/ufw || sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  else
    echo 'IPV6=yes' >> /etc/default/ufw
  fi
}

# Setzt die Service-Regeln (kein reset). SSH/WG dual-stack (Lockout-Schutz),
# 443 familienspezifisch: v4 immer, v6 nur bei ENABLE_IPV6=1; 443/udp nur bei HTTP/3.
_ufw_rules_apply() {
  # rc != 0, sobald ein RELEVANTES "ufw allow" fehlschlaegt. Fehler werden NICHT
  # mehr verschluckt (frueher: alle Kommandos mit "|| true"), damit der Aufrufer
  # bei einer nicht angelegten 443-Regel wirklich einen Fehler sieht.
  local rc=0
  local cur; cur="$(awk '{print $4}' <<< "${SSH_CONNECTION:-}")"
  ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || rc=1
  if [[ -n "$cur" && "$cur" != "${SSH_PORT}" ]]; then ufw allow "${cur}/tcp" >/dev/null 2>&1 || rc=1; fi
  ufw allow "${WG_PORT}/udp" >/dev/null 2>&1 || rc=1
  # Alte 443-Regeln IMMER sauber entfernen - dual-stack (443/tcp, 443/udp) UND
  # familienspezifisch (0.0.0.0/0 bzw. ::/0). Deletes sind best-effort (die Regel
  # existiert evtl. nicht) und duerfen kein rc setzen.
  ufw delete allow "443/tcp"                       >/dev/null 2>&1 || true
  ufw delete allow "443/udp"                       >/dev/null 2>&1 || true
  ufw delete allow proto tcp to 0.0.0.0/0 port 443 >/dev/null 2>&1 || true
  ufw delete allow proto tcp to ::/0 port 443      >/dev/null 2>&1 || true
  ufw delete allow proto udp to 0.0.0.0/0 port 443 >/dev/null 2>&1 || true
  ufw delete allow proto udp to ::/0 port 443      >/dev/null 2>&1 || true
  if [[ "${ENABLE_IPV6:-0}" == "1" ]]; then
    # Mit IPV6=yes erzeugt die EINFACHE Form "ufw allow 443/tcp" v4 UND v6.
    ufw allow 443/tcp >/dev/null 2>&1 || rc=1
    if [[ "${ENABLE_HTTP3:-0}" == "1" ]]; then ufw allow 443/udp >/dev/null 2>&1 || rc=1; fi
  else
    # Nur IPv4: 0.0.0.0/0-spezifisch - erzeugt KEINE v6-Regel (v6 bleibt zu).
    ufw allow proto tcp to 0.0.0.0/0 port 443 >/dev/null 2>&1 || rc=1
    if [[ "${ENABLE_HTTP3:-0}" == "1" ]]; then ufw allow proto udp to 0.0.0.0/0 port 443 >/dev/null 2>&1 || rc=1; fi
  fi
  return "$rc"
}

# Statusausgabe der UFW-Service-Lage. Liest die ECHTE "ufw status" (nicht nur die
# ENV-Flags), damit ein evtl. nicht entfernter v6-443-Eintrag nicht faelschlich
# als "geschlossen" gemeldet wird (UFW-Regel-Match beim delete kann abweichen).
_ufw_status_report() {
  local st v6tcp=0 v6udp=0 wgv6=0
  st="$(ufw status 2>/dev/null || true)"
  # WICHTIG: protokoll-genau matchen. Frueher matchte '443.*\(v6\)' AUCH die
  # Zeile "443/udp (v6)" und meldete dann faelschlich 443/tcp (v6) als offen.
  grep -qE '443/tcp \(v6\)' <<<"$st" && v6tcp=1
  grep -qE '443/udp \(v6\)' <<<"$st" && v6udp=1
  grep -qiE "${WG_PORT}/udp.*\(v6\)" <<<"$st" && wgv6=1
  # Klarstellung: ENABLE_IPV6 betrifft NUR externen HTTPS-Zugriff (443/tcp v6).
  info "ENABLE_IPV6 steuert nur externen HTTPS-Zugriff (443/tcp v6), nicht WireGuard."
  ok "443/tcp erlaubt (IPv4)"
  if [[ "${ENABLE_IPV6:-0}" == "1" ]]; then
    if (( v6tcp )); then ok "HTTPS extern IPv6: 443/tcp (v6) erlaubt"; else warn "443/tcp (v6) SOLL offen sein (ENABLE_IPV6=1), ist aber laut 'ufw status' nicht gelistet."; fi
  else
    if (( v6tcp )); then warn "443 (v6) ist laut 'ufw status' noch offen, obwohl ENABLE_IPV6=0 - bitte pruefen: sudo ufw status"; else ok "HTTPS extern IPv6: aus (443/tcp v6 geschlossen, ENABLE_IPV6=0)"; fi
  fi
  ok "WireGuard ${WG_PORT}/udp erlaubt (IPv4)"
  # WireGuard ist von ENABLE_IPV6 unabhaengig: bei IPV6=yes legt UFW i. d. R. auch
  # eine v6-Regel fuer den WG-Port an. Das transparent ausweisen.
  if (( wgv6 )); then
    info "WireGuard ${WG_PORT}/udp ist auch via IPv6 (v6) freigegeben - unabhaengig von ENABLE_IPV6 (Systemeinstellung IPV6=yes)."
  fi
  if [[ "${ENABLE_HTTP3:-0}" == "1" ]]; then
    if [[ "${ENABLE_IPV6:-0}" == "1" ]]; then ok "HTTP/3 aktiv, 443/udp und 443/udp (v6) erlaubt"; else ok "HTTP/3 aktiv, 443/udp erlaubt"; fi
  else
    ok "HTTP/3 aus, 443/udp geschlossen"
    (( v6udp )) && warn "443/udp (v6) ist laut 'ufw status' noch offen, obwohl HTTP/3 aus - bitte pruefen: sudo ufw status"
  fi
}

# Verifiziert die TATSAECHLICHE 443-Lage in "ufw status" gegen die erwartete
# Konfig (ENABLE_IPV6 / ENABLE_HTTP3). 0 = alles wie erwartet, 1 = Abweichung
# (mit err-Meldung je Punkt). $1 = optionaler vorab erfasster "ufw status"-Text
# (fuer Tests); sonst wird er selbst gelesen.
#   - 443/tcp IPv4:  immer erwartet
#   - 443/tcp (v6):  genau bei ENABLE_IPV6=1
#   - 443/udp IPv4:  genau bei ENABLE_HTTP3=1
#   - 443/udp (v6):  genau bei ENABLE_HTTP3=1 UND ENABLE_IPV6=1
_ufw_verify_443() {
  local st="${1:-}"
  [[ -z "$st" ]] && st="$(ufw status 2>/dev/null || true)"
  local tcp_v4=0 tcp_v6=0 udp_v4=0 udp_v6=0
  grep -E '(^|[[:space:]])443/tcp([[:space:]]|$)' <<<"$st" | grep -qv '(v6)' && tcp_v4=1
  grep -qE '443/tcp \(v6\)' <<<"$st" && tcp_v6=1
  grep -E '(^|[[:space:]])443/udp([[:space:]]|$)' <<<"$st" | grep -qv '(v6)' && udp_v4=1
  grep -qE '443/udp \(v6\)' <<<"$st" && udp_v6=1
  local want_tcp_v6=0 want_udp_v4=0 want_udp_v6=0
  [[ "${ENABLE_IPV6:-0}" == "1" ]] && want_tcp_v6=1
  [[ "${ENABLE_HTTP3:-0}" == "1" ]] && want_udp_v4=1
  [[ "${ENABLE_HTTP3:-0}" == "1" && "${ENABLE_IPV6:-0}" == "1" ]] && want_udp_v6=1
  local rc=0
  (( tcp_v4 == 1 ))            || { err "443/tcp (IPv4) fehlt in 'ufw status'."; rc=1; }
  (( tcp_v6 == want_tcp_v6 ))  || { err "443/tcp (v6): erwartet=${want_tcp_v6}, gefunden=${tcp_v6} (ENABLE_IPV6=${ENABLE_IPV6:-0})."; rc=1; }
  (( udp_v4 == want_udp_v4 ))  || { err "443/udp (IPv4): erwartet=${want_udp_v4}, gefunden=${udp_v4} (ENABLE_HTTP3=${ENABLE_HTTP3:-0})."; rc=1; }
  (( udp_v6 == want_udp_v6 ))  || { err "443/udp (v6): erwartet=${want_udp_v6}, gefunden=${udp_v6}."; rc=1; }
  return "$rc"
}

apply_firewall() {
  load_env
  section "Firewall neu anwenden"
  local cur_ssh_port; cur_ssh_port="$(awk '{print $4}' <<< "${SSH_CONNECTION:-}")"
  echo "UFW wird gesetzt: SSH ${SSH_PORT}/tcp, HTTPS 443/tcp, WireGuard ${WG_PORT}/udp"
  echo "IPv6 extern: $([[ "${ENABLE_IPV6:-0}" == "1" ]] && echo "an (443/tcp v6)" || echo "aus")  HTTP/3: $([[ "${ENABLE_HTTP3:-0}" == "1" ]] && echo an || echo aus)"
  if [[ -n "$cur_ssh_port" && "$cur_ssh_port" != "${SSH_PORT}" ]]; then
    info "Aktive SSH-Sitzung laeuft auf Port ${cur_ssh_port}/tcp - dieser bleibt zusaetzlich offen (Schutz vor Aussperren)."
  fi
  warn "Achtung: falscher SSH-Port kann dich aussperren."
  read -rp "Firewall anwenden? [n]: " a; [[ "$a" =~ ^([YyJj]|yes|ja)$ ]] || return
  maybe_backup_before_change
  ensure_ufw_ipv6_yes
  ufw --force reset; ufw default deny incoming; ufw default allow outgoing
  if ! _ufw_rules_apply; then
    err "UFW-Regeln konnten nicht vollstaendig gesetzt werden - Firewall wird NICHT aktiviert."
    return 1
  fi
  # Lockout-Schutz: NUR aktivieren, wenn der SSH-Port (und der aktive Sitzungsport)
  # nach _ufw_rules_apply wirklich als ALLOW-Regel vorhanden ist. Sonst wuerde
  # "ufw --force enable" bei default-deny die laufende SSH-Sitzung aussperren.
  # WICHTIG: "ufw show added" (NICHT "ufw status") - nach dem "ufw --force reset"
  # ist UFW inaktiv, und "ufw status" listet dann KEINE Regeln (nur "Status:
  # inactive"). Nur "ufw show added" zeigt die gerade gestagten allow-Regeln.
  local ufw_rules; ufw_rules="$(ufw show added 2>/dev/null || true)"
  if ! grep -qE "(^|[[:space:]])${SSH_PORT}/tcp([[:space:]]|$)" <<<"$ufw_rules"; then
    err "SSH-Port ${SSH_PORT}/tcp ist NICHT als UFW-Regel vorhanden - Firewall wird NICHT aktiviert (Aussperr-Schutz)."
    err "Bitte SSH_PORT pruefen (sudo homeedge settings) und erneut versuchen."
    return 1
  fi
  if [[ -n "$cur_ssh_port" && "$cur_ssh_port" != "${SSH_PORT}" ]] \
     && ! grep -qE "(^|[[:space:]])${cur_ssh_port}/tcp([[:space:]]|$)" <<<"$ufw_rules"; then
    err "Aktiver SSH-Sitzungsport ${cur_ssh_port}/tcp ist NICHT freigegeben - Firewall wird NICHT aktiviert (Aussperr-Schutz)."
    return 1
  fi
  ufw --force enable
  echo
  _ufw_status_report
}

# Nicht-interaktive, additive UFW-Angleichung an die Konfig (kein reset -> kein Lockout).
ufw_apply_auto() {
  load_env
  command -v ufw >/dev/null 2>&1 || return 0
  ensure_ufw_ipv6_yes
  if ! _ufw_rules_apply; then
    err "UFW-Regeln konnten nicht vollstaendig gesetzt werden (mind. ein 'ufw allow' schlug fehl)."
    return 1
  fi
  # Verifikation braucht AKTIVE UFW - "ufw status" listet bei inaktiver Firewall
  # keine Regeln. Ist UFW inaktiv, sind die Regeln gestaged (user.rules), aber
  # nicht ueberpruefbar -> ehrliche Warnung statt falschem "OK".
  if ! ufw status 2>/dev/null | grep -qiE '^Status: (active|aktiv)'; then
    warn "UFW ist INAKTIV - 443-Regeln wurden gestaged, aber nicht verifiziert. Aktivieren: sudo homeedge firewall"
    return 0
  fi
  if ! ufw reload >/dev/null 2>&1; then err "ufw reload fehlgeschlagen."; return 1; fi
  if ! _ufw_verify_443; then
    err "UFW 443-Regeln stimmen nach reload NICHT mit der Konfig ueberein (IPv6=${ENABLE_IPV6:-0}, HTTP/3=${ENABLE_HTTP3:-0})."
    return 1
  fi
  ok "UFW angeglichen und verifiziert (IPv6=${ENABLE_IPV6:-0}, HTTP/3=${ENABLE_HTTP3:-0})."
  return 0
}

# Stellt sicher, dass UFW AKTIV ist (mit SSH-Lockout-Schutz): erst SSH/443/WG
# erlauben (_ufw_rules_apply), dann aktivieren. 0 = aktiv, 1 = konnte nicht
# sicher aktiviert werden. Fuer apply-all/Wizard (Bug P1: UFW nicht faelschlich
# als OK melden, wenn sie inaktiv bleibt).
ufw_ensure_active() {
  load_env
  if ! command -v ufw >/dev/null 2>&1; then err "ufw ist nicht installiert - Firewall kann nicht aktiviert werden."; return 1; fi
  ensure_ufw_ipv6_yes
  # SSH-Port (und aktiven SSH-Sitzungsport) VOR enable erlauben -> kein Lockout.
  _ufw_rules_apply
  # Lockout-Schutz: vor dem Aktivieren sicherstellen, dass die SSH-Regel da ist.
  local cur_ssh_port; cur_ssh_port="$(awk '{print $4}' <<< "${SSH_CONNECTION:-}")"
  # Aktiv-Status aus "ufw status"; die gestagten Regeln aus "ufw show added" -
  # "ufw status" listet bei INAKTIVER UFW KEINE Regeln (nur "Status: inactive"),
  # daher wuerde der SSH-Check sonst immer fehlschlagen und UFW nie aktiviert.
  local ufw_rules ufw_added
  ufw_rules="$(ufw status 2>/dev/null || true)"
  ufw_added="$(ufw show added 2>/dev/null || true)"
  if ! grep -qiE "Status: (active|aktiv)" <<<"$ufw_rules"; then
    if ! grep -qE "(^|[[:space:]])${SSH_PORT:-22}/tcp([[:space:]]|$)" <<<"$ufw_added"; then
      err "SSH-Port ${SSH_PORT:-22}/tcp ist nicht freigegeben - UFW wird NICHT aktiviert (Aussperr-Schutz)."
      return 1
    fi
    if [[ -n "$cur_ssh_port" && "$cur_ssh_port" != "${SSH_PORT:-22}" ]] \
       && ! grep -qE "(^|[[:space:]])${cur_ssh_port}/tcp([[:space:]]|$)" <<<"$ufw_added"; then
      err "Aktiver SSH-Sitzungsport ${cur_ssh_port}/tcp ist nicht freigegeben - UFW wird NICHT aktiviert (Aussperr-Schutz)."
      return 1
    fi
  fi
  if grep -qiE "Status: (active|aktiv)" <<<"$ufw_rules"; then
    ufw reload >/dev/null 2>&1 || true
  else
    ufw --force enable >/dev/null 2>&1 || true
  fi
  if ufw status 2>/dev/null | grep -qiE "Status: (active|aktiv)"; then
    return 0
  fi
  err "UFW konnte nicht aktiviert werden."
  return 1
}

show_values() {
  load_env
  section "Aktuelle Werte"
  printf '%-28s %s\n' "VPS Public Host/IP:" "${VPS_PUBLIC_HOST}"
  printf '%-28s %s\n' "Externes Interface:" "${EXT_IF}"
  printf '%-28s %s\n' "SSH Port:" "${SSH_PORT}"
  printf '%-28s %s\n' "WireGuard Interface:" "${WG_IF}"
  printf '%-28s %s/udp\n' "WireGuard Port:" "${WG_PORT}"
  printf '%-28s %s\n' "VPS WG Adresse:" "${VPS_WG_ADDR}"
  printf '%-28s %s\n' "Client/UniFi WG Adresse:" "${CLIENT_WG_ADDR}"
  printf '%-28s %s\n' "Backend-Netze:" "${HOME_SUBNET}"
  printf '%-28s %s\n' "UniFi PublicKey:" "$([[ -n "${CLIENT_PUBLIC_KEY:-}" ]] && echo gesetzt || echo fehlt)"
  printf '%-28s %s\n' "PresharedKey:" "$([[ "${USE_PSK}" == "1" ]] && echo aktiv || echo aus)"
  printf '%-28s %s\n' "ACME E-Mail:" "${ACME_EMAIL}"
  printf '%-28s %s\n' "Cloudflare Token:" "$([[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] && echo gesetzt || echo nicht gesetzt)"
  printf '%-28s %s\n' "Caddy Fail2ban:" "$([[ "${CADDY_FAIL2BAN}" == "1" ]] && echo aktiv || echo inaktiv)"
  printf '%-28s %s\n' "Caddy HTTP/3 UDP443:" "$([[ "${ENABLE_HTTP3:-0}" == "1" ]] && echo aktiv || echo deaktiviert)"
  echo
  printf '%b\n' "${C_BOLD}Externe Dienste:${C_RESET}"
  list_services
}

list_services() {
  if [[ ! -f "$SERVICES_FILE" || ! -s "$SERVICES_FILE" ]]; then warn "Keine Dienste vorhanden."; return; fi
  require_valid_services || return 1
  nl -w2 -s'. ' "$SERVICES_FILE" | sed $'s/\t/ | /g'
}

# Fragt das Backend-Profil ab (Anzeige nach stderr, Rueckgabe nach stdout).
ask_profile() {
  local default="${1:-standard}" def c
  case "$default" in jellyfin) def=2 ;; jellyseerr) def=3 ;; *) def=1 ;; esac
  { echo "Backend-Profil:"; echo "  1) Standard"; echo "  2) Jellyfin (flush_interval -1 fuer Streaming)"; echo "  3) Jellyseerr"; } >&2
  c="$(ask "Profil" "$def")"
  case "$c" in 2|jellyfin) printf 'jellyfin' ;; 3|jellyseerr) printf 'jellyseerr' ;; *) printf 'standard' ;; esac
}

# ------------------------------------------------------------
# services.tsv Integritaet (Append/Validierung/Repair)
# ------------------------------------------------------------
# Profil-Vorschlag anhand Port.
profile_suggest() { case "$1" in 8096) echo jellyfin ;; 5055) echo jellyseerr ;; *) echo standard ;; esac; }

# ------------------------------------------------------------
# Strikte Feld-Validierung (Bug P1: Domain/Backend/Port/Scheme/Profil)
# Verhindert, dass aus Eingaben eine kaputte/unsichere Caddyfile entsteht.
# ------------------------------------------------------------
# Enthaelt der String ein verbotenes Zeichen?  { } ; " ' ` $ \ Whitespace/Tab
_has_forbidden_chars() {
  case "$1" in
    *'{'*|*'}'*|*';'*|*'"'*|*"'"*|*'`'*|*'$'*|*'\'*|*' '*|*$'\t'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Gueltige Domain: optionaler Wildcard-Prefix (*.) + FQDN mit mindestens einem Punkt.
# Keine Sonderzeichen, kein Slash, kein Doppelpunkt, keine Leerzeichen.
valid_domain() {
  local d="${1:-}" re
  [[ -n "$d" ]] || return 1
  _has_forbidden_chars "$d" && return 1
  case "$d" in */*|*:*) return 1 ;; esac
  re='^(\*\.)?([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
  [[ "$d" =~ $re ]]
}

# Gueltiges Backend: IPv4 oder Hostname (ein/mehrere Labels). IPv6 erstmal NICHT.
# Keine Sonderzeichen, kein Slash, kein Doppelpunkt, keine Leerzeichen.
valid_backend() {
  local b="${1:-}" re o
  [[ -n "$b" ]] || return 1
  _has_forbidden_chars "$b" && return 1
  case "$b" in */*|*:*) return 1 ;; esac
  if [[ "$b" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    for o in ${b//./ }; do (( o >= 0 && o <= 255 )) || return 1; done
    return 0
  fi
  re='^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$'
  [[ "$b" =~ $re ]]
}

valid_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_scheme() { [[ "${1:-}" == "http" || "${1:-}" == "https" ]]; }
valid_profile() { case "${1:-}" in standard|jellyfin|jellyseerr) return 0 ;; *) return 1 ;; esac; }

# Bricht ab, wenn services.tsv ungueltig ist. Fuer lesende Funktionen (Bug P2).
require_valid_services() {
  if ! validate_services_file >/dev/null 2>&1; then
    err "services.tsv ist ungueltig."
    printf '%s\n' "Bitte ausfuehren:"
    printf '%s\n' "sudo homeedge repair-services"
    return 1
  fi
  return 0
}

# Haengt einen Dienst sicher an: stellt erst Trailing-Newline sicher, dann genau
# 5 Felder. Verhindert das Verkleben mit der letzten Zeile.
append_service() {
  local domain="$1" scheme="$2" ip="$3" port="$4" profile="$5"
  touch "$SERVICES_FILE"
  if [[ -s "$SERVICES_FILE" && -n "$(tail -c1 "$SERVICES_FILE")" ]]; then
    printf '\n' >> "$SERVICES_FILE"
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$domain" "$scheme" "$ip" "$port" "$profile" >> "$SERVICES_FILE"
}

# Validiert services.tsv ($1 optional, default SERVICES_FILE). 0 = ok, 1 = defekt.
validate_services_file() {
  local f="${1:-$SERVICES_FILE}"
  [[ -f "$f" && -s "$f" ]] || return 0   # keine/leere Datei = keine Dienste = ok
  local rc=0 ln=0 line nf d s i p pr
  local -A seen=()
  if [[ -n "$(tail -c1 "$f")" ]]; then err "services.tsv endet nicht mit Newline (Zeilen koennen verkleben)."; rc=1; fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    ln=$((ln+1)); [[ -z "$line" ]] && continue
    nf=$(awk -F'\t' '{print NF}' <<<"$line")
    if [[ "$nf" -ne 5 ]]; then err "Zeile ${ln}: ${nf} Felder statt 5 (verklebt?): ${line}"; rc=1; continue; fi
    IFS=$'\t' read -r d s i p pr <<<"$line"
    if ! valid_domain "$d"; then
      err "services.tsv Zeile ${ln}: Domain \"${d}\" ist ungueltig."
      # Haeufigster Fall: unvollstaendige Domain ohne Punkt (z. B. "jf").
      if [[ -n "$d" && "$d" != *.* ]]; then
        info "Bitte vollstaendige Domain (FQDN) verwenden, z. B. ${d}.smatitec.de"
      else
        info "Erlaubt: FQDN oder *.domain.tld, keine Leerzeichen/Sonderzeichen ( { } ; \" ' \` \$ \\ / : )."
      fi
      rc=1
    fi
    if [[ -n "$d" ]]; then
      if [[ -n "${seen[$d]:-}" ]]; then err "Zeile ${ln}: doppelte Domain '${d}' (auch Zeile ${seen[$d]})"; rc=1; else seen[$d]="$ln"; fi
    fi
    valid_scheme "$s" || { err "Zeile ${ln}: scheme '${s}' (erwartet http/https)"; rc=1; }
    valid_backend "$i" || { err "Zeile ${ln}: ungueltige Backend-Adresse '${i}' (erlaubt: IPv4 oder Hostname, keine Sonderzeichen)"; rc=1; }
    valid_port "$p" || { err "Zeile ${ln}: Port '${p}' ungueltig (numerisch, 1-65535)"; rc=1; }
    valid_profile "$pr" || { err "Zeile ${ln}: Profil '${pr}' (erwartet standard/jellyfin/jellyseerr)"; rc=1; }
  done < "$f"
  return $rc
}

# Validiert SERVICES_FILE; bei Fehler Rollback aus $1. 0 = ok.
_services_commit_check() {
  if validate_services_file; then rm -f "$1"; return 0; fi
  err "services.tsv ungueltig - stelle vorherigen Stand wieder her."
  [[ -f "$1" ]] && mv "$1" "$SERVICES_FILE"
  return 1
}

# Transaktionale Uebernahme einer Dienst-Aenderung (Bug P2).
# Voraussetzung: die neue services.tsv ist bereits geschrieben, $1 ist das
# Backup der alten services.tsv.
# Ablauf: 1) neue services.tsv validieren  2) Caddyfile generieren+validieren
#         3) Caddy reload  4) caddy_is_running pruefen.
# Bei jedem Fehler wird der ALTE Stand (services.tsv UND Caddyfile) wiederher-
# gestellt und Caddy mit dem alten Stand neu geladen. Kein kaputter Zwischen-
# stand bleibt zurueck. 0 = uebernommen, 1 = zurueckgerollt.
_service_change_commit() {
  local bak="$1"
  # 1) Neue services.tsv streng validieren.
  if ! validate_services_file; then
    err "Aenderung ungueltig - alter Stand wird wiederhergestellt."
    [[ -f "$bak" ]] && mv "$bak" "$SERVICES_FILE"
    return 1
  fi
  # 2-4) Caddyfile generieren+validieren, reload, Laufzeitpruefung.
  #      reload_caddy -> _caddy_prepare_config generiert in eine temp. Datei,
  #      validiert und rollt das Caddyfile bei Fehler selbst zurueck.
  if reload_caddy; then
    rm -f "$bak"
    return 0
  fi
  # reload_caddy gibt 1 auch bei einem reinen ZERTIFIKATS-/ACME-Fehler zurueck,
  # obwohl die Config gueltig ist und der Container laeuft. In dem Fall ist die
  # Aenderung selbst korrekt - NICHT zurueckrollen, nur warnen (Token/DNS-01).
  if caddy_is_running && [[ -s "${CADDY_DIR}/Caddyfile" ]] && validate_caddyfile; then
    warn "Dienst gespeichert und Config aktiv, aber Zertifikat fuer mind. eine Domain steht aus oder schlaegt fehl."
    warn "Falls es ein echter Fehler ist: Cloudflare Token / DNS-01 pruefen (sudo homeedge caddy-logs ; sudo homeedge set-token)."
    rm -f "$bak"
    return 0
  fi
  # Echter Config-/Apply-Fehler: services.tsv auf alten Stand zuruecksetzen und
  # Caddy mit altem (funktionierendem) Stand neu laden, damit nichts Halbfertiges
  # aktiv bleibt.
  err "Caddy-Reload fehlgeschlagen - alter Stand (services.tsv + Caddyfile) wird wiederhergestellt."
  [[ -f "$bak" ]] && mv "$bak" "$SERVICES_FILE"
  reload_caddy >/dev/null 2>&1 || true
  return 1
}

# Rekonstruiert saubere 5-Feld-Zeilen aus einer defekten Datei (stdout).
# Nutzt scheme (http/https) als Anker. Rueckgabe 2 = unsichere Zuordnung.
repair_build() {
  local f="$1" t
  local -a toks=()
  while IFS= read -r t; do
    [[ -z "$t" ]] && continue
    # verklebtes <port><domain> auftrennen (Ziffern direkt gefolgt von Buchstabe)
    while [[ "$t" =~ ^([0-9]+)([A-Za-z].*)$ ]]; do
      toks+=("${BASH_REMATCH[1]}"); t="${BASH_REMATCH[2]}"
    done
    toks+=("$t")
  done < <(tr '\t' '\n' < "$f")
  local i=0 n=${#toks[@]} d s ip p pr
  local -a out=()
  while (( i < n )); do
    d="${toks[i]:-}"; s="${toks[i+1]:-}"; ip="${toks[i+2]:-}"; p="${toks[i+3]:-}"; pr="${toks[i+4]:-}"
    if [[ ( "$s" == "http" || "$s" == "https" ) && "$p" =~ ^[0-9]+$ ]]; then
      if [[ "$pr" == standard || "$pr" == jellyfin || "$pr" == jellyseerr ]]; then i=$((i+5)); else pr="$(profile_suggest "$p")"; i=$((i+4)); fi
      out+=("${d}"$'\t'"${s}"$'\t'"${ip}"$'\t'"${p}"$'\t'"${pr}")
    else
      return 2
    fi
  done
  (( ${#out[@]} == 0 )) && return 2
  printf '%s\n' "${out[@]}"
}

# Migriert alte 4-Spalten-Eintraege (ohne Profil) auf das aktuelle 5-Spalten-
# Format, indem das Profil anhand des Ports ergaenzt wird. Nur eindeutig saubere
# 4-Spalten-Zeilen werden migriert; alles andere bleibt unveraendert und wird
# der regulaeren Validierung/Reparatur ueberlassen. Idempotent.
# 0 = migriert oder nichts zu tun, 1 = nicht eindeutig migrierbar.
migrate_services_4to5() {
  local f="${1:-$SERVICES_FILE}"
  [[ -f "$f" && -s "$f" ]] || return 0
  validate_services_file "$f" >/dev/null 2>&1 && return 0
  local tmp changed=0 line nf d s i p
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    nf=$(awk -F'\t' '{print NF}' <<<"$line")
    if [[ "$nf" -eq 4 ]]; then
      IFS=$'\t' read -r d s i p <<<"$line"
      if valid_domain "$d" && valid_scheme "$s" && valid_backend "$i" && valid_port "$p"; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$d" "$s" "$i" "$p" "$(profile_suggest "$p")" >> "$tmp"
        changed=1
        continue
      fi
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$f"
  if (( changed )) && validate_services_file "$tmp" >/dev/null 2>&1; then
    cat "$tmp" > "$f"; chmod 600 "$f" 2>/dev/null || true
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# Analysiert/repariert services.tsv (Backup der defekten Datei vorher).
repair_services() {
  need_root; load_env
  local noninteractive=0
  [[ "${1:-}" == "--non-interactive" || "${1:-}" == "--yes" ]] && noninteractive=1
  section "services.tsv reparieren"
  [[ -f "$SERVICES_FILE" ]] || { warn "Keine services.tsv vorhanden."; return 0; }
  if validate_services_file >/dev/null 2>&1; then ok "services.tsv ist bereits gueltig."; return 0; fi
  warn "services.tsv ist defekt. Reparatur wird versucht."
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  # 1) Defekte aktive Datei sichern.
  local bak="${SERVICES_FILE}.broken.${ts}"
  cp -a "$SERVICES_FILE" "$bak"; chmod 600 "$bak" 2>/dev/null || true
  warn "Defekte Datei gesichert: $bak"
  # 2) Reparatur NUR in eine temporaere Datei (aktive Datei bleibt unangetastet).
  local tmp; tmp="$(mktemp)"
  repair_build "$SERVICES_FILE" > "$tmp" 2>/dev/null || true
  # 3) Temp-Datei validieren. 4) Nur bei OK uebernehmen.
  if [[ -s "$tmp" ]] && validate_services_file "$tmp" >/dev/null 2>&1; then
    echo "Vorschlag fuer reparierte services.tsv:"
    nl -w2 -s'. ' "$tmp" | sed $'s/\t/ | /g'
    echo
    if (( noninteractive )) || yesno "Diese reparierte Version uebernehmen?" "y"; then
      # Schluss-Newline sicherstellen und atomar uebernehmen.
      [[ -n "$(tail -c1 "$tmp")" ]] && printf '\n' >> "$tmp"
      cat "$tmp" > "$SERVICES_FILE"; chmod 600 "$SERVICES_FILE" 2>/dev/null || true; rm -f "$tmp"
      ok "services.tsv repariert."
      validate_services_file && ok "Validierung erfolgreich."
    else
      rm -f "$tmp"; warn "Nicht uebernommen. Original (defekt) bleibt, Backup: $bak"; return 1
    fi
  else
    # 5) Reparatur unsicher: aktive Datei NICHT veraendern, Reparaturvorschlag
    #    (falls vorhanden) zur Diagnose sichern.
    if [[ -s "$tmp" ]]; then
      local rf="${SERVICES_FILE}.repair-failed.${ts}"
      cp -a "$tmp" "$rf"; chmod 600 "$rf" 2>/dev/null || true
      warn "Ungueltiger Reparaturvorschlag zur Diagnose gesichert: $rf"
    fi
    rm -f "$tmp"
    err "Automatische Reparatur unsicher - aktive services.tsv bleibt unveraendert, bitte manuell pruefen."
    echo "Datei:  $SERVICES_FILE"
    echo "Backup: $bak"
    # Diagnose-Hinweis: unvollstaendige Domains (ohne Punkt) sind die haeufigste
    # Ursache und koennen NICHT sicher erraten werden.
    local _d _rest
    while IFS=$'\t' read -r _d _rest || [[ -n "$_d" ]]; do
      [[ -z "$_d" ]] && continue
      if [[ "$_d" != *.* && "$_d" != \** ]]; then
        info "Domain \"${_d}\" scheint unvollstaendig zu sein. Bitte FQDN eintragen, z. B. ${_d}.smatitec.de."
      fi
    done < "$SERVICES_FILE"
    return 1
  fi
}

validate_service() {
  local domain="$1" scheme="$2" ip="$3" port="$4" profile="${5:-standard}"
  if ! valid_domain "$domain"; then
    err "Ungueltige Domain: '${domain}'. Erlaubt sind FQDNs wie jft.smatitec.de oder Wildcards wie *.smatitec.de."
    err "Nicht erlaubt: Leerzeichen und Sonderzeichen ( { } ; \" ' \` \$ \\ / : )."
    return 1
  fi
  if ! valid_scheme "$scheme"; then err "Scheme muss 'http' oder 'https' sein."; return 1; fi
  if ! valid_backend "$ip"; then
    err "Ungueltige Backend-Adresse: '${ip}'. Erlaubt sind IPv4 (z.B. 192.168.10.99) oder Hostnamen."
    err "Nicht erlaubt: Sonderzeichen ( { } ; \" ' \` \$ \\ ), Leerzeichen, IPv6 oder Doppelpunkt."
    return 1
  fi
  if ! valid_port "$port"; then err "Ungueltiger Port: '$port' (numerisch, 1-65535)."; return 1; fi
  if ! valid_profile "$profile"; then err "Ungueltiges Profil: '$profile' (erwartet standard/jellyfin/jellyseerr)."; return 1; fi
  return 0
}

add_service() {
  load_env; touch "$SERVICES_FILE"
  section "Neuen externen Dienst hinzufuegen"
  local domain scheme ip port profile
  domain="$(ask "Domain, z.B. jellyfin.example.de")"; scheme="$(ask "Backend Scheme http/https" "http")"; ip="$(ask "Backend IP im Heimnetz")"; port="$(ask "Backend Port")"
  validate_service "$domain" "$scheme" "$ip" "$port" || return 1
  # Doppelte Domain frueh und klar ablehnen (verklebte Datei verhindern).
  if [[ -s "$SERVICES_FILE" ]] && cut -f1 "$SERVICES_FILE" | grep -qxF "$domain"; then
    err "Domain '${domain}' ist bereits vorhanden. Abbruch."
    return 1
  fi
  profile="$(ask_profile standard)"
  maybe_backup_before_change
  local _bak; _bak="$(mktemp)"; cp -a "$SERVICES_FILE" "$_bak" 2>/dev/null || true
  append_service "$domain" "$scheme" "$ip" "$port" "$profile"
  if ! _service_change_commit "$_bak"; then
    err "Dienst NICHT hinzugefuegt - alter Stand ist wiederhergestellt."
    return 1
  fi
  write_unifi_values || true
  ok "Dienst hinzugefuegt."
  warn "UniFi Firewall erlauben: ${VPS_WG_IP} -> ${ip}:${port}/tcp"
}

edit_service() {
  [[ -f "$SERVICES_FILE" && -s "$SERVICES_FILE" ]] || { warn "Keine Dienste vorhanden."; return; }
  validate_services_file >/dev/null 2>&1 || { err "services.tsv ist ungueltig. Bitte zuerst: sudo homeedge repair-services"; return 1; }
  list_services; local num; num="$(ask "Nummer aendern")"
  [[ "$num" =~ ^[0-9]+$ ]] || { err "Ungueltige Nummer."; return 1; }
  # WICHTIG: gleiche Zaehlung wie list_services (nl zaehlt nur nicht-leere Zeilen).
  # Leerzeilen ueberspringen, sonst waere die Auswahl gegenueber der Anzeige
  # verschoben (falscher Dienst). Leerzeilen werden dabei zugleich bereinigt.
  local lines; mapfile -t lines < <(grep -v '^$' "$SERVICES_FILE"); local idx=$((num-1))
  if (( idx < 0 || idx >= ${#lines[@]} )); then err "Ungueltige Nummer."; return; fi
  local old_domain old_scheme old_ip old_port old_profile; IFS=$'\t' read -r old_domain old_scheme old_ip old_port old_profile <<< "${lines[$idx]}"
  local domain scheme ip port profile
  domain="$(ask "Domain" "$old_domain")"; scheme="$(ask "Backend Scheme http/https" "$old_scheme")"; ip="$(ask "Backend IP" "$old_ip")"; port="$(ask "Backend Port" "$old_port")"
  validate_service "$domain" "$scheme" "$ip" "$port" || return 1
  profile="$(ask_profile "${old_profile:-standard}")"
  maybe_backup_before_change
  local _bak; _bak="$(mktemp)"; cp -a "$SERVICES_FILE" "$_bak" 2>/dev/null || true
  lines[$idx]="${domain}"$'\t'"${scheme}"$'\t'"${ip}"$'\t'"${port}"$'\t'"${profile}"; printf "%s\n" "${lines[@]}" > "$SERVICES_FILE"
  if ! _service_change_commit "$_bak"; then
    err "Dienst NICHT geaendert - alter Stand ist wiederhergestellt."
    return 1
  fi
  write_unifi_values || true; ok "Dienst aktualisiert."
}

delete_service() {
  [[ -f "$SERVICES_FILE" && -s "$SERVICES_FILE" ]] || { warn "Keine Dienste vorhanden."; return; }
  validate_services_file >/dev/null 2>&1 || { err "services.tsv ist ungueltig. Bitte zuerst: sudo homeedge repair-services"; return 1; }
  list_services; local num; num="$(ask "Nummer loeschen")"
  [[ "$num" =~ ^[0-9]+$ ]] || { err "Ungueltige Nummer."; return 1; }
  # Gleiche Zaehlung wie list_services (Leerzeilen ueberspringen) - sonst wird der
  # falsche Dienst geloescht, wenn die Datei eine Leerzeile enthaelt.
  local lines; mapfile -t lines < <(grep -v '^$' "$SERVICES_FILE"); local idx=$((num-1))
  if (( idx < 0 || idx >= ${#lines[@]} )); then err "Ungueltige Nummer."; return; fi
  maybe_backup_before_change
  local _bak; _bak="$(mktemp)"; cp -a "$SERVICES_FILE" "$_bak" 2>/dev/null || true
  unset 'lines[$idx]'
  # Letzten Dienst geloescht -> wirklich LEERE Datei schreiben (nicht eine
  # Leerzeile), sonst entsteht genau die Off-by-one-Bedingung fuer die naechste
  # Bearbeitung.
  if (( ${#lines[@]} == 0 )); then : > "$SERVICES_FILE"; else printf "%s\n" "${lines[@]}" > "$SERVICES_FILE"; fi
  if ! _service_change_commit "$_bak"; then
    err "Dienst NICHT geloescht - alter Stand ist wiederhergestellt."
    return 1
  fi
  write_unifi_values || true; ok "Dienst geloescht."
}

edit_settings() {
  load_env
  section "Globale Einstellungen aendern"
  maybe_backup_before_change
  show_network_interfaces
  if yesno "Externes Interface aus Liste auswaehlen?" "y"; then
    select_ext_interface
    load_env
  else
    EXT_IF="$(ask "Externes Interface" "$EXT_IF")"
  fi
  VPS_PUBLIC_HOST="$(ask "VPS Public Host/IP" "$VPS_PUBLIC_HOST")"
  local _sp; _sp="$(ask "SSH Port" "$SSH_PORT")"
  if [[ "$_sp" =~ ^[0-9]+$ ]] && (( _sp >= 1 && _sp <= 65535 )); then SSH_PORT="$_sp"
  else warn "Ungueltiger SSH-Port '${_sp}' - behalte ${SSH_PORT} (UFW/Fail2ban brauchen einen numerischen Port)."; fi
  ACME_EMAIL="$(ask "ACME E-Mail" "$ACME_EMAIL")"
  if yesno "Cloudflare API Token aendern?" "n"; then
    local _nt; _nt="$(sanitize_token "$(ask_secret "Neuer Cloudflare API Token")")"
    if [[ -z "$_nt" ]]; then warn "Leer eingegeben - Token bleibt unveraendert."; else CLOUDFLARE_API_TOKEN="$_nt"; fi
  fi
  if yesno "Caddy/Jellyfin Fail2ban aktivieren?" "$([[ "$CADDY_FAIL2BAN" == "1" ]] && echo y || echo n)"; then CADDY_FAIL2BAN="1"; else CADDY_FAIL2BAN="0"; fi
  save_env; write_unifi_values; reload_caddy; install_fail2ban
  ok "Globale Einstellungen gespeichert. WireGuard aenderst du jetzt separat im WireGuard-Menue."
}

test_backends() {
  [[ -f "$SERVICES_FILE" && -s "$SERVICES_FILE" ]] || { warn "Keine Dienste vorhanden."; return; }
  require_valid_services || return 1
  section "Backend-Test"
  while IFS=$'\t' read -r domain scheme ip port profile || [[ -n "$domain" ]]; do
    [[ -z "${domain:-}" ]] && continue; printf '%b\n' "${C_BOLD}${domain}${C_RESET} -> ${scheme}://${ip}:${port}"
    if [[ "$scheme" == "https" ]]; then curl -k -I --connect-timeout 5 "https://${ip}:${port}" || true; else curl -I --connect-timeout 5 "http://${ip}:${port}" || true; fi; echo
  done < "$SERVICES_FILE"
}

status_all() {
  section "Status"
  show_values || true
  domains_status || true
  section "WireGuard"; wg show 2>/dev/null || true
  ipv6_status || true
  section "Docker"; docker ps 2>/dev/null || true
  section "Caddy Logs"; docker logs --tail 30 caddy-edge 2>/dev/null | mask_secrets || true
  section "Fail2ban"; fail2ban-client status 2>/dev/null || true; fail2ban-client status sshd 2>/dev/null || true; fail2ban-client status caddy-auth 2>/dev/null || true
  section "UFW"; ufw status verbose 2>/dev/null || true
  section "Update-Verhalten"; update_policy_info
}

# Zeigt pro Domain Backend, erwartete VPS-IP, aktuelle DNS-Records und Bewertung (Bug 7).
domains_status() {
  load_env
  section "Domains / DNS-Status"
  if [[ ! -s "$SERVICES_FILE" ]]; then warn "Keine Dienste vorhanden."; return 0; fi
  require_valid_services || return 1
  local expect="${VPS_PUBLIC_HOST:-}" expect6; expect6="$(vps_ipv6)"
  echo "Erwartete VPS-IPv4/Host: ${expect:-unbekannt}"
  echo "Erwartete VPS-IPv6:      ${expect6:-(keine)}   (ENABLE_IPV6=${ENABLE_IPV6:-0})"
  local domain scheme ip port profile a aaaa
  while IFS=$'\t' read -r domain scheme ip port profile || [[ -n "$domain" ]]; do
    [[ -z "$domain" ]] && continue
    a="$(dig +short A "$domain" 2>/dev/null | tail -n1 || true)"
    aaaa="$(dig +short AAAA "$domain" 2>/dev/null | tail -n1 || true)"
    echo
    printf '%bDomain:%b   %s\n' "$C_BOLD" "$C_RESET" "$domain"
    printf '  Backend:  %s://%s:%s\n' "$scheme" "$ip" "$port"
    printf '  A:        %s\n' "${a:-(keiner)}"
    printf '  AAAA:     %s\n' "${aaaa:-(keiner)}"
    # IPv4-Bewertung
    if _is_ip "$expect"; then
      if [[ -z "$a" ]]; then warn "kein A-Record vorhanden"
      elif [[ "$a" == "$expect" ]]; then ok "A zeigt auf VPS IPv4"
      else warn "A zeigt nicht auf diesen VPS (moeglicherweise bewusst noch nicht migriert)"; fi
    else
      info "VPS als DNS-Name konfiguriert - A-Record-Vergleich uebersprungen"
    fi
    # IPv6-Bewertung
    if [[ -z "$aaaa" ]]; then
      info "kein AAAA-Record vorhanden"
    elif [[ "${ENABLE_IPV6:-0}" != "1" ]]; then
      warn "AAAA vorhanden, aber ENABLE_IPV6=0 (IPv6 extern nicht aktiviert)"
    elif [[ -n "$expect6" && "$aaaa" == "$expect6" ]]; then
      ok "AAAA zeigt auf VPS IPv6"
    elif [[ -n "$expect6" ]]; then
      warn "AAAA zeigt nicht auf diesen VPS (erwartet ${expect6})"
    else
      warn "AAAA vorhanden, aber VPS hat keine globale IPv6"
    fi
  done < "$SERVICES_FILE"
}

# Lokaler HTTPS-Test mit korrektem SNI via --resolve (Bug 5).
test_domain() {
  load_env
  local domain="${1:-}"
  [[ -z "$domain" ]] && domain="$(ask "Domain")"
  [[ -z "$domain" ]] && { err "Keine Domain angegeben."; return 1; }
  section "Domain-Test (lokal per SNI): ${domain}"
  echo "Kommando: curl -vk --resolve ${domain}:443:127.0.0.1 https://${domain}/"
  echo
  if ! command -v curl >/dev/null 2>&1; then err "curl nicht installiert."; return 1; fi
  curl -sS -k -I --connect-timeout 10 --max-time 20 --resolve "${domain}:443:127.0.0.1" "https://${domain}/" 2>&1 \
    | sed -n '1,20p' | mask_secrets || true
  echo
  if cert_ready "$domain"; then ok "TLS/Zertifikat lokal erreichbar (SNI ok)."; else warn "Noch kein Zertifikat - evtl. wird es gerade angefordert (1-2 Minuten)."; fi
}

# Prueft einen Cloudflare-Token gegen die Verify-API. 0=ok, 1=ungueltig, 2=kein curl.
verify_cloudflare_token() {
  local tok="$1" out
  command -v curl >/dev/null 2>&1 || return 2
  out="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null)" || return 1
  grep -q '"success":true' <<<"$out" && return 0 || return 1
}

# Prueft, dass der Token in env- und Caddy-.env genau einzeilig und nicht leer ist (Bug 1).
validate_token_files() {
  local rc=0 f val cnt
  for f in "$ENV_FILE" "${CADDY_DIR}/.env"; do
    [[ -f "$f" ]] || continue
    # robust: awk zaehlt zuverlaessig genau eine Zahl (kein mehrzeiliges cnt).
    cnt="$(awk '/^CLOUDFLARE_API_TOKEN=/{c++} END{print c+0}' "$f" 2>/dev/null)"
    cnt="${cnt:-0}"
    val="$(grep -m1 '^CLOUDFLARE_API_TOKEN=' "$f" 2>/dev/null | cut -d= -f2- | tr -d "'\"")"
    if [[ "$cnt" -ne 1 || -z "$val" ]]; then err "Token in $f fehlerhaft (Zeilen: $cnt)."; rc=1; fi
  done
  return $rc
}

# Sicherer, dedizierter Menuepunkt: Cloudflare API Token aendern (Bug P3).
# Transaktional mit Rollback: ein falscher Token darf den alten, funktionierenden
# Stand niemals zerstoeren. Token wird nie unmaskiert ausgegeben.
change_cloudflare_token() {
  need_root; load_env
  section "Cloudflare API Token aendern"
  maybe_backup_before_change

  # 1) Alten Token + alte .env-Dateien sichern.
  local oldtok="${CLOUDFLARE_API_TOKEN:-}"
  local bak_env bak_caddyenv
  bak_env="$(mktemp)"; bak_caddyenv="$(mktemp)"
  [[ -f "$ENV_FILE" ]] && cp -a "$ENV_FILE" "$bak_env" 2>/dev/null || true
  [[ -f "${CADDY_DIR}/.env" ]] && cp -a "${CADDY_DIR}/.env" "$bak_caddyenv" 2>/dev/null || true

  # Aufraeumen der temporaeren Backups bei jedem Ruecksprung.
  _cf_cleanup() { rm -f "$bak_env" "$bak_caddyenv"; }

  # 2) Neuen Token verdeckt einlesen, 3) bereinigen (kein CR/LF/Whitespace).
  local newtok
  newtok="$(sanitize_token "$(ask_secret "Neuer Cloudflare API Token")")"
  if [[ -z "$newtok" ]]; then err "Kein Token eingegeben. Abbruch, nichts geaendert."; _cf_cleanup; return 1; fi

  # 4) Token optional gegen die Cloudflare Verify-API testen.
  if yesno "Token online gegen Cloudflare pruefen?" "y"; then
    if verify_cloudflare_token "$newtok"; then
      ok "Token von Cloudflare bestaetigt."
    else
      warn "Token konnte nicht bestaetigt werden (Netzwerk/Rechte/Format?)."
      if ! yesno "Trotzdem speichern?" "n"; then warn "Abgebrochen, nichts geaendert."; _cf_cleanup; return 1; fi
    fi
  fi

  # 5) Neuen Token in beide .env-Dateien schreiben.
  CLOUDFLARE_API_TOKEN="$newtok"
  save_env
  write_caddy_stack

  # 6+7) validieren, reload, Laufzeitpruefung. Bei jedem Fehler -> Rollback.
  local failed=0 reason=""
  if ! validate_token_files; then failed=1; reason="Token-Dateien fehlerhaft"; fi
  if (( ! failed )) && ! reload_caddy; then failed=1; reason="Caddy-Reload mit neuem Token fehlgeschlagen"; fi
  if (( ! failed )) && ! caddy_is_running; then failed=1; reason="Caddy laeuft nach Reload nicht"; fi

  # 8) Fehler -> alten Token + alte .env-Dateien wiederherstellen, Caddy mit
  #    altem Token wieder starten.
  if (( failed )); then
    err "${reason}."
    err "Rollback: alter Cloudflare Token wird wiederhergestellt."
    CLOUDFLARE_API_TOKEN="$oldtok"
    [[ -s "$bak_env" ]] && cp -a "$bak_env" "$ENV_FILE" 2>/dev/null || save_env
    [[ -s "$bak_caddyenv" ]] && cp -a "$bak_caddyenv" "${CADDY_DIR}/.env" 2>/dev/null || write_caddy_stack
    reload_caddy >/dev/null 2>&1 || restart_caddy >/dev/null 2>&1 || true
    if caddy_is_running; then
      ok "Alter funktionierender Stand wiederhergestellt, Caddy laeuft."
    else
      err "Caddy laeuft nach Rollback nicht - bitte manuell pruefen: sudo homeedge restart"
    fi
    _cf_cleanup
    err "Token nicht uebernommen. (Anzeige maskiert: cfut_***MASKED***)"
    return 1
  fi

  # 9) Erfolg.
  _cf_cleanup
  ok "Token gespeichert (einzeilig) in ${ENV_FILE} und ${CADDY_DIR}/.env"
  ok "Cloudflare Token aktualisiert und Caddy laeuft. (Anzeige maskiert: cfut_***MASKED***)"
}

show_logs() {
  menu_head "HomeEdge - Logs"
  menu_item 1 "Caddy Container Logs"
  menu_item 2 "Caddy Access Log"
  menu_item 3 "Fail2ban Log"
  menu_item 4 "WireGuard Live"
  menu_item 0 "Zurueck"
  line
  local c; c="$(ask "Auswahl" "1")"
  case "$c" in 1) if caddy_compose_file_exists; then caddy_compose logs -f --tail 100 2>&1 | mask_secrets; else docker logs -f --tail 100 caddy-edge 2>&1 | mask_secrets; fi ;; 2) tail -f "${CADDY_DIR}/logs/access.log" 2>/dev/null | mask_secrets ;; 3) { tail -f /var/log/fail2ban.log 2>/dev/null || journalctl -u fail2ban -f; } | mask_secrets ;; 4) watch -n 2 wg show ;; 0) return ;; *) err "Ungueltig." ;; esac
}

system_usage() {
  section "Server-Auslastung"
  echo "Load / Uptime:"
  uptime || true
  echo
  echo "RAM / Swap:"
  free -h || true
  echo
  echo "Root-Dateisystem:"
  df -h / || true
  echo
  echo "Top Prozesse nach RAM:"
  ps aux --sort=-%mem | head -10 || true
  echo
  echo "Docker Container Verbrauch:"
  if command -v docker >/dev/null 2>&1; then
    docker stats --no-stream 2>/dev/null || warn "Docker stats nicht verfuegbar oder keine Container."
  else
    warn "Docker ist nicht installiert."
  fi
  echo
  echo "WireGuard Transfer:"
  wg show 2>/dev/null || warn "WireGuard Status nicht verfuegbar."
}



# ------------------------------------------------------------
# Monitoring: Beszel Agent (optional)
# ------------------------------------------------------------
# Der Agent wird NIE automatisch installiert. Er unterstuetzt ZWEI Modelle:
#
#  1) PULL / SSH  (BESZEL_MODE=pull, empfohlen): Der Beszel-Hub verbindet sich
#     zum Agent. Der Agent-Port ist NUR ueber das WireGuard-Interface UND NUR
#     fuer die WireGuard-IP des Hubs erreichbar - nie oeffentlich. Benoetigt
#     KEY (+ LISTEN/Port/Iface/Hub-IP), NICHT HUB_URL/TOKEN.
#     Firewall-Regel (exakt):
#       ufw allow in on <IFACE> from <HUB_WG_IP> to any port <PORT> proto tcp \
#         comment 'Homeedge Beszel Agent'
#
#  2) WEBSOCKET / TOKEN  (BESZEL_MODE=websocket, advanced): Der Agent verbindet
#     sich AKTIV zum Hub. Benoetigt KEY + HUB_URL + TOKEN. KEINE eingehende
#     UFW-Regel fuer den Agent-Port noetig.
#
# Konfig (chmod 600) in ${BESZEL_ENV}: KEY, HUB_URL, TOKEN, LISTEN, BESZEL_MODE,
# BESZEL_AGENT_PORT, BESZEL_WG_IFACE, BESZEL_HUB_WG_IP.
# Wichtig: fuer die Firewall wird NIE HUB_URL benutzt, nur BESZEL_HUB_WG_IP.
# KEY und TOKEN werden nie im Klartext ausgegeben.

# Liest einen Wert aus beszel.env (unquoted). $1 = Schluessel.
_beszel_get() {
  [[ -f "$BESZEL_ENV" ]] || return 0
  # "|| true": fehlt der Schluessel, liefert grep rc 1; ohne Guard wuerde die
  # bare Zuweisung in load_beszel_config unter set -e (CLI) abbrechen (alte
  # env ohne BESZEL_MODE etc.). Funktion gibt IMMER rc 0 zurueck.
  grep -m1 "^$1=" "$BESZEL_ENV" 2>/dev/null | cut -d= -f2- \
    | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" || true
}

# Extrahiert den Port aus einem LISTEN-Wert (IP:PORT, [v6]:PORT, :PORT oder PORT).
_beszel_port_from_listen() {
  local l="${1:-}"
  [[ -z "$l" ]] && return 0
  if [[ "$l" == *:* ]]; then echo "${l##*:}"; else echo "$l"; fi
}

# Laedt die gespeicherte Konfiguration in globale Variablen (best effort).
load_beszel_config() {
  BESZEL_KEY=""; BESZEL_TOKEN=""; BESZEL_HUB_URL=""; BESZEL_LISTEN=""
  BESZEL_MODE="pull"
  BESZEL_AGENT_PORT="$BESZEL_PORT_DEFAULT"; BESZEL_HUB_WG_IP=""; BESZEL_WG_IFACE=""
  [[ -f "$BESZEL_ENV" ]] || return 0
  BESZEL_KEY="$(_beszel_get KEY)"
  BESZEL_TOKEN="$(_beszel_get TOKEN)"
  BESZEL_HUB_URL="$(_beszel_get HUB_URL)"
  BESZEL_LISTEN="$(_beszel_get LISTEN)"
  local m; m="$(_beszel_get BESZEL_MODE)"
  if [[ "$m" == "pull" || "$m" == "websocket" ]]; then
    BESZEL_MODE="$m"
  else
    # Altinstallation ohne gespeicherten Modus: aus HUB_URL/TOKEN ableiten.
    if [[ -n "$BESZEL_HUB_URL" && -n "$BESZEL_TOKEN" ]]; then BESZEL_MODE="websocket"; else BESZEL_MODE="pull"; fi
  fi
  local p; p="$(_beszel_get BESZEL_AGENT_PORT)"
  [[ "$p" =~ ^[0-9]+$ ]] || p="$(_beszel_port_from_listen "$BESZEL_LISTEN")"
  [[ "$p" =~ ^[0-9]+$ ]] && BESZEL_AGENT_PORT="$p"
  BESZEL_HUB_WG_IP="$(_beszel_get BESZEL_HUB_WG_IP)"
  BESZEL_WG_IFACE="$(_beszel_get BESZEL_WG_IFACE)"
}

# Nur numerischer Port 1-65535.
beszel_validate_port() { [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

# WireGuard-Interface muss existieren (ip link show <iface>).
beszel_validate_wg_iface() { [[ -n "${1:-}" ]] && ip link show "$1" >/dev/null 2>&1; }

# Hub-IP/CIDR: IPv4/IPv6/CIDR, nicht leer. 0=ok, 1=Formatfehler, 2=verboten (0.0.0.0/0 ::/0).
# CIDR-Bits werden sauber geprueft: IPv4 /0-/32, IPv6 /0-/128.
beszel_validate_hub_ip() {
  local ip="${1:-}" host o pfx
  [[ -n "$ip" ]] || return 1
  case "$ip" in 0.0.0.0/0|::/0|0.0.0.0|::) return 2 ;; esac
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]{1,3})?$ ]]; then
    host="${ip%%/*}"
    for o in ${host//./ }; do (( o >= 0 && o <= 255 )) || return 1; done
    if [[ "$ip" == */* ]]; then pfx="${ip##*/}"; (( pfx >= 0 && pfx <= 32 )) || return 1; fi
    return 0
  fi
  # IPv6(/CIDR): Hex-Gruppen mit Doppelpunkt; Prefix 0-128.
  if [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ ]]; then
    if [[ "$ip" == */* ]]; then pfx="${ip##*/}"; (( pfx >= 0 && pfx <= 128 )) || return 1; fi
    return 0
  fi
  return 1
}

# Validiert eine LISTEN-Bind-IP (ohne Port): leer ODER einzelne IPv4/IPv6 (KEIN
# CIDR, KEIN Hostname, KEINE Sonderzeichen/Leerzeichen). 0 = ok.
beszel_validate_listen_ip() {
  local ip="${1:-}" o
  [[ -z "$ip" ]] && return 0
  # keine Shell-Sonderzeichen / Whitespace / CIDR
  [[ "$ip" == */* ]] && return 1
  [[ "$ip" =~ [[:space:]\;\$\`\"\'\\\&\|\<\>\(\)] ]] && return 1
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    for o in ${ip//./ }; do (( o >= 0 && o <= 255 )) || return 1; done
    return 0
  fi
  # IPv6 (ohne Zone/Prefix)
  [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:]+$ ]] && return 0
  return 1
}

# Normalisiert einen Beszel-/SSH-Public-Key: CR/Rand-Whitespace entfernen, ein
# fehlendes Leerzeichen nach dem Typ (z. B. "ssh-ed25519AAAA...") automatisch
# einfuegen, und auf die ersten zwei Felder (Typ + Base64) reduzieren (Kommentar
# verwerfen). Gibt den bereinigten Key aus (ggf. leer).
_beszel_key_normalize() {
  local k="${1:-}"
  k="${k//$'\r'/}"; k="${k//$'\n'/ }"
  # fuehrende/abschliessende Leerzeichen trimmen
  k="${k#"${k%%[![:space:]]*}"}"; k="${k%"${k##*[![:space:]]}"}"
  # fehlendes Leerzeichen nach bekanntem Typ eindeutig korrigieren
  k="$(printf '%s' "$k" | sed -E 's#^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-[a-z0-9-]+)([A-Za-z0-9+/])#\1 \3#')"
  # auf Typ + Base64 (erste zwei Felder) reduzieren
  local typ blob _rest
  read -r typ blob _rest <<<"$k"
  [[ -n "$typ" && -n "$blob" ]] && printf '%s %s' "$typ" "$blob"
}

# Prueft einen (normalisierten) SSH-Public-Key: bekannter Typ + Leerzeichen +
# Base64-Blob (>= 32 Zeichen). 0 = gueltig.
beszel_validate_key() {
  [[ "${1:-}" =~ ^(ssh-ed25519|ssh-rsa|ssh-dss|ecdsa-sha2-[a-z0-9-]+)[[:space:]][A-Za-z0-9+/]{32,}={0,3}$ ]]
}

# Prueft, ob eine HUB_URL ausgehend erreichbar ist (irgendeine HTTP-Antwort =
# erreichbar). 0 = erreichbar, 1 = nicht erreichbar, 2 = kann nicht pruefen.
beszel_hub_reachable() {
  local url="${1:-}"
  [[ -n "$url" ]] || return 1
  command -v curl >/dev/null 2>&1 || return 2
  curl -sS -m 8 -o /dev/null "$url" >/dev/null 2>&1
}

# Ist UFW aktiv? 0 = ja.
ufw_is_active() { ufw status 2>/dev/null | grep -qiE "Status: (active|aktiv)"; }

# Lauscht der Agent auf einer WILDCARD-Adresse (*:PORT / 0.0.0.0 / [::]) - also
# potenziell oeffentlich? 0 = ja.
beszel_listens_wildcard() {
  local port="$1"
  command -v ss >/dev/null 2>&1 || return 1
  ss -H -ltn "sport = :${port}" 2>/dev/null \
    | grep -qE '(\*|0\.0\.0\.0|\[::\]|::):'"${port}"'([[:space:]]|$)'
}

# Lauscht der Agent AUSSCHLIESSLICH auf Loopback (127.0.0.0/8 / ::1)? 0 = ja.
# Ein reiner Loopback-Listener ist von aussen nie erreichbar (auch ohne UFW).
beszel_listens_only_loopback() {
  local port="$1" addrs a host
  command -v ss >/dev/null 2>&1 || return 1
  addrs="$(ss -H -ltn "sport = :${port}" 2>/dev/null | awk '{print $4}')"
  [[ -z "$addrs" ]] && return 1   # lauscht gar nicht -> nicht "nur loopback"
  while read -r a; do
    [[ -z "$a" ]] && continue
    host="${a%:*}"; host="${host#[}"; host="${host%]}"
    case "$host" in
      127.*|::1) : ;;             # loopback ok
      *) return 1 ;;              # eine Nicht-Loopback-Adresse -> false
    esac
  done <<< "$addrs"
  return 0
}

# Ist ein Host eine private/LAN-/Loopback-Adresse oder ein lokaler Hostname?
beszel_is_private_host() {
  local h="${1:-}"
  case "$h" in
    localhost|*.local|*.lan|*.home|*.internal) return 0 ;;
    10.*|127.*|192.168.*|169.254.*) return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    ::1|fc[0-9a-fA-F][0-9a-fA-F]:*|fd[0-9a-fA-F][0-9a-fA-F]:*|fe80:*) return 0 ;;
  esac
  return 1
}

# Ermittelt den Beszel-Release-Dateinamen fuer die aktuelle Architektur.
beszel_arch() {
  case "$(uname -m 2>/dev/null)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;;
    *) return 1 ;;
  esac
}

beszel_installed() { [[ -x "$BESZEL_BIN" ]]; }

# Liest den aktuell gesetzten LISTEN-Port aus der env, sonst Default.
beszel_port() {
  local p=""
  [[ -f "$BESZEL_ENV" ]] && p="$(grep -m1 '^LISTEN=' "$BESZEL_ENV" 2>/dev/null | cut -d= -f2- | tr -d '"'\''[:space:]' || true)"
  [[ -n "$p" && "$p" =~ ^[0-9]+$ ]] || p="$BESZEL_PORT_DEFAULT"
  echo "$p"
}

beszel_version() {
  [[ -x "$BESZEL_BIN" ]] || { echo "nicht installiert"; return; }
  "$BESZEL_BIN" -v 2>/dev/null | head -n1 \
    || "$BESZEL_BIN" --version 2>/dev/null | head -n1 \
    || echo "unbekannt"
}

# Erlaubt harmlose Zeichen fuer Token/KEY: kein CR/LF/Whitespace, keine
# Sonderzeichen die die env-Datei aushebeln koennten. KEY darf Base64 sein
# (Slash/Plus/Gleich enthalten), TOKEN typischerweise nur Base64/URL-safe.
_beszel_sanitize_line() { printf '%s' "${1:-}" | tr -d '\r\n[:space:]"'\''`$\\'; }

beszel_write_env() {
  # $1 MODE  $2 KEY  $3 TOKEN  $4 HUB_URL  $5 LISTEN  $6 PORT  $7 HUB_WG_IP  $8 WG_IFACE
  local mode="$1" key="$2" tok="$3" hub="$4" listen="$5" port="$6" hubip="$7" iface="$8"
  umask 077
  cat > "$BESZEL_ENV" <<EOB
# HomeEdge - Beszel-Agent Konfiguration (chmod 600)
# Verwaltet ueber: sudo homeedge beszel-install / beszel-reconfigure
# BESZEL_MODE = pull (Hub -> Agent, WireGuard) oder websocket (Agent -> Hub).
# BESZEL_HUB_WG_IP = WireGuard-IP/CIDR, die per UFW auf den Agent-Port darf.
# Fuer die Firewall wird NUR BESZEL_HUB_WG_IP genutzt, NIE HUB_URL.
KEY="${key}"
HUB_URL="${hub}"
TOKEN="${tok}"
LISTEN="${listen}"
BESZEL_MODE="${mode}"
BESZEL_AGENT_PORT="${port}"
BESZEL_WG_IFACE="${iface}"
BESZEL_HUB_WG_IP="${hubip}"
EOB
  chmod 600 "$BESZEL_ENV"
}

# Fragt den KEY interaktiv ab, normalisiert und validiert ihn (mit Auto-Fix des
# fehlenden Leerzeichens). Bei reconfigure = leer -> alten KEY behalten. Setzt NB_KEY.
_beszel_prompt_key() {
  local op="$1" hint="" raw clean
  [[ "$op" == reconfigure ]] && hint=" (leer = unveraendert)"
  while :; do
    raw="$(ask_secret "Beszel Public-Key (KEY, vollstaendig aus dem Hub kopieren)${hint}")"
    if [[ -z "$raw" && "$op" == reconfigure ]]; then NB_KEY="$BESZEL_KEY"; return 0; fi
    clean="$(_beszel_key_normalize "$raw")"
    if beszel_validate_key "$clean"; then NB_KEY="$clean"; return 0; fi
    err "Ungueltiger Beszel Public Key. Bitte den Public Key aus dem Beszel Hub vollstaendig kopieren. Format: ssh-ed25519 AAAA..."
  done
}

# Erklaert (Pull-Modus), dass fuer die UFW-Quell-IP die tatsaechlich auf dem
# WireGuard-Interface sichtbare Source-IP zaehlt - NICHT die LAN-/Docker-IP des
# Hub. $1 = iface, $2 = port.
_beszel_source_ip_help() {
  local iface="${1:-<WG_IFACE>}" port="${2:-<PORT>}" vpsip="${VPS_WG_IP:-<VPS_WG_IP>}"
  echo
  warn "WICHTIG - richtige Hub-Quell-IP fuer die Firewall:"
  cat <<EOH
  Hier muss die Quell-IP eingetragen werden, die der VPS ueber das WireGuard-
  Interface SIEHT. Das ist oft NICHT die LAN-IP des Docker-/Unraid-Hosts und
  NICHT die Docker-Container-IP.

  Beispiel:
    Beszel Hub laeuft auf Unraid:   192.168.10.3   (LAN - NICHT eintragen)
    VPS WireGuard-IP:               ${vpsip}
    Hub/Gegenseite im Tunnel:       10.0.0.2       (DIESE IP eintragen)

  Im Beszel Hub ("System hinzufuegen") eintragen:
    Host/IP: ${vpsip}
    Port:    ${port}
  In HomeEdge als erlaubte Hub-IP eintragen:
    10.0.0.2   (die Tunnel-Source-IP der Hub-Seite)

  Unklar, welche IP? Auf dem VPS ausfuehren:
    sudo tcpdump -ni ${iface} tcp port ${port}
  Dann im Beszel Hub die Verbindung testen. Die Source-IP aus tcpdump
  (z. B.  10.0.0.2.xxxxx > ${vpsip}.${port}) ist die einzutragende Hub-IP
  -> BESZEL_HUB_WG_IP=10.0.0.2
EOH
  command -v tcpdump >/dev/null 2>&1 \
    || info "tcpdump ist nicht installiert - bei Bedarf: sudo apt update && sudo apt install -y tcpdump"
  echo
}

# Interaktive Konfig-Abfrage. $1 = install|reconfigure. Fragt zuerst den Modus ab
# und danach nur die je Modus benoetigten Werte. Setzt NB_MODE/NB_KEY/NB_TOKEN/
# NB_HUB/NB_LISTEN/NB_PORT/NB_IFACE/NB_HUBIP.
_beszel_prompt_config() {
  local op="$1" vr def_mode="pull" mc
  [[ -n "${BESZEL_MODE:-}" ]] && def_mode="$BESZEL_MODE"
  echo "Wie soll der Beszel Agent angebunden werden?"
  echo "  1) Hub verbindet sich zum Agent ueber WireGuard (Pull/SSH, empfohlen)"
  echo "  2) Agent verbindet sich aktiv zum Hub per HUB_URL/TOKEN (WebSocket, advanced)"
  mc="$(ask "Auswahl" "$([[ "$def_mode" == websocket ]] && echo 2 || echo 1)")"
  case "$mc" in
    2|websocket|ws) NB_MODE="websocket" ;;
    *)              NB_MODE="pull" ;;
  esac

  # KEY wird in BEIDEN Modi benoetigt.
  _beszel_prompt_key "$op"

  # Defaults leeren, damit modus-fremde Werte nicht versehentlich bestehen bleiben.
  NB_TOKEN=""; NB_HUB=""; NB_LISTEN=""; NB_IFACE=""; NB_HUBIP=""
  NB_PORT="${BESZEL_AGENT_PORT:-$BESZEL_PORT_DEFAULT}"

  if [[ "$NB_MODE" == "pull" ]]; then
    while :; do
      NB_PORT="$(ask "Agent-Port" "${BESZEL_AGENT_PORT:-$BESZEL_PORT_DEFAULT}")"
      beszel_validate_port "$NB_PORT" && break
      err "Ungueltiger Port (1-65535)."
    done
    while :; do
      NB_IFACE="$(ask "WireGuard-Interface (Agent nur ueber dieses Interface)" "${BESZEL_WG_IFACE:-${WG_IF:-wg0}}")"
      beszel_validate_wg_iface "$NB_IFACE" && break
      warn "Interface '${NB_IFACE}' existiert derzeit nicht (ip link show ${NB_IFACE})."
      yesno "Trotzdem verwenden (Tunnel evtl. noch nicht aktiv)?" "n" && break
    done
    # Vor der Hub-IP-Abfrage klar erklaeren, WELCHE IP gemeint ist.
    _beszel_source_ip_help "$NB_IFACE" "$NB_PORT"
    while :; do
      NB_HUBIP="$(ask "Erlaubte Hub-Quell-IP im Tunnel (die der VPS auf ${NB_IFACE} sieht), z. B. 10.0.0.2 - NICHT die LAN-IP" "${BESZEL_HUB_WG_IP:-}")"
      vr=0; beszel_validate_hub_ip "$NB_HUBIP" || vr=$?
      (( vr == 2 )) && { err "0.0.0.0/0 bzw. ::/0 ist NICHT erlaubt - das waere oeffentlich!"; continue; }
      (( vr != 0 )) && { err "Ungueltige IP/CIDR. Erlaubt: einzelne IPv4/IPv6 (nicht leer)."; continue; }
      # Standard: nur EINZELNE Host-IP. CIDR erlaubt mehrere Clients -> nur im
      # Expertenmodus nach ausdruecklicher Bestaetigung.
      if [[ "$NB_HUBIP" == */* ]]; then
        warn "CIDR erlaubt mehrere Clients und ist weniger restriktiv."
        if yesno "CIDR ${NB_HUBIP} wirklich verwenden (Expertenmodus)?" "n"; then break; fi
        err "Bitte eine EINZELNE Host-IP eingeben (z. B. 10.0.0.2)."
        continue
      fi
      break
    done
    # Lokale Listen-IP: bevorzugt an die VPS-WireGuard-IP binden (nicht oeffentlich).
    # Nur leer oder eine EINZELNE gueltige IPv4/IPv6 - kein Hostname/CIDR/Sonderzeichen.
    local def_ip="${VPS_WG_IP:-}" lip
    while :; do
      lip="$(ask "Lokale Listen-IP (leer = alle Interfaces; Default VPS-WireGuard-IP)" "$def_ip")"
      beszel_validate_listen_ip "$lip" && break
      err "Ungueltige Listen-IP. Erlaubt: leer oder einzelne IPv4/IPv6 (kein Hostname, kein CIDR, keine Sonderzeichen)."
    done
    if [[ -z "$lip" ]]; then
      NB_LISTEN="${NB_PORT}"
    elif [[ "$lip" == *:* ]]; then
      NB_LISTEN="[${lip}]:${NB_PORT}"   # IPv6 in eckigen Klammern
    else
      NB_LISTEN="${lip}:${NB_PORT}"
    fi
  else
    # WebSocket: HUB_URL + TOKEN Pflicht, KEINE eingehende Regel/Interface/Hub-IP.
    local host
    while :; do
      NB_HUB="$(_beszel_sanitize_line "$(ask "Beszel HUB_URL (z. B. https://beszel.example.de)" "${BESZEL_HUB_URL:-}")")"
      if [[ -z "$NB_HUB" ]]; then err "HUB_URL darf im WebSocket-Modus nicht leer sein."; continue; fi
      if [[ "$NB_HUB" =~ ^https:// ]]; then break; fi
      if [[ "$NB_HUB" =~ ^http:// ]]; then
        host="${NB_HUB#http://}"; host="${host%%[:/]*}"
        if beszel_is_private_host "$host"; then
          info "http:// akzeptiert (private/LAN-Adresse ${host})."
          break
        fi
        warn "HUB_URL nutzt unverschluesseltes http:// fuer eine oeffentliche Adresse (${host})."
        yesno "Trotzdem verwenden (nicht empfohlen)?" "n" && break
        continue
      fi
      err "HUB_URL muss mit http:// oder https:// beginnen."
    done
    local rawtok
    rawtok="$(ask_secret "Beszel Registrations-TOKEN$([[ "$op" == reconfigure ]] && echo ' (leer = unveraendert)')")"
    NB_TOKEN="$(_beszel_sanitize_line "$rawtok")"
    [[ -z "$NB_TOKEN" && "$op" == reconfigure ]] && NB_TOKEN="$BESZEL_TOKEN"
    NB_PORT="${BESZEL_AGENT_PORT:-$BESZEL_PORT_DEFAULT}"
    # WICHTIG: LISTEN NICHT leer lassen. Ein leeres LISTEN kann dazu fuehren, dass
    # der Agent auf dem Default-Port auf *:PORT (alle Interfaces) lauscht. Im
    # WebSocket-Modus verbindet sich der Agent aktiv zum Hub und braucht KEINEN
    # oeffentlichen Listener -> fest an Loopback binden.
    NB_LISTEN="127.0.0.1:${NB_PORT}"
  fi
}

# Schreibt die systemd-Unit. $1 mode $2 iface $3 listen. Im Pull-Modus wird die
# Unit vom WireGuard-Interface abhaengig gemacht (After/Wants=wg-quick@IFACE) und
# - falls LISTEN eine IP enthaelt - per ExecStartPre gewartet, bis die IP am
# Interface existiert (verhindert Boot-Race). StateDirectory/WorkingDirectory
# geben dem Agent ein beschreibbares Datenverzeichnis (kein "Data directory not found").
beszel_write_unit() {
  local mode="${1:-pull}" iface="${2:-}" listen="${3:-}"
  local after_line="network-online.target" wants_line="network-online.target" pre_line="" lip=""
  if [[ "$mode" == "pull" && -n "$iface" ]]; then
    after_line="wg-quick@${iface}.service network-online.target"
    wants_line="wg-quick@${iface}.service network-online.target"
    # Listen-IP aus LISTEN extrahieren (IP:PORT bzw. [v6]:PORT), Port abschneiden.
    if [[ "$listen" == *:* ]]; then
      lip="${listen%:*}"; lip="${lip#[}"; lip="${lip%]}"
    fi
    if [[ -n "$lip" ]]; then
      # Bis zu 30s auf die Listen-IP am Interface warten; sonst Fehler -> Restart.
      pre_line="ExecStartPre=/bin/sh -c 'for i in \$(seq 1 30); do ip -o addr show ${iface} 2>/dev/null | grep -qw ${lip} && exit 0; sleep 1; done; echo \"Beszel: Listen-IP ${lip} auf ${iface} nicht vorhanden\" >&2; exit 1'"
    fi
  fi
  cat > "$BESZEL_UNIT" <<EOUNIT
[Unit]
Description=Beszel Agent (HomeEdge, ${mode})
After=${after_line}
Wants=${wants_line}

[Service]
Type=simple
User=root
EnvironmentFile=/etc/homeedge/beszel.env
${pre_line}
ExecStart=/usr/local/bin/beszel-agent
Restart=on-failure
RestartSec=5s
StateDirectory=beszel-agent
WorkingDirectory=/var/lib/beszel-agent
# Absicherung
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/beszel-agent
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictNamespaces=yes
LockPersonality=yes
MemoryDenyWriteExecute=yes
RestrictRealtime=yes
RestrictSUIDSGID=yes
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOUNIT
  chmod 644 "$BESZEL_UNIT"
  systemctl daemon-reload
}

# Findet WIRKLICH zu weite UFW-Freigaben fuer den Port: Quelle Anywhere /
# Anywhere (v6) / 0.0.0.0/0 / ::/0 (auch interface-only ohne 'from' rendert als
# "Anywhere"). Eine restriktive Regel "... ALLOW <hub-ip>" wird NICHT gemeldet.
# Unabhaengig von der Hub-IP - so entstehen keine falschen "oeffentlich"-Meldungen.
beszel_public_exposure() {
  local port="$1"
  command -v ufw >/dev/null 2>&1 || return 0
  # WICHTIG: "|| true" - im Normalfall (keine zu weite Regel) liefert die letzte
  # grep-Stufe rc 1; ohne Guard wuerde eine bare Zuweisung var="$(...)" unter
  # set -e (CLI-Pfad) das Skript abbrechen. Die Funktion gibt IMMER rc 0 zurueck.
  ufw status 2>/dev/null \
    | grep -E "(^|[^0-9])${port}/(tcp|udp)([[:space:]]|\(v6\))" \
    | grep -iF "ALLOW" \
    | grep -iE 'Anywhere|0\.0\.0\.0/0|::/0' || true
}

# Entfernt GENAU die restriktive Regel anhand (alter) Werte. Fehler ignorieren.
beszel_remove_ufw_rule() {
  local iface="$1" ip="$2" port="$3"
  command -v ufw >/dev/null 2>&1 || return 0
  [[ -n "$iface" && -n "$ip" && -n "$port" ]] || return 0
  ufw delete allow in on "$iface" from "$ip" to any port "$port" proto tcp >/dev/null 2>&1 || true
}

# Setzt GENAU eine restriktive Regel: nur ueber <iface> und nur von <ip>.
beszel_apply_ufw_rule() {
  local iface="$1" ip="$2" port="$3"
  if ! command -v ufw >/dev/null 2>&1; then
    warn "UFW nicht installiert - Regel nicht gesetzt. Port ${port} manuell auf WireGuard/${ip} beschraenken!"
    return 0
  fi
  ufw allow in on "$iface" from "$ip" to any port "$port" proto tcp comment 'Homeedge Beszel Agent' >/dev/null 2>&1 \
    && ok "UFW: Port ${port}/tcp NUR von ${ip} ueber ${iface} erlaubt." \
    || warn "UFW-Regel konnte nicht gesetzt werden - bitte manuell pruefen."
  ufw reload >/dev/null 2>&1 || true
}

# Bietet an, oeffentliche/zu weite Freigaben fuer den Port zu entfernen. Es
# werden NUR die bekannten pauschalen/interface-only-Formen entfernt, keine
# fremden Regeln ungefragt.
beszel_remove_public_exposure() {
  local port="$1" iface="${2:-}" pub
  pub="$(beszel_public_exposure "$port")"
  [[ -z "$pub" ]] && return 0
  warn "Oeffentliche oder zu weite UFW-Freigabe(n) fuer Port ${port} gefunden:"
  printf '%s\n' "$pub" | sed 's/^/  /'
  if yesno "Diese Freigabe(n) jetzt entfernen (empfohlen)?" "y"; then
    ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
    ufw delete allow "${port}/udp" >/dev/null 2>&1 || true
    ufw delete allow "${port}" >/dev/null 2>&1 || true
    [[ -n "$iface" ]] && ufw delete allow in on "$iface" to any port "${port}" proto tcp >/dev/null 2>&1 || true
    ufw reload >/dev/null 2>&1 || true
    local left; left="$(beszel_public_exposure "$port")"
    if [[ -z "$left" ]]; then ok "Oeffentliche Freigabe(n) fuer ${port} entfernt."
    else warn "Nicht alles automatisch entfernbar - bitte manuell: sudo ufw status numbered"; fi
  else
    warn "Oeffentliche Freigabe fuer ${port} bleibt bestehen - das ist unsicher!"
  fi
}

# Laedt das aktuelle Beszel-Agent-Binary (latest) und installiert es atomar.
# Erfolgt IMMER in einer Temp-Datei; nur bei erfolgreicher Groessen-/Format-
# Pruefung wird /usr/local/bin/beszel-agent ersetzt.
beszel_download_binary() {
  need_root
  local arch tar_name url tmp ver_before ver_after
  if ! command -v curl >/dev/null 2>&1; then err "curl ist nicht installiert."; return 1; fi
  arch="$(beszel_arch)" || { err "Nicht unterstuetzte Architektur: $(uname -m)"; return 1; }
  ver_before="$(beszel_version 2>/dev/null || echo 'nicht installiert')"
  tar_name="beszel-agent_linux_${arch}.tar.gz"
  url="${BESZEL_DOWNLOAD_BASE}/${tar_name}"
  info "Lade Beszel Agent (${arch}) von ${url} ..."
  tmp="$(mktemp -d)"
  # KEIN RETURN-Trap: der feuert bei verschachtelten Funktionen unerwartet
  # erneut und laeuft dann unter "set -u" auf ein ungesetztes $tmp. Stattdessen
  # wird das Temp-Verzeichnis auf jedem Pfad explizit aufgeraeumt.
  if ! curl -fsSL -o "${tmp}/${tar_name}" "$url"; then
    err "Download fehlgeschlagen. Netzwerk/URL pruefen."
    rm -rf "$tmp"; return 1
  fi
  # Optionale SHA256-Pruefung: falls upstream <asset>.sha256 bereitstellt.
  local sum_remote="" sum_local="" verified=0
  if sum_remote="$(curl -fsSL -m 15 "${url}.sha256" 2>/dev/null)" && [[ -n "$sum_remote" ]] && command -v sha256sum >/dev/null 2>&1; then
    sum_remote="$(awk '{print $1}' <<<"$sum_remote")"
    sum_local="$(sha256sum "${tmp}/${tar_name}" | awk '{print $1}')"
    if [[ -n "$sum_remote" && "$sum_remote" == "$sum_local" ]]; then
      ok "SHA256 verifiziert."; verified=1
    else
      err "SHA256 stimmt nicht ueberein - Abbruch, altes Binary bleibt intakt."
      err "erwartet: ${sum_remote}"; err "erhalten: ${sum_local}"
      rm -rf "$tmp"; return 1
    fi
  fi
  (( verified )) || warn "Download von GitHub latest OHNE separate Signatur-/Checksummenpruefung."
  if ! tar -xzf "${tmp}/${tar_name}" -C "$tmp" 2>/dev/null; then
    err "Archiv konnte nicht entpackt werden."
    rm -rf "$tmp"; return 1
  fi
  local extracted; extracted="$(find "$tmp" -maxdepth 2 -type f -name 'beszel-agent' | head -n1 || true)"
  if [[ -z "$extracted" || ! -s "$extracted" ]]; then
    err "beszel-agent Binary nicht im Archiv gefunden."
    rm -rf "$tmp"; return 1
  fi
  # Atomar installieren (kein halb ueberschriebenes Binary).
  install -m 0755 "$extracted" "$BESZEL_BIN"
  rm -rf "$tmp"
  ver_after="$(beszel_version)"
  info "Version vorher: ${ver_before}  ->  nachher: ${ver_after}"
  ok "Beszel Agent installiert: ${ver_after}"
}

# Interaktive Installation (frische Installation).
beszel_install() {
  need_root; load_env; load_beszel_config
  section "Beszel Agent installieren"
  if beszel_installed; then
    warn "Beszel Agent ist bereits installiert (${BESZEL_BIN})."
    echo "  1) Konfiguration aendern (Modus / Port / Hub-IP / Token)"
    echo "  2) Auf aktuelle Version aktualisieren"
    echo "  0) Abbruch"
    local c; c="$(ask "Auswahl" "0")"
    case "$c" in
      1) beszel_reconfigure; return $? ;;
      2) beszel_update; return $? ;;
      *) warn "Abgebrochen."; return 0 ;;
    esac
  fi

  _beszel_prompt_config install
  # Pflichtfelder je Modus pruefen.
  if [[ "$NB_MODE" == "pull" ]]; then
    [[ -z "$NB_KEY" ]] && { err "KEY ist im Pull-Modus Pflicht."; return 1; }
    [[ -z "$NB_HUBIP" ]] && { err "Hub-WireGuard-IP ist im Pull-Modus Pflicht."; return 1; }
  else
    [[ -z "$NB_KEY" || -z "$NB_HUB" || -z "$NB_TOKEN" ]] && { err "KEY, HUB_URL und TOKEN sind im WebSocket-Modus Pflicht."; return 1; }
  fi

  beszel_download_binary || return 1
  beszel_write_env "$NB_MODE" "$NB_KEY" "$NB_TOKEN" "$NB_HUB" "$NB_LISTEN" "$NB_PORT" "$NB_HUBIP" "$NB_IFACE"
  ok "Konfig geschrieben: ${BESZEL_ENV} (chmod 600, Secrets nicht ausgegeben)."
  beszel_write_unit "$NB_MODE" "$NB_IFACE" "$NB_LISTEN"
  ok "systemd-Unit geschrieben: ${BESZEL_UNIT}"

  if [[ "$NB_MODE" == "pull" ]]; then
    # Bestehende oeffentliche Altlasten pruefen/bereinigen, dann restriktive Regel.
    beszel_remove_public_exposure "$NB_PORT" "$NB_IFACE"
    beszel_apply_ufw_rule "$NB_IFACE" "$NB_HUBIP" "$NB_PORT"
  else
    info "WebSocket-Modus: keine eingehende UFW-Regel fuer Port ${NB_PORT} noetig."
    # Falls eine frueher gesetzte oeffentliche Freigabe existiert, anbieten zu entfernen.
    beszel_remove_public_exposure "$NB_PORT"
    if beszel_hub_reachable "$NB_HUB"; then ok "HUB_URL ausgehend erreichbar: ${NB_HUB}"
    else warn "HUB_URL nicht erreichbar (${NB_HUB}) - DNS/Netz/URL pruefen. Agent versucht es weiter."; fi
  fi

  systemctl enable --now beszel-agent >/dev/null 2>&1 || true
  sleep 1
  beszel_verify_installation
}

# Konfiguration aendern (Port/Hub-IP/Interface/Token): alte Regel weg, neue Regel.
beszel_reconfigure() {
  need_root; load_env; load_beszel_config
  section "Beszel Agent konfigurieren / Modus, Port oder Hub-IP aendern"
  if ! beszel_installed && [[ ! -f "$BESZEL_ENV" ]]; then
    err "Beszel Agent ist nicht installiert. Zuerst: sudo homeedge beszel-install"
    return 1
  fi
  # ALTE Werte merken (fuer gezielte Regel-Entfernung) - unabhaengig vom alten Modus.
  local old_iface="${BESZEL_WG_IFACE:-${WG_IF:-wg0}}" old_ip="${BESZEL_HUB_WG_IP:-}" old_port="${BESZEL_AGENT_PORT:-$BESZEL_PORT_DEFAULT}"
  _beszel_prompt_config reconfigure
  if [[ "$NB_MODE" == "pull" ]]; then
    [[ -z "$NB_KEY" ]] && { err "KEY ist im Pull-Modus Pflicht."; return 1; }
    [[ -z "$NB_HUBIP" ]] && { err "Hub-WireGuard-IP ist im Pull-Modus Pflicht."; return 1; }
  else
    [[ -z "$NB_KEY" || -z "$NB_HUB" || -z "$NB_TOKEN" ]] && { err "KEY, HUB_URL und TOKEN sind im WebSocket-Modus Pflicht."; return 1; }
  fi

  # Reihenfolge lt. Vorgabe: Service stoppen -> ALTE UFW-Regel entfernen ->
  # neue Werte schreiben -> ggf. NEUE UFW-Regel -> daemon-reload -> Service starten.
  systemctl stop beszel-agent 2>/dev/null || true
  # Alte restriktive Regel immer anhand der alten Werte entfernen (Port/IP/Modus-Wechsel).
  beszel_remove_ufw_rule "$old_iface" "$old_ip" "$old_port"
  beszel_write_env "$NB_MODE" "$NB_KEY" "$NB_TOKEN" "$NB_HUB" "$NB_LISTEN" "$NB_PORT" "$NB_HUBIP" "$NB_IFACE"
  ok "Konfig aktualisiert: ${BESZEL_ENV}"
  beszel_write_unit "$NB_MODE" "$NB_IFACE" "$NB_LISTEN"    # enthaelt systemctl daemon-reload
  if [[ "$NB_MODE" == "pull" ]]; then
    beszel_remove_public_exposure "$NB_PORT" "$NB_IFACE"
    beszel_apply_ufw_rule "$NB_IFACE" "$NB_HUBIP" "$NB_PORT"
  else
    info "WebSocket-Modus: keine eingehende UFW-Regel noetig - eingehende Freigabe wurde entfernt."
    beszel_remove_public_exposure "$NB_PORT"
    if beszel_hub_reachable "$NB_HUB"; then ok "HUB_URL ausgehend erreichbar: ${NB_HUB}"
    else warn "HUB_URL nicht erreichbar (${NB_HUB}) - DNS/Netz/URL pruefen."; fi
  fi
  systemctl start beszel-agent 2>/dev/null || true
  sleep 1
  beszel_verify_installation
}

# Zeigt eine klare, modus-abhaengige Statuszusammenfassung. Kehrt IMMER sauber
# zurueck (kein Shell-Fehler): 0 = ok, 1 = Warnung/Problem.
beszel_verify_installation() {
  load_beszel_config
  local mode="${BESZEL_MODE:-pull}"
  local port="${BESZEL_AGENT_PORT:-$BESZEL_PORT_DEFAULT}" ip="${BESZEL_HUB_WG_IP:-}" iface="${BESZEL_WG_IFACE:-${WG_IF:-wg0}}"
  section "Beszel Agent - Pruefung"
  local svc="nein" listen="nein" rule="nein" pub="nein" ufwact="nein" wild="nein"
  systemctl is-active --quiet beszel-agent 2>/dev/null && svc="ja"
  command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q . && listen="ja"
  beszel_listens_wildcard "$port" && wild="ja"
  if command -v ufw >/dev/null 2>&1; then
    ufw_is_active && ufwact="ja"
    # Restriktive Regel exakt: Portzeile MIT Interface UND mit der Hub-IP als Quelle.
    if [[ -n "$ip" ]] && ufw status 2>/dev/null | grep -E "(^|[^0-9])${port}/tcp" | grep -F "$iface" | grep -qF "$ip"; then rule="ja"; fi
    [[ -n "$(beszel_public_exposure "$port")" ]] && pub="ja"
  fi
  local modelabel; [[ "$mode" == websocket ]] && modelabel="WebSocket/Token" || modelabel="Pull/SSH (WireGuard)"
  printf '  Betriebsmodus:            %s\n' "$modelabel"
  printf '  Beszel Agent installiert: %s\n' "$(beszel_installed && echo ja || echo nein)"
  printf '  Service aktiv:            %s\n' "$svc"
  printf '  Version:                  %s\n' "$(beszel_version)"
  printf '  KEY gesetzt:              %s\n' "$([[ -n "${BESZEL_KEY:-}" ]] && echo ja || echo nein)"
  printf '  UFW aktiv:                %s\n' "$ufwact"
  if [[ "$mode" == "pull" ]]; then
    printf '  LISTEN:                   %s\n' "${BESZEL_LISTEN:-<nicht gesetzt>}"
    printf '  Agent-Port:               %s\n' "$port"
    printf '  WireGuard-Interface:      %s\n' "$iface"
    printf '  Beszel Hub Ziel (im Hub): %s\n' "${VPS_WG_IP:-<VPS_WG_IP>}:${port}"
    printf '  Erlaubte Quell-IP (UFW):  %s\n' "${ip:-<nicht gesetzt>}"
    printf '  UFW-Regel vorhanden:      %s\n' "$rule"
    printf '  Lauscht auf Port %s:  %s\n' "$port" "$listen"
    printf '  Oeffentliche Freigabe:    %s\n' "$pub"
    echo   "  Hinweis: Ziel-IP (im Hub) und erlaubte Quell-IP (UFW) sind normalerweise UNTERSCHIEDLICH."
  else
    printf '  HUB_URL gesetzt:          %s\n' "$([[ -n "${BESZEL_HUB_URL:-}" ]] && echo ja || echo nein)"
    printf '  TOKEN gesetzt:            %s\n' "$([[ -n "${BESZEL_TOKEN:-}" ]] && echo ja || echo nein)"
    printf '  Agent-Port (informativ): %s\n' "$port"
    printf '  Lauscht auf Port %s:  %s (Wildcard: %s)\n' "$port" "$listen" "$wild"
    printf '  Oeffentliche Freigabe:    %s\n' "$pub"
  fi
  echo
  # Bewertung.
  if [[ "$pub" == "ja" ]]; then
    err "ACHTUNG: OEFFENTLICHE/zu weite Freigabe fuer Port ${port} gefunden!"
    err "Der Agent-Port darf nicht oeffentlich erreichbar sein."
    info "Bereinigen: sudo homeedge beszel-check-firewall"
    return 1
  fi
  # UFW inaktiv + Agent lauscht NICHT-nur-Loopback -> Port ist NICHT durch die
  # Firewall geschuetzt. Ein reiner Loopback-Listener (127.0.0.1/::1) ist harmlos.
  if [[ "$listen" == "ja" && "$ufwact" == "nein" ]] && ! beszel_listens_only_loopback "$port"; then
    err "ACHTUNG: Agent lauscht extern erreichbar auf Port ${port}, aber UFW ist INAKTIV!"
    if [[ "$wild" == "ja" ]]; then
      err "Der Agent lauscht auf einer Wildcard-Adresse (*:${port}) - Port waere oeffentlich erreichbar."
    else
      err "Ohne aktive Firewall ist der Port nicht auf die Hub-IP eingeschraenkt (jeder WireGuard-Client/LAN-Host koennte zugreifen)."
    fi
    info "UFW aktivieren: sudo homeedge firewall   |   Regeln: sudo homeedge beszel-check-firewall"
    return 1
  fi
  if [[ "$mode" == "pull" ]]; then
    if [[ "$svc" == "ja" && "$rule" == "ja" && "$ufwact" == "ja" ]]; then
      ok "Pull-Modus OK: Zugriff nur von ${ip} ueber ${iface} erlaubt (UFW aktiv)."
      return 0
    fi
    warn "Pruefung nicht komplett gruen (Details oben). Ggf. Tunnel/Interface/Hub-IP/UFW pruefen."
    return 1
  else
    if [[ "$svc" == "ja" ]]; then
      [[ -z "${BESZEL_HUB_URL:-}" ]] && { warn "HUB_URL ist nicht gesetzt - im WebSocket-Modus erforderlich."; return 1; }
      ok "WebSocket-Modus OK: Agent laeuft, keine eingehende Freigabe noetig."
      return 0
    fi
    warn "Pruefung nicht komplett gruen: Service laeuft nicht (Logs: sudo homeedge beszel-logs)."
    return 1
  fi
}

beszel_status() {
  need_root; load_env; load_beszel_config
  section "Beszel Agent Status"
  if ! beszel_installed && [[ ! -f "$BESZEL_ENV" ]]; then warn "Beszel Agent ist NICHT installiert."; return 1; fi
  beszel_verify_installation || true
  echo
  echo "Version: $(beszel_version)"
  echo
  systemctl status beszel-agent --no-pager 2>&1 | mask_secrets | sed -n '1,12p' || true
  echo
  local port="${BESZEL_AGENT_PORT:-$BESZEL_PORT_DEFAULT}"
  echo "== Lauschende Sockets auf Port ${port} =="
  ss -H -ltn "sport = :${port}" 2>/dev/null | sed 's/^/  /' || true
  echo
  echo "== UFW-Regeln fuer Port ${port} =="
  ufw status 2>/dev/null | grep -E "(^|[^0-9])${port}/(tcp|udp)" | sed 's/^/  /' || true
}

# Menuepunkt 8: Firewall-Regeln pruefen und ggf. oeffentliche Freigaben entfernen.
beszel_check_firewall() {
  need_root; load_env; load_beszel_config
  section "Beszel Firewall-Regeln pruefen"
  local mode="${BESZEL_MODE:-pull}"
  local port="${BESZEL_AGENT_PORT:-$BESZEL_PORT_DEFAULT}" ip="${BESZEL_HUB_WG_IP:-}" iface="${BESZEL_WG_IFACE:-${WG_IF:-wg0}}"
  echo "Betriebsmodus: $([[ "$mode" == websocket ]] && echo 'WebSocket/Token' || echo 'Pull/SSH (WireGuard)')"
  echo
  echo "== Aktuelle UFW-Regeln fuer Port ${port} =="
  ufw status 2>/dev/null | grep -E "(^|[^0-9])${port}/(tcp|udp)" | sed 's/^/  /' || echo "  (keine)"
  echo
  # Gemeinsame Laufzeit-Fakten (beide Modi).
  local ufwact="nein" listen="nein" wild="nein" pubfound="nein"
  command -v ufw >/dev/null 2>&1 && ufw_is_active && ufwact="ja"
  command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q . && listen="ja"
  beszel_listens_wildcard "$port" && wild="ja"
  [[ -n "$(beszel_public_exposure "$port")" ]] && pubfound="ja"
  printf '  UFW aktiv: %s   Agent lauscht: %s   Wildcard *:%s: %s   Oeffentliche Regel: %s\n' \
    "$ufwact" "$listen" "$port" "$wild" "$pubfound"
  echo
  if [[ "$mode" == "websocket" ]]; then
    info "WebSocket-Modus: KEINE eingehende UFW-Regel fuer Port ${port} noetig."
    local ws_rc=0
    if beszel_listens_only_loopback "$port"; then
      ok "Agent lauscht nur auf Loopback (nicht extern erreichbar) - im WebSocket-Modus korrekt."
    elif [[ "$wild" == "ja" && "$ufwact" == "nein" ]]; then
      err "ACHTUNG: Agent lauscht auf *:${port} und UFW ist INAKTIV - Port waere oeffentlich erreichbar!"
      info "UFW aktivieren: sudo homeedge firewall"
      info "Oder Agent an Loopback binden: sudo homeedge beszel-reconfigure (WebSocket setzt LISTEN=127.0.0.1:${port})"
      ws_rc=1
    elif [[ "$listen" == "ja" && "$ufwact" == "nein" ]]; then
      warn "Agent lauscht extern auf Port ${port} und UFW ist inaktiv - bitte UFW aktivieren oder Bind pruefen."
      ws_rc=1
    fi
    # Oeffentliche/zu weite UFW-Regel -> ROT + Entfernung anbieten.
    if [[ "$pubfound" == "ja" ]]; then
      err "Oeffentliche/zu weite UFW-Freigabe fuer Port ${port} gefunden (im WebSocket-Modus nicht noetig)."
      beszel_remove_public_exposure "$port"
      [[ -n "$(beszel_public_exposure "$port")" ]] && ws_rc=1
    fi
    [[ -z "$(beszel_public_exposure "$port")" && "$ws_rc" == "0" ]] && ok "WebSocket-Firewall OK: keine oeffentliche Erreichbarkeit fuer Port ${port}."
    return "$ws_rc"
  fi
  echo "Im Beszel Hub eintragen:       ${VPS_WG_IP:-<VPS_WG_IP>}:${port}"
  echo "Auf VPS erlaubt als Quell-IP:  ${ip:-<keine Hub-IP gesetzt>}  (die IP, die der VPS auf ${iface} sieht)"
  echo "Erwartet: Zugriff NUR von ${ip:-<keine Hub-IP gesetzt>} ueber ${iface} auf Port ${port}."
  echo "(Ziel-IP im Hub und erlaubte Quell-IP sind normalerweise UNTERSCHIEDLICH - Diagnose: sudo tcpdump -ni ${iface} tcp port ${port})"
  if [[ -n "$ip" ]] && ufw status 2>/dev/null | grep -E "(^|[^0-9])${port}/tcp" | grep -F "$iface" | grep -qF "$ip"; then
    ok "Restriktive Regel vorhanden: nur ${ip} ueber ${iface}."
  else
    warn "Keine korrekte restriktive Regel gefunden (nur ${ip:-<Hub-IP>} ueber ${iface})."
    [[ -n "$ip" ]] && yesno "Restriktive Regel jetzt (neu) setzen?" "y" && beszel_apply_ufw_rule "$iface" "$ip" "$port"
  fi
  echo
  beszel_remove_public_exposure "$port" "$iface"
  local left; left="$(beszel_public_exposure "$port")"
  [[ -z "$left" ]] && ok "Keine oeffentliche Freigabe fuer Port ${port} (mehr) vorhanden."
}

beszel_logs() {
  need_root
  if ! beszel_installed; then warn "Beszel Agent ist NICHT installiert."; return 1; fi
  section "Beszel Agent Logs"
  local mode="${1:-tail}"
  case "$mode" in
    -f|follow|live) journalctl -u beszel-agent -f --no-pager 2>&1 | mask_secrets ;;
    *) journalctl -u beszel-agent -n 200 --no-pager 2>&1 | mask_secrets ;;
  esac
}

beszel_restart() {
  need_root
  if ! beszel_installed; then err "Beszel Agent ist NICHT installiert."; return 1; fi
  section "Beszel Agent neu starten"
  systemctl restart beszel-agent && ok "Neu gestartet." || err "Neustart fehlgeschlagen."
  sleep 1
  systemctl status beszel-agent --no-pager 2>&1 | mask_secrets | sed -n '1,10p' || true
}

beszel_update() {
  need_root; load_env
  section "Beszel Agent aktualisieren"
  if ! beszel_installed; then err "Beszel Agent ist NICHT installiert (zuerst installieren)."; return 1; fi
  local ver_before; ver_before="$(beszel_version)"
  info "Aktuelle Version: ${ver_before}"
  # Atomar herunterladen und ersetzen (kein Restart, wenn Download fehlschlaegt).
  beszel_download_binary || return 1
  systemctl restart beszel-agent && ok "Neu gestartet." || warn "Neustart nicht erfolgreich."
  local ver_after; ver_after="$(beszel_version)"
  info "Neue Version:     ${ver_after}"
}

beszel_uninstall() {
  need_root; load_env; load_beszel_config
  section "Beszel Agent deinstallieren"
  if ! beszel_installed && [[ ! -f "$BESZEL_UNIT" && ! -f "$BESZEL_ENV" ]]; then
    warn "Beszel Agent ist nicht installiert - nichts zu tun."
    return 0
  fi
  if ! yesno "Beszel Agent wirklich deinstallieren?" "n"; then warn "Abgebrochen."; return 0; fi
  # Gespeicherte Werte fuer die gezielte Regel-Entfernung merken (VOR dem
  # Loeschen der env-Datei einlesen).
  local iface="${BESZEL_WG_IFACE:-${WG_IF:-wg0}}" ip="${BESZEL_HUB_WG_IP:-}" port="${BESZEL_AGENT_PORT:-$BESZEL_PORT_DEFAULT}"
  # Dienst stoppen/deaktivieren.
  systemctl stop beszel-agent 2>/dev/null || true
  systemctl disable beszel-agent 2>/dev/null || true
  # Unit entfernen.
  if [[ -f "$BESZEL_UNIT" ]]; then rm -f "$BESZEL_UNIT"; systemctl daemon-reload; ok "systemd-Unit entfernt."; fi
  # Binary optional entfernen.
  if [[ -x "$BESZEL_BIN" ]] && yesno "Binary ${BESZEL_BIN} entfernen?" "y"; then rm -f "$BESZEL_BIN"; ok "Binary entfernt."; fi
  # env-Datei optional entfernen.
  if [[ -f "$BESZEL_ENV" ]] && yesno "Konfigurationsdatei ${BESZEL_ENV} entfernen (enthaelt Secrets)?" "y"; then rm -f "$BESZEL_ENV"; ok "Konfig entfernt."; fi
  # UFW-Regel optional entfernen - GENAU die restriktive Regel anhand der
  # gespeicherten Werte (iface/ip/port). KEINE anderen Regeln anfassen.
  if command -v ufw >/dev/null 2>&1 && [[ -n "$ip" ]]; then
    if ufw status 2>/dev/null | grep -E "(^|[^0-9])${port}/tcp" | grep -F "$iface" | grep -qF "$ip"; then
      if yesno "UFW-Regel 'allow in on ${iface} from ${ip} to any port ${port}/tcp' entfernen?" "y"; then
        beszel_remove_ufw_rule "$iface" "$ip" "$port"
        ufw reload >/dev/null 2>&1 || true
        ok "UFW-Regel entfernt."
      fi
    fi
  fi
  ok "Beszel Agent deinstalliert."
}


# ------------------------------------------------------------
# Backup / Restore
# ------------------------------------------------------------
BACKUP_DIR="${EDGE_DIR}/backups"

backup_create() {
  need_root
  load_env
  section "Backup erstellen"
  # Vor dem Backup pruefen, ob services.tsv valide ist (sonst defekter Stand).
  # Im auto-Modus (z. B. Pre-Restore-Backup) ohne Rueckfrage durchziehen.
  if [[ -s "$SERVICES_FILE" ]] && ! validate_services_file >/dev/null 2>&1; then
    warn "services.tsv ist fehlerhaft. Dieses Backup wuerde einen defekten Stand enthalten."
    if [[ "${BACKUP_BEHAVIOR:-ask}" != "auto" ]]; then
      if ! yesno "Backup trotzdem erstellen?" "n"; then
        warn "Abgebrochen. Tipp: sudo homeedge repair-services"
        return 1
      fi
    fi
  fi
  mkdir -p "$BACKUP_DIR"
  local ts backup_file manifest_file tmp_manifest
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_file="${BACKUP_DIR}/edge-backup-${ts}.tar.gz"
  tmp_manifest="$(mktemp)"

  cat > "$tmp_manifest" <<EOF
HomeEdge Backup
Erstellt: $(date -Is)
Hostname: $(hostname)
VPS: ${VPS_PUBLIC_HOST:-unbekannt}
WG Interface: ${WG_IF:-unbekannt}
Hinweis: Dieses Backup enthaelt Secrets wie WireGuard-Keys und Cloudflare Token.
EOF

  local items=()
  [[ -d /etc/homeedge ]] && items+=("etc/homeedge")   # enthaelt auch beszel.env falls vorhanden
  [[ -d /etc/wireguard ]] && items+=("etc/wireguard")
  # Beszel-systemd-Unit (falls installiert) mitsichern - Binary NICHT (kann via
  # sudo homeedge beszel-install/beszel-update wieder geholt werden).
  [[ -f /etc/systemd/system/beszel-agent.service ]] && items+=("etc/systemd/system/beszel-agent.service")
  # Caddy-Dateien EINZELN pruefen - ein halb erstellter Stack (z. B. ohne
  # docker-compose.yml) darf das Backup nicht crashen lassen (Bug P1).
  local caddy_complete=1 cf
  for cf in Caddyfile Dockerfile docker-compose.yml .env; do
    if [[ -f "/opt/caddy-edge/${cf}" ]]; then items+=("opt/caddy-edge/${cf}"); else caddy_complete=0; fi
  done
  [[ -d /opt/caddy-edge/data ]] && items+=("opt/caddy-edge/data")
  [[ -d /opt/caddy-edge/config ]] && items+=("opt/caddy-edge/config")
  if [[ -d /opt/caddy-edge && "$caddy_complete" -eq 0 ]]; then
    warn "Caddy-Stack ist unvollstaendig - es werden nur die vorhandenen Dateien gesichert."
    warn "Reparatur nach dem Backup: sudo homeedge caddy-rebuild"
  fi
  [[ -f /etc/fail2ban/jail.d/sshd-local.conf ]] && items+=("etc/fail2ban/jail.d/sshd-local.conf")
  [[ -f /etc/fail2ban/jail.d/caddy-auth.local ]] && items+=("etc/fail2ban/jail.d/caddy-auth.local")
  [[ -f /etc/fail2ban/filter.d/caddy-auth.conf ]] && items+=("etc/fail2ban/filter.d/caddy-auth.conf")
  [[ -f /etc/apt/apt.conf.d/20auto-upgrades ]] && items+=("etc/apt/apt.conf.d/20auto-upgrades")
  [[ -f /etc/ufw/user.rules ]] && items+=("etc/ufw/user.rules")
  [[ -f /etc/ufw/user6.rules ]] && items+=("etc/ufw/user6.rules")
  [[ -f /usr/local/bin/homeedge ]] && items+=("usr/local/bin/homeedge")

  if (( ${#items[@]} == 0 )); then
    err "Keine passenden Dateien fuer Backup gefunden."
    rm -f "$tmp_manifest"
    return 1
  fi

  tar -czf "$backup_file" -C / "${items[@]}" -C "$(dirname "$tmp_manifest")" "$(basename "$tmp_manifest")"
  chmod 600 "$backup_file"
  rm -f "$tmp_manifest"

  ok "Backup erstellt: $backup_file"
  warn "Backup enthaelt Secrets. Nicht unverschluesselt teilen."
  echo
  ls -lh "$backup_file"
}

backup_list() {
  section "Backups anzeigen"
  mkdir -p "$BACKUP_DIR"
  if ! ls -1 "$BACKUP_DIR"/edge-backup-*.tar.gz >/dev/null 2>&1; then
    warn "Keine Backups gefunden in $BACKUP_DIR"
    return 0
  fi
  local i=1 f
  for f in "$BACKUP_DIR"/edge-backup-*.tar.gz; do
    printf '  %b%2d%b) %s  (%s)\n' "$C_GREEN" "$i" "$C_RESET" "$(basename "$f")" "$(du -h "$f" | awk '{print $1}')"
    i=$((i+1))
  done
}

backup_select_file() {
  mkdir -p "$BACKUP_DIR"
  mapfile -t backups < <(ls -1t "$BACKUP_DIR"/edge-backup-*.tar.gz 2>/dev/null || true)
  if (( ${#backups[@]} == 0 )); then
    err "Keine Backups gefunden."
    return 1
  fi
  local i choice
  for i in "${!backups[@]}"; do
    printf '  %b%2d%b) %s  (%s)\n' "$C_GREEN" "$((i+1))" "$C_RESET" "$(basename "${backups[$i]}")" "$(du -h "${backups[$i]}" | awk '{print $1}')"
  done
  echo
  choice="$(ask "Backup Nummer waehlen, 0 = Abbruch" "1")"
  [[ "$choice" =~ ^[0-9]+$ ]] || { err "Ungueltige Eingabe."; return 1; }
  (( choice == 0 )) && return 1
  if (( choice < 1 || choice > ${#backups[@]} )); then err "Ungueltige Nummer."; return 1; fi
  printf '%s\n' "${backups[$((choice-1))]}"
}

backup_show_content() {
  section "Backup Inhalt anzeigen"
  local f
  f="$(backup_select_file)" || return 0
  echo
  info "Inhalt von: $f"
  tar -tzf "$f" | sed -n '1,120p'
  local total
  total="$(tar -tzf "$f" | wc -l)"
  echo
  info "Eintraege gesamt: $total"
}

# Gemeinsame, atomare Restore-Routine. $1 = Backup-Datei, $2 = mode (full|config).
_do_restore() {
  local f="$1" mode="$2"
  # 0) Pflichtdateien im Backup pruefen BEVOR irgendetwas veraendert wird.
  local listing; listing="$(tar -tzf "$f" 2>/dev/null || true)"
  local miss=0
  grep -qE '(^|/)etc/homeedge/services\.tsv$' <<<"$listing" || { err "Backup enthaelt keine etc/homeedge/services.tsv"; miss=1; }
  grep -qE '(^|/)etc/homeedge/homeedge\.env$' <<<"$listing" || { err "Backup enthaelt keine etc/homeedge/homeedge.env"; miss=1; }
  if (( miss )); then
    err "Backup ist unvollstaendig. Restore abgebrochen (nichts veraendert)."
    return 1
  fi
  # Caddyfile/.env sind optional - werden bei Bedarf aus services.tsv/env neu erzeugt.
  grep -qE '(^|/)opt/caddy-edge/Caddyfile$' <<<"$listing" || info "Kein Caddyfile im Backup - wird aus services.tsv neu generiert."
  grep -qE '(^|/)opt/caddy-edge/\.env$' <<<"$listing" || info "Keine Caddy-.env im Backup - wird aus homeedge.env neu erzeugt."

  # 1) Pre-Restore-Backup des aktuellen Zustands.
  info "Erstelle Pre-Restore-Backup des aktuellen Zustands..."
  BACKUP_BEHAVIOR=auto backup_create >/dev/null 2>&1 || warn "Pre-Restore-Backup unvollstaendig (fahre fort)."

  info "Dienste werden kurz gestoppt..."
  load_env || true
  systemctl stop "wg-quick@${WG_IF:-unifi}" 2>/dev/null || true

  # 2) Entpacken. Bei config-Modus die Software (Binary) NIEMALS ueberschreiben.
  #    KEIN Fallback ohne --exclude: schlaegt der Restore mit Exclude fehl, wird
  #    abgebrochen, damit nicht doch /usr/local/bin/homeedge ueberschrieben wird.
  if [[ "$mode" == "config" ]]; then
    if ! tar -xzf "$f" -C / --exclude='usr/local/bin/homeedge'; then
      err "Restore (config) fehlgeschlagen. Es wird NICHT ohne --exclude erneut entpackt."
      err "Die installierte HomeEdge-Version bleibt unveraendert. Backup pruefen: $f"
      return 1
    fi
  else
    if ! tar -xzf "$f" -C /; then
      err "Restore (full) fehlgeschlagen. Backup pruefen: $f"
      return 1
    fi
  fi

  # 3) Rechte/Token/Symlink.
  repair_env_file || true
  chmod 600 /etc/homeedge/homeedge.env 2>/dev/null || true
  chmod 600 /etc/wireguard/*.conf /etc/wireguard/*.template 2>/dev/null || true
  if [[ "$mode" == "full" && -f /usr/local/bin/homeedge ]]; then
    chmod +x /usr/local/bin/homeedge 2>/dev/null || true
    ln -sf /usr/local/bin/homeedge /usr/local/bin/edgectl 2>/dev/null || true
  fi

  load_env || true

  # 4) services.tsv validieren - bei Defekt Reparatur versuchen.
  if ! validate_services_file; then
    warn "Wiederhergestellte services.tsv ist ungueltig - versuche automatische Reparatur..."
    repair_services || true
  fi
  if ! validate_services_file; then
    err "Restore unvollstaendig: services.tsv weiterhin defekt. Bitte: sudo homeedge repair-services"
    return 1
  fi
  ok "services.tsv valide."

  # 5) Caddyfile neu generieren + validieren + reload (blockiert bei Fehler).
  # Das Image wird NICHT mitgesichert - nach Restore ggf. einmalig bauen.
  if command -v docker >/dev/null 2>&1; then
    caddy_ensure_image || { err "Caddy-Image konnte nicht gebaut werden - bitte: sudo homeedge caddy-rebuild"; return 1; }
    reload_caddy || { err "Caddy-Reload fehlgeschlagen - bitte pruefen."; return 1; }
  fi
  # 6) Fail2ban (mit Config-Test), WireGuard, UFW.
  command -v fail2ban-client >/dev/null 2>&1 && install_fail2ban || true
  restart_wg || true
  ufw_apply_auto || true

  ok "Restore (${mode}) abgeschlossen."
  echo
  info "Abschluss-Healthcheck:"
  health_check || true
  return 0
}

backup_restore() {
  need_root
  section "Komplettes Restore (Software + Config)"
  local f; f="$(backup_select_file)" || return 0
  echo
  tar -tzf "$f" 2>/dev/null | sed -n '1,40p'
  echo
  warn "Achtung: Restore ueberschreibt aktuelle Konfiguration UND HomeEdge-Software."
  if ! yesno "Fortfahren?" "n"; then warn "Abgebrochen."; return 0; fi
  _do_restore "$f" full
}

restore_config() {
  need_root
  section "Config Restore (nur Konfiguration)"
  local f; f="$(backup_select_file)" || return 0
  echo
  warn "Achtung: Restore ueberschreibt aktuelle Konfiguration. HomeEdge-Software bleibt unveraendert."
  if ! yesno "Fortfahren?" "n"; then warn "Abgebrochen."; return 0; fi
  _do_restore "$f" config
}

backup_delete() {
  need_root
  section "Backup loeschen"
  local f
  f="$(backup_select_file)" || return 0
  warn "Loesche: $f"
  if yesno "Wirklich loeschen?" "n"; then
    rm -f "$f"
    ok "Backup geloescht."
  fi
}

backup_export_to_path() {
  need_root
  section "Backup exportieren/kopieren"
  local f dest
  f="$(backup_select_file)" || return 0
  dest="$(ask "Zielpfad, z.B. /root/edge-backup.tar.gz" "/root/$(basename "$f")")"
  cp -a "$f" "$dest"
  chmod 600 "$dest" 2>/dev/null || true
  ok "Kopiert nach: $dest"
  warn "Datei enthaelt Secrets. Sicher speichern."
}


# ------------------------------------------------------------
# Netzwerk / Interfaces
# ------------------------------------------------------------
default_interface() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}'
}

default_source_ip() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}'
}

interface_ipv4s() {
  local ifn="$1"
  ip -o -4 addr show dev "$ifn" scope global 2>/dev/null | awk '{print $4}' | paste -sd ', ' -
}

interface_ipv6s() {
  local ifn="$1"
  ip -o -6 addr show dev "$ifn" scope global 2>/dev/null | awk '{print $4}' | paste -sd ', ' -
}

interface_state() {
  local ifn="$1"
  cat "/sys/class/net/${ifn}/operstate" 2>/dev/null || echo "unknown"
}

show_network_interfaces() {
  load_env
  section "Netzwerkadapter"
  local def src ifn state ipv4 ipv6 mark
  def="$(default_interface)"
  src="$(default_source_ip)"
  printf '%-4s %-16s %-10s %-24s %s\n' "Nr" "Interface" "Status" "IPv4" "IPv6"
  line
  local n=1
  while read -r ifn; do
    [[ -z "$ifn" ]] && continue
    state="$(interface_state "$ifn")"
    ipv4="$(interface_ipv4s "$ifn")"; [[ -z "$ipv4" ]] && ipv4="-"
    ipv6="$(interface_ipv6s "$ifn")"; [[ -z "$ipv6" ]] && ipv6="-"
    mark=""
    [[ "$ifn" == "$def" ]] && mark="  < default route"
    [[ "$ifn" == "$EXT_IF" ]] && mark="${mark}  < HomeEdge EXT_IF"
    printf '%-4s %-16s %-10s %-24s %s%s\n' "$n" "$ifn" "$state" "$ipv4" "$ipv6" "$mark"
    n=$((n+1))
  done < <(ls /sys/class/net | sort)
  echo
  echo "Default-Route:"
  ip route show default 2>/dev/null || true
  echo
  echo "Route-Test ins Internet:"
  ip route get 1.1.1.1 2>/dev/null || true
  echo
  printf 'Aktuelles HomeEdge EXT_IF: %s\n' "${EXT_IF:-<leer>}"
  printf 'Automatisch erkannt:      %s%s\n' "${def:-<keins>}" "$([[ -n "$src" ]] && echo " / Source-IP ${src}" || true)"
}

select_ext_interface() {
  load_env
  section "Externes Interface auswaehlen"
  local def ifn state ipv4 ipv6 selected
  def="$(default_interface)"
  mapfile -t ifaces < <(ls /sys/class/net | grep -v '^lo$' | sort)
  if (( ${#ifaces[@]} == 0 )); then
    err "Keine Netzwerkadapter gefunden."
    return 1
  fi
  printf '%-4s %-16s %-10s %-24s %s\n' "Nr" "Interface" "Status" "IPv4" "Hinweis"
  line
  local i=1
  for ifn in "${ifaces[@]}"; do
    state="$(interface_state "$ifn")"
    ipv4="$(interface_ipv4s "$ifn")"; [[ -z "$ipv4" ]] && ipv4="-"
    local hint=""
    [[ "$ifn" == "$def" ]] && hint="Default-Route"
    [[ "$ifn" == "$EXT_IF" ]] && hint="${hint} aktuell"
    printf '%-4s %-16s %-10s %-24s %s\n' "$i" "$ifn" "$state" "$ipv4" "$hint"
    i=$((i+1))
  done
  echo
  echo "Empfehlung: Nimm das Interface mit 'Default-Route'."
  selected="$(ask "Nummer waehlen oder Interface-Name eingeben" "$([[ -n "$def" ]] && echo "$def" || echo "${ifaces[0]}")")"
  if [[ "$selected" =~ ^[0-9]+$ ]]; then
    local idx=$((selected-1))
    if (( idx < 0 || idx >= ${#ifaces[@]} )); then err "Ungueltige Nummer."; return 1; fi
    EXT_IF="${ifaces[$idx]}"
  else
    if [[ ! -e "/sys/class/net/${selected}" ]]; then err "Interface '${selected}' existiert nicht."; return 1; fi
    EXT_IF="$selected"
  fi
  save_env
  ok "Externes Interface gespeichert: ${EXT_IF}"
}


apply_all() {
  need_root
  # load_env setzt ALLE Defaults (ENABLE_IPV6=0, ENABLE_HTTP3=0, WG_MTU=, SSH_PORT=22,
  # WG_PORT=51821, ...), damit nachfolgende Schritte nie auf unset-Variablen laufen.
  load_env
  section "apply-all: Preflight"

  # --- A) Preflight: nichts veraendern, nur pruefen/reparieren. ---
  local -a pf=()
  # services.tsv: leer = ok. Sonst 4->5 migrieren, dann ggf. reparieren.
  if [[ -s "$SERVICES_FILE" ]]; then
    migrate_services_4to5 || true
    if ! validate_services_file >/dev/null 2>&1; then
      warn "services.tsv ungueltig - versuche automatische Reparatur..."
      repair_services --non-interactive >/dev/null 2>&1 || true
    fi
    if ! validate_services_file >/dev/null 2>&1; then
      pf+=("services.tsv ungueltig  ->  sudo homeedge repair-services")
    else
      ok "services.tsv valide"
    fi
  else
    ok "services.tsv leer (keine Dienste) - ok"
  fi
  # WireGuard-Pflichtwerte.
  [[ -n "${WG_IF:-}" && -n "${WG_PORT:-}" && -n "${VPS_WG_ADDR:-}" ]] || pf+=("WireGuard-Basiswerte fehlen (WG_IF/WG_PORT/VPS_WG_ADDR)  ->  sudo homeedge settings")
  # Docker vorhanden (Caddy-Stack braucht Docker).
  command -v docker >/dev/null 2>&1 || pf+=("Docker ist nicht installiert/erreichbar")
  # Cloudflare Token noetig, sobald Dienste konfiguriert sind (DNS-01).
  if [[ -s "$SERVICES_FILE" && -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    pf+=("Cloudflare API Token fehlt (fuer Zertifikate noetig)  ->  sudo homeedge set-token")
  fi
  if (( ${#pf[@]} > 0 )); then
    section "apply-all: ABBRUCH (Preflight fehlgeschlagen)"
    err "Es wird NICHTS veraendert. Folgende Punkte zuerst beheben:"
    local p; for p in "${pf[@]}"; do printf '  %b-%b %s\n' "$C_RED" "$C_RESET" "$p"; done
    echo
    err "Reparatur:"
    printf '  %s\n' "sudo homeedge migrate" "sudo homeedge repair-services" "sudo homeedge apply-all" "sudo homeedge health"
    return 1
  fi
  ok "Preflight ok"

  # --- B) Apply ---
  section "apply-all: Apply"
  local rc=0 caddy_ok=1
  generate_keys || rc=1
  write_wg_config || rc=1
  # Dienst-Werte sind optional (haengen an services.tsv) - kein Apply-Blocker.
  write_unifi_values || true
  # Erstinstallation: Image einmalig bauen, falls es fehlt. Danach laedt reload
  # nur noch neu (baut nie). Bei Build-Fehler wird kein Reload versucht.
  if caddy_ensure_image; then
    if reload_caddy; then ok "Caddy angewendet"; else err "Caddy Apply fehlgeschlagen"; caddy_ok=0; rc=1; fi
  else
    err "Caddy-Image konnte nicht gebaut werden - Caddy nicht angewendet."
    caddy_ok=0; rc=1
  fi
  install_fail2ban || rc=1
  # WG ist evtl. noch nicht aktivierbar (UniFi PublicKey fehlt) - nicht fatal.
  restart_wg || true
  # UFW muss am Ende wirklich AKTIV sein (mit SSH-Lockout-Schutz), sonst Fehler.
  ufw_ensure_active || rc=1
  if (( rc != 0 )); then
    echo
    err "apply-all nicht vollstaendig erfolgreich."
    (( caddy_ok == 0 )) && err "Caddy konnte nicht angewendet werden - Details: sudo homeedge caddy-logs ; sudo homeedge health"
    info "Reparatur: sudo homeedge caddy-rebuild ; sudo homeedge health"
  else
    ok "apply-all vollstaendig erfolgreich."
  fi
  return $rc
}

# ------------------------------------------------------------
# Wizard-/Apply-Abschluss: Verifikation
# Prueft, ob HomeEdge nach Setup/Apply wirklich vollstaendig funktionsfaehig ist.
# Respektiert MIGRATION_MODE (Parallelbetrieb): DNS auf altem VPS = WARN, nicht ROT.
# Caddy holt Zertifikate per DNS-01 und startet daher auch, wenn A/AAAA noch auf
# den alten VPS zeigen. 0 = alles Kritische ok, 1 = mindestens ein harter Fehler.
# Aufruf: verify_setup [--migration]
# ------------------------------------------------------------
verify_setup() {
  need_root; load_env
  [[ "${1:-}" == "--migration" ]] && MIGRATION_MODE=1
  section "Wizard-Abschluss: Verifikation"
  local fail=0 warns=0
  local -a problems=()
  local mig="${MIGRATION_MODE:-0}"
  [[ "$mig" == "1" ]] && info "MIGRATION_MODE=1: DNS darf noch auf den alten VPS zeigen (WARN, kein Fehler)."

  # services.tsv valide
  if validate_services_file >/dev/null 2>&1; then ok "services.tsv valide"
  else err "services.tsv ungueltig"; problems+=("services.tsv ungueltig  ->  sudo homeedge repair-services"); fail=1; fi

  # Caddy-Stack vollstaendig pruefen: Verzeichnis, Caddyfile, .env, Compose-Datei,
  # Compose-Config und Container-Zustand (Bug P1: Wizard darf nicht ohne Stack
  # "fertig" melden).
  local stack; stack="$(caddy_stack_state)"
  case "$stack" in
    dir_missing)       err "Caddy Verzeichnis fehlt: $CADDY_DIR"; problems+=("Caddy Stack fehlt  ->  sudo homeedge apply-all  oder  sudo homeedge caddy-rebuild"); fail=1 ;;
    caddyfile_missing)
      if [[ -f "${CADDY_DIR}/Caddyfile.failed" ]]; then
        err "Caddyfile wurde nicht aktiviert, weil die neu generierte Caddyfile ungueltig war."
        info "Details: ${CADDY_VALIDATE_LOG}"
        info "Fehlerhafte Datei: ${CADDY_DIR}/Caddyfile.failed"
        problems+=("Caddyfile ungueltig (siehe ${CADDY_VALIDATE_LOG})  ->  sudo homeedge caddy-rebuild ; sudo homeedge diagnose")
      else
        err "Caddyfile fehlt: ${CADDY_DIR}/Caddyfile"
        problems+=("Caddyfile fehlt  ->  sudo homeedge caddy-rebuild")
      fi
      fail=1 ;;
    env_missing)       err "Caddy .env fehlt: ${CADDY_DIR}/.env"; problems+=(".env fehlt  ->  sudo homeedge caddy-rebuild"); fail=1 ;;
    compose_missing)   err "Caddy Docker Compose Datei fehlt: $CADDY_COMPOSE_FILE"; problems+=("Compose-Datei fehlt  ->  sudo homeedge caddy-rebuild"); fail=1 ;;
    compose_invalid)   err "docker compose config ungueltig (${CADDY_COMPOSE_FILE})"; problems+=("Compose ungueltig  ->  sudo homeedge caddy-rebuild"); fail=1 ;;
    no_container)      err "Caddy Container existiert nicht"; problems+=("Container fehlt  ->  sudo homeedge apply-all"); fail=1 ;;
    restarting)        err "Caddy Container im Restarting-Zustand (Crash-Loop)"; problems+=("Caddy crasht  ->  sudo homeedge restart; sudo homeedge caddy-logs"); fail=1 ;;
    exited)            err "Caddy Container ist exited (gestoppt)"; problems+=("Caddy gestoppt  ->  sudo homeedge restart"); fail=1 ;;
    running)
      ok "Caddy Stack vollstaendig (Verzeichnis, Caddyfile, .env, docker-compose.yml)"
      ok "Caddy Container laeuft (running=true, restarting=false)"
      if validate_caddyfile; then ok "Caddyfile validate OK"
      else err "Caddyfile validate fehlgeschlagen"; problems+=("Caddyfile ungueltig  ->  sudo homeedge reload"); fail=1; fi ;;
  esac

  # UFW aktiv
  local ufw_out; ufw_out="$(ufw status 2>/dev/null || true)"
  if grep -qiE "Status: (active|aktiv)" <<<"$ufw_out"; then ok "UFW aktiv"
  else err "UFW nicht aktiv"; problems+=("UFW inaktiv  ->  sudo homeedge firewall"); fail=1; fi

  # 443/tcp erlaubt
  if grep -qE "(^|[[:space:]])443/tcp" <<<"$ufw_out"; then ok "443/tcp erlaubt"
  else err "443/tcp nicht freigegeben"; problems+=("443/tcp fehlt  ->  sudo homeedge firewall"); fail=1; fi

  # WG-Port udp erlaubt
  if grep -qE "(^|[[:space:]])${WG_PORT}/udp" <<<"$ufw_out"; then ok "WireGuard ${WG_PORT}/udp erlaubt"
  else err "${WG_PORT}/udp nicht freigegeben"; problems+=("${WG_PORT}/udp fehlt  ->  sudo homeedge firewall"); fail=1; fi

  # Fail2ban aktiv
  if systemctl is-active --quiet fail2ban 2>/dev/null; then ok "Fail2ban aktiv"
  else err "Fail2ban nicht aktiv"; problems+=("Fail2ban inaktiv  ->  sudo systemctl restart fail2ban"); fail=1; fi

  # caddy-auth Jail vorhanden, wenn aktiviert
  if [[ "${CADDY_FAIL2BAN}" == "1" ]]; then
    if fail2ban-client status caddy-auth >/dev/null 2>&1; then ok "caddy-auth Jail vorhanden"
    else err "caddy-auth aktiviert, aber Jail fehlt"; problems+=("caddy-auth Jail fehlt  ->  sudo homeedge fail2ban"); fail=1; fi
  fi

  # WireGuard Interface vorhanden
  if ip link show "$WG_IF" >/dev/null 2>&1; then ok "WireGuard Interface ${WG_IF} vorhanden"
  elif [[ -n "${CLIENT_PUBLIC_KEY:-}" ]]; then
    err "WireGuard Interface ${WG_IF} fehlt"; problems+=("WG Interface fehlt  ->  sudo systemctl restart wg-quick@${WG_IF}"); fail=1
  else
    warn "WireGuard Interface ${WG_IF} noch nicht aktiv (UniFi/Client PublicKey fehlt - im Parallelbetrieb ok)"; warns=$((warns+1))
  fi

  # Lokaler SNI-Test pro Domain + DNS-Bewertung (MIGRATION_MODE-aware).
  # Zertifikate werden per DNS-01 geholt - das funktioniert auch im Parallel-
  # betrieb mit altem DNS. Ein dauerhaft fehlendes Zertifikat ist daher ein
  # echter Fehler (z. B. falscher Cloudflare Token) und KEIN reiner Migrations-
  # zustand -> harter Fehler (Bug P2: Zertifikatsstatus ernst nehmen).
  if [[ -s "$SERVICES_FILE" ]] && validate_services_file >/dev/null 2>&1; then
    local domain scheme ip port profile a expect="${VPS_PUBLIC_HOST:-}" deadline pending
    local caddy_up=0; [[ "$stack" == "running" ]] && caddy_up=1
    # Fall A: ohne laufenden Caddy/ohne Caddyfile ist ein SNI-Test nicht moeglich.
    if (( caddy_up == 0 )); then
      err "Lokaler SNI-Test nicht moeglich, weil Caddy nicht laeuft oder Caddyfile fehlt."
      info "Zuerst Caddy reparieren: sudo homeedge caddy-rebuild"
    elif command -v openssl >/dev/null 2>&1; then
      # Kurze Schonfrist (reload hat bereits bis 120s gewartet).
      deadline=$((SECONDS+45))
      while :; do
        pending=0
        while IFS=$'\t' read -r domain scheme ip port profile || [[ -n "$domain" ]]; do
          [[ -z "$domain" ]] && continue
          cert_ready "$domain" || pending=$((pending+1))
        done < "$SERVICES_FILE"
        (( pending == 0 )) && break
        (( SECONDS >= deadline )) && break
        sleep 5
      done
    fi
    while IFS=$'\t' read -r domain scheme ip port profile || [[ -n "$domain" ]]; do
      [[ -z "$domain" ]] && continue
      # Lokaler SNI/TLS-Test: curl --resolve DOMAIN:443:127.0.0.1 https://DOMAIN
      if (( caddy_up == 0 )); then
        : # Fall A bereits oben gemeldet (Stack-Fehler ist der harte Fehler).
      elif cert_ready "$domain"; then
        ok "SNI/TLS lokal ok (Zertifikat aktiv): ${domain}"
      else
        # Fall B: Caddy laeuft, aber Zertifikat/TLS fehlt -> Token/DNS-01 pruefen.
        err "Lokaler SNI-Test fehlgeschlagen fuer ${domain}: Caddy laeuft, aber kein Zertifikat/TLS."
        problems+=("Zertifikat fehlt fuer ${domain}  ->  Cloudflare Token / DNS-01 pruefen (sudo homeedge set-token), dann: sudo homeedge reload ; Test: sudo homeedge test-domain ${domain}")
        fail=1
      fi
      # DNS-Bewertung (nur DNS-Ziel ist migrations-tolerant, nicht das Zertifikat)
      a="$(dig +short A "$domain" 2>/dev/null | tail -n1 || true)"
      if [[ "$mig" == "1" ]]; then
        if [[ -z "$a" ]]; then info "DNS ${domain}: kein A-Record (Parallelbetrieb)"
        elif [[ -n "$expect" ]] && _is_ip "$expect" && [[ "$a" != "$expect" ]]; then warn "DNS ${domain} -> ${a} zeigt noch auf alten VPS (bewusst, MIGRATION_MODE=1)"; warns=$((warns+1))
        else ok "DNS ${domain} -> ${a:-?}"; fi
      else
        if [[ -z "$a" ]]; then err "DNS ${domain}: kein A-Record"; problems+=("DNS ${domain} fehlt  ->  A-Record auf diesen VPS setzen oder MIGRATION_MODE=1"); fail=1
        elif _is_ip "$expect" && [[ "$a" != "$expect" ]]; then err "DNS ${domain} -> ${a}, erwartet ${expect}"; problems+=("DNS ${domain} zeigt nicht auf diesen VPS  ->  A-Record korrigieren oder MIGRATION_MODE=1"); fail=1
        else ok "DNS ${domain} -> ${a}"; fi
      fi
    done < "$SERVICES_FILE"
  else
    info "Keine gueltigen Dienste eingetragen - SNI/DNS-Test uebersprungen."
  fi

  section "Ergebnis"
  if (( fail )); then
    err "Setup NICHT vollstaendig erfolgreich - bitte folgende Punkte beheben:"
    local p; for p in "${problems[@]}"; do printf '  %b-%b %s\n' "$C_RED" "$C_RESET" "$p"; done
    echo
    err "Allgemeine Diagnose: sudo homeedge health   und   sudo homeedge diagnose"
    err "Nach der Reparatur erneut pruefen: sudo homeedge verify-setup"
    return 1
  fi
  if (( warns )); then
    warn "Setup funktionsfaehig. ${warns} Hinweis(e) (z. B. DNS-Migration laeuft noch oder Zertifikate werden gerade ausgestellt)."
  else
    ok "Setup vollstaendig erfolgreich und funktionsfaehig."
  fi
  return 0
}

# ------------------------------------------------------------
# Ampel / Health checks
# ------------------------------------------------------------
HEALTH_RED=0
HEALTH_YELLOW=0
HEALTH_GREEN=0

_health_line() {
  local state="$1" title="$2" msg="${3:-}"
  case "$state" in
    green) HEALTH_GREEN=$((HEALTH_GREEN+1)); printf '%b%-8s%b %-32s %s\n' "$C_GREEN" "[GRUEN]" "$C_RESET" "$title" "$msg" ;;
    yellow) HEALTH_YELLOW=$((HEALTH_YELLOW+1)); printf '%b%-8s%b %-32s %s\n' "$C_YELLOW" "[GELB]" "$C_RESET" "$title" "$msg" ;;
    red) HEALTH_RED=$((HEALTH_RED+1)); printf '%b%-8s%b %-32s %s\n' "$C_RED" "[ROT]" "$C_RESET" "$title" "$msg" ;;
    *) printf '%-8s %-32s %s\n' "[INFO]" "$title" "$msg" ;;
  esac
}

_is_ip() { [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

_tls_check_one() {
  local domain="$1" tmp code rc detail certfile
  tmp="$(mktemp)"
  code="000"
  rc=0
  code="$(curl -sS -I --connect-timeout 10 --max-time 20 --resolve "${domain}:443:127.0.0.1" -o /dev/null -w '%{http_code}' "https://${domain}" 2>"$tmp")" || rc=$?
  if [[ "$rc" -eq 0 && "$code" != "000" ]]; then
    _health_line green "TLS ${domain}" "Zertifikat ok, HTTP ${code}"
  elif ! caddy_is_running; then
    detail="$(tr '\n' ' ' < "$tmp" | cut -c1-140)"
    _health_line red "TLS ${domain}" "Lokaler SNI-Test nicht moeglich: Caddy laeuft nicht (${detail:-kein TLS})"
  elif caddy_acme_error_for_domain "$domain"; then
    # Caddy laeuft, aber die Logs zeigen einen echten ACME-Fehler -> ROT.
    _health_line red "TLS ${domain}" "ACME-/Zertifikatsfehler in den Logs - Cloudflare Token/DNS-01 pruefen (sudo homeedge caddy-logs)"
  else
    # Caddy laeuft, kein Fehler im Log -> Zertifikat wird per DNS-01 noch geholt: GELB.
    _health_line yellow "TLS ${domain}" "Zertifikat wird noch angefordert / ausstehend (DNS-01 kann dauern)"
  fi
  rm -f "$tmp"

  if command -v openssl >/dev/null 2>&1; then
    detail="$(echo | openssl s_client -servername "$domain" -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -issuer -subject -dates 2>/dev/null | tr '\n' '; ' | sed 's/; $//')"
    [[ -n "$detail" ]] && printf '          %s\n' "$detail"
  fi
}

check_certs() {
  load_env
  section "Zertifikate pruefen"
  if [[ ! -f "$SERVICES_FILE" || ! -s "$SERVICES_FILE" ]]; then
    warn "Keine Dienste vorhanden."
    return
  fi
  require_valid_services || return 1

  if ! caddy_is_running; then
    err "Caddy laeuft nicht. Zertifikate koennen nicht sauber getestet werden."
    return 1
  fi

  while IFS=$'\t' read -r domain scheme ip port profile || [[ -n "$domain" ]]; do
    [[ -z "${domain:-}" ]] && continue
    _tls_check_one "$domain"
  done < "$SERVICES_FILE"
}

health_check() {
  need_root
  load_env
  HEALTH_RED=0; HEALTH_YELLOW=0; HEALTH_GREEN=0

  section "Ampel-Check: Aktivitaet / Sicherheit / Zertifikate"

  [[ -f "$ENV_FILE" ]] && _health_line green "HomeEdge Konfig" "$ENV_FILE" || _health_line red "HomeEdge Konfig" "fehlt"
  # services.tsv als EIGENEN Punkt bewerten und danach trotzdem weiterlaufen
  # (nicht abbrechen, damit Docker/Caddy/UFW/Fail2ban/WG-Status sichtbar bleiben).
  local services_ok=1
  if [[ ! -f "$SERVICES_FILE" || ! -s "$SERVICES_FILE" ]]; then
    _health_line yellow "Externe Dienste" "keine Dienste eingetragen"
  elif validate_services_file >/dev/null 2>&1; then
    _health_line green "Externe Dienste" "konfiguriert und services.tsv valide"
  else
    _health_line red "services.tsv" "ungueltig - Reparatur: sudo homeedge repair-services"
    services_ok=0
  fi

  if systemctl is-active --quiet docker 2>/dev/null; then _health_line green "Docker" "aktiv"; else _health_line red "Docker" "nicht aktiv"; fi

  # Caddy-Stack granular bewerten: Verzeichnis, Caddyfile, .env, Compose-Datei,
  # Compose-Config und Container-Zustand getrennt melden (Bug P1).
  case "$(caddy_stack_state)" in
    dir_missing)
      _health_line red "Caddy Stack" "Verzeichnis fehlt: $CADDY_DIR"; caddy_stack_repair_hint ;;
    caddyfile_missing)
      _health_line red "Caddy Stack" "Caddyfile fehlt: ${CADDY_DIR}/Caddyfile"; caddy_stack_repair_hint ;;
    env_missing)
      _health_line red "Caddy Stack" ".env fehlt: ${CADDY_DIR}/.env"; caddy_stack_repair_hint ;;
    compose_missing)
      _health_line red "Caddy Stack" "fehlt: ${CADDY_COMPOSE_FILE} nicht gefunden"; caddy_stack_repair_hint ;;
    compose_invalid)
      _health_line red "Caddy Stack" "docker compose config ungueltig"; caddy_stack_repair_hint ;;
    no_container)
      _health_line red "Caddy Container" "existiert nicht"; caddy_stack_repair_hint ;;
    restarting)
      _health_line red "Caddy Container" "Restarting (Crash-Loop) - Logs: sudo homeedge caddy-logs" ;;
    exited)
      _health_line red "Caddy Container" "exited (gestoppt) - Reparatur: sudo homeedge restart" ;;
    running)
      _health_line green "Caddy Container" "laeuft (running=true, restarting=false)"
      if validate_caddyfile; then
        _health_line green "Caddy Konfig" "valid"
      else
        _health_line red "Caddy Konfig" "ungueltig oder nicht pruefbar"
      fi ;;
  esac

  # Alter Fehler-Marker: nur kritisch, wenn die aktuelle Konfig NICHT laeuft.
  # Laeuft Caddy mit valider Konfig, wird der Marker archiviert (kein dauerhaftes ROT).
  if [[ -f "${CADDY_DIR}/Caddyfile.failed" ]]; then
    if [[ "$(caddy_stack_state)" == "running" ]] && caddy_is_running \
        && validate_caddyfile; then
      local _ts; _ts="$(date +%Y%m%d-%H%M%S)"
      mv "${CADDY_DIR}/Caddyfile.failed" "${CADDY_DIR}/Caddyfile.failed.old.${_ts}" 2>/dev/null || true
      [[ -f "$CADDY_VALIDATE_LOG" ]] && cp -a "$CADDY_VALIDATE_LOG" "${CADDY_VALIDATE_LOG}.old.${_ts}" 2>/dev/null || true
      _health_line yellow "Caddyfile (frueher fehlerhaft)" "aktuelle Konfig ist valid - Marker archiviert"
    else
      _health_line red "Caddyfile (letzte Generierung)" "war ungueltig, aktuelle Konfig nicht aktiv"
      printf '          %s\n' "Datei: ${CADDY_DIR}/Caddyfile.failed"
      printf '          %s\n' "Log:   ${CADDY_VALIDATE_LOG}"
      printf '          %s\n' "Reparatur: sudo homeedge caddy-rebuild"
    fi
  fi

  if systemctl is-active --quiet fail2ban 2>/dev/null; then
    _health_line green "Fail2ban" "aktiv"
    if fail2ban-client status sshd >/dev/null 2>&1; then _health_line green "Fail2ban SSH" "sshd jail aktiv"; else _health_line yellow "Fail2ban SSH" "sshd jail nicht pruefbar"; fi
    if [[ "${CADDY_FAIL2BAN}" == "1" ]]; then
      if fail2ban-client status caddy-auth >/dev/null 2>&1; then _health_line green "Fail2ban Caddy" "caddy-auth jail aktiv"; else _health_line yellow "Fail2ban Caddy" "aktiviert, aber Jail fehlt"; fi
    fi
  else
    _health_line red "Fail2ban" "nicht aktiv"
  fi

  # CrowdSec nur bewerten, wenn das optionale Modul aktiviert ist.
  if [[ "${ENABLE_CROWDSEC:-0}" == "1" ]]; then
    if systemctl is-active --quiet crowdsec 2>/dev/null; then _health_line green "CrowdSec" "aktiv"; else _health_line red "CrowdSec" "aktiviert, aber Dienst nicht aktiv"; fi
    if systemctl is-active --quiet "$CROWDSEC_BOUNCER_SVC" 2>/dev/null; then _health_line green "CrowdSec Bouncer" "aktiv (${CROWDSEC_BOUNCER_SVC})"; else _health_line red "CrowdSec Bouncer" "nicht aktiv - Decisions evtl. nicht durchgesetzt"; fi
    [[ -f "$CROWDSEC_ACQUIS_FILE" ]] && _health_line green "CrowdSec Acquisition" "$CROWDSEC_ACQUIS_FILE" || _health_line red "CrowdSec Acquisition" "fehlt: $CROWDSEC_ACQUIS_FILE"
    local _cslog="${CROWDSEC_CADDY_LOG:-/opt/caddy-edge/logs/access.log}"
    [[ -f "$_cslog" ]] && _health_line green "CrowdSec Caddy-Log" "$_cslog" || _health_line yellow "CrowdSec Caddy-Log" "fehlt: $_cslog"
  fi

  if ufw status 2>/dev/null | grep -qi "Status: active\|Status: aktiv"; then
    _health_line green "UFW Firewall" "aktiv"
  else
    _health_line red "UFW Firewall" "nicht aktiv"
  fi

  if [[ -n "${CLIENT_PUBLIC_KEY:-}" ]]; then _health_line green "WG Client PublicKey" "gesetzt"; else _health_line red "WG Client PublicKey" "fehlt"; fi

  if ip link show "$WG_IF" >/dev/null 2>&1; then
    _health_line green "WireGuard Interface" "${WG_IF} vorhanden"
  else
    _health_line red "WireGuard Interface" "${WG_IF} fehlt"
  fi

  local hs now age peerline
  hs="$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')"
  now="$(date +%s)"
  if [[ -z "${hs:-}" || "$hs" == "0" ]]; then
    _health_line red "WG Handshake" "kein Handshake"
  else
    age=$((now-hs))
    if (( age < 600 )); then _health_line green "WG Handshake" "vor ${age}s"; elif (( age < 3600 )); then _health_line yellow "WG Handshake" "vor ${age}s"; else _health_line red "WG Handshake" "zu alt: ${age}s"; fi
  fi

  if (( services_ok )) && [[ -f "$SERVICES_FILE" && -s "$SERVICES_FILE" ]]; then
    local domain scheme ip port route code rc url tmp msg dns
    while IFS=$'\t' read -r domain scheme ip port profile || [[ -n "$domain" ]]; do
      [[ -z "${domain:-}" ]] && continue

      route="$(ip route get "$ip" 2>/dev/null || true)"
      if grep -q "dev ${WG_IF}" <<< "$route"; then
        _health_line green "Route ${ip}" "ueber ${WG_IF}"
      else
        _health_line red "Route ${ip}" "nicht ueber ${WG_IF}: ${route}"
      fi

      url="${scheme}://${ip}:${port}"
      tmp="$(mktemp)"; rc=0; code="$(curl -k -sS -I --connect-timeout 5 --max-time 10 -o /dev/null -w '%{http_code}' "$url" 2>"$tmp")" || rc=$?
      if [[ "$rc" -eq 0 && "$code" =~ ^(2|3)[0-9][0-9]$ ]]; then
        _health_line green "Backend ${domain}" "${url} HTTP ${code}"
      elif [[ "$rc" -eq 0 && "$code" =~ ^(401|403)$ ]]; then
        _health_line yellow "Backend ${domain}" "${url} HTTP ${code} (Auth/Forbidden, technisch erreichbar)"
      else
        msg="$(tr '\n' ' ' < "$tmp" | cut -c1-100)"
        _health_line red "Backend ${domain}" "${url} nicht ok: HTTP ${code} ${msg}"
      fi
      rm -f "$tmp"

      dns="$(dig +short A "$domain" 2>/dev/null | tail -n1 || true)"
      if [[ -z "$dns" ]]; then
        _health_line yellow "DNS ${domain}" "kein A-Record gefunden"
      elif _is_ip "$VPS_PUBLIC_HOST"; then
        [[ "$dns" == "$VPS_PUBLIC_HOST" ]] && _health_line green "DNS ${domain}" "${dns}" || _health_line yellow "DNS ${domain}" "${dns}, erwartet ${VPS_PUBLIC_HOST}"
      else
        _health_line green "DNS ${domain}" "A-Record: ${dns}"
      fi
    done < "$SERVICES_FILE"
  elif (( ! services_ok )); then
    _health_line yellow "Backend/DNS/TLS-Checks" "uebersprungen (services.tsv ungueltig) - erst reparieren"
  fi

  (( services_ok )) && { check_certs || true; }

  section "Gesamt-Ampel"
  if (( HEALTH_RED > 0 )); then
    printf '%b\n' "${C_RED}[ROT]${C_RESET} Es gibt ${HEALTH_RED} kritische Punkte und ${HEALTH_YELLOW} Warnungen."
  elif (( HEALTH_YELLOW > 0 )); then
    printf '%b\n' "${C_YELLOW}[GELB]${C_RESET} Grundfunktion ok, aber ${HEALTH_YELLOW} Warnungen pruefen."
  else
    printf '%b\n' "${C_GREEN}[GRUEN]${C_RESET} Alles Wesentliche ist aktiv und sieht sauber aus."
  fi
  echo
  info "Hinweis: Die Ampel ist ein technischer Check, keine Garantie fuer perfekte Sicherheit."
  # Exitcode != 0, sobald es kritische (ROT) Punkte gibt - fuer Skripte/Migration.
  (( HEALTH_RED > 0 )) && return 1
  return 0
}


# ------------------------------------------------------------
# Security submenu / checks
# ------------------------------------------------------------
security_ports() {
  load_env
  section "Offene Ports / Bewertung"
  ss -tulpn || true
  echo
  info "Erwartet: TCP ${SSH_PORT} (SSH), TCP 443 (HTTPS), UDP ${WG_PORT} (WireGuard)."
  info "127.0.0.1:2019 ist Caddy Admin API nur lokal und von aussen nicht erreichbar. Das ist ok."
  if udp443_open; then
    warn "UDP 443 ist Caddy HTTP/3/QUIC. Nicht schlimm, aber optional. Fuer minimalen Footprint kannst du HTTP/3 deaktivieren."
  else
    ok "UDP 443 ist nicht offen. Caddy laeuft nur mit HTTP/1.1 und HTTP/2."
  fi
  echo
  warn "Wichtig: Pruefe von extern zusaetzlich mit nmap oder einem Portscanner. ss zeigt nur lokal lauschende Dienste."
}

security_firewall() {
  load_env
  section "Firewall / UFW"
  ufw status verbose || true
  echo
  if ufw status 2>/dev/null | grep -qi "Status: active\|Status: aktiv"; then
    ok "UFW ist aktiv."
  else
    err "UFW ist nicht aktiv."
  fi
  info "Soll: default deny incoming, allow outgoing, erlaubte Ports: SSH, 443/tcp, WG/udp."
}

security_ssh_status() {
  load_env
  section "SSH-Hardening Status"
  echo "Aktiver SSH-Port laut HomeEdge: ${SSH_PORT}"
  echo
  grep -RniE "^(PermitRootLogin|PasswordAuthentication|KbdInteractiveAuthentication|PubkeyAuthentication)" /etc/ssh/sshd_config /etc/ssh/sshd_config.d/ 2>/dev/null || warn "Keine expliziten SSH-Hardening-Werte gefunden."
  echo
  if sshd -T 2>/dev/null | grep -E "^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication)"; then
    echo
  else
    warn "sshd -T konnte nicht ausgewertet werden."
  fi
  info "Sicherer Zielzustand: PermitRootLogin no, PasswordAuthentication no, KbdInteractiveAuthentication no, PubkeyAuthentication yes."
  warn "Root-/Passwort-Login erst deaktivieren, wenn ein Admin-User mit SSH-Key getestet ist."
}

security_fail2ban() {
  section "Fail2ban Status"
  systemctl status fail2ban --no-pager -l || true
  echo
  fail2ban-client status 2>/dev/null || true
  fail2ban-client status sshd 2>/dev/null || true
  fail2ban-client status caddy-auth 2>/dev/null || true
}

security_http3_toggle() {
  load_env
  section "Caddy HTTP/3 / QUIC (UDP 443)"
  maybe_backup_before_change
  if [[ "${ENABLE_HTTP3:-0}" == "1" ]]; then
    warn "HTTP/3 ist aktuell aktiv (Caddy lauscht zusaetzlich auf UDP 443)."
    if yesno "HTTP/3 deaktivieren?" "y"; then
      ENABLE_HTTP3="0"; save_env; reload_caddy; ufw_apply_auto
      ok "HTTP/3 deaktiviert, 443/udp geschlossen."
    fi
  else
    info "HTTP/3 ist aktuell deaktiviert (nur HTTP/1.1 und HTTP/2)."
    if yesno "HTTP/3 aktivieren?" "n"; then
      ENABLE_HTTP3="1"; save_env; reload_caddy; ufw_apply_auto
      ok "HTTP/3 aktiviert, 443/udp erlaubt."
    fi
  fi
  echo
  section "UFW Status"
  ufw status verbose 2>/dev/null | grep -E '443|Status' || true
  echo
  if udp443_open; then info "UDP 443 ist offen."; else info "UDP 443 ist geschlossen."; fi
}

security_minimal_check() {
  load_env
  section "Minimal-Sicherheitscheck"

  local bad=0 warnc=0

  if ufw status 2>/dev/null | grep -qi "Status: active\|Status: aktiv"; then ok "UFW aktiv"; else err "UFW nicht aktiv"; bad=$((bad+1)); fi
  if systemctl is-active --quiet fail2ban 2>/dev/null; then ok "Fail2ban aktiv"; else err "Fail2ban nicht aktiv"; bad=$((bad+1)); fi
  if caddy_is_running; then ok "Caddy Container laeuft"; else err "Caddy Container laeuft nicht"; bad=$((bad+1)); fi
  if ip link show "$WG_IF" >/dev/null 2>&1; then ok "WireGuard Interface ${WG_IF} vorhanden"; else err "WireGuard Interface fehlt"; bad=$((bad+1)); fi

  if tcp_port_open "${SSH_PORT}"; then ok "SSH Port ${SSH_PORT}/tcp offen"; else warn "SSH Port ${SSH_PORT}/tcp nicht sichtbar"; warnc=$((warnc+1)); fi
  if tcp_port_open 443; then ok "HTTPS 443/tcp offen"; else err "HTTPS 443/tcp nicht offen"; bad=$((bad+1)); fi
  if udp_port_open "${WG_PORT}"; then ok "WireGuard ${WG_PORT}/udp offen"; else err "WireGuard ${WG_PORT}/udp nicht offen"; bad=$((bad+1)); fi

  if udp443_open; then
    if [[ "${ENABLE_HTTP3:-0}" == "1" ]]; then warn "UDP 443 offen wegen HTTP/3/QUIC (optional)"; warnc=$((warnc+1)); else warn "UDP 443 offen, obwohl HTTP/3 deaktiviert sein sollte"; warnc=$((warnc+1)); fi
  else
    ok "UDP 443 nicht offen"
  fi

  local rootlogin passauth kbd pubkey
  rootlogin="$(sshd -T 2>/dev/null | awk '/^permitrootlogin /{print $2}' || true)"
  passauth="$(sshd -T 2>/dev/null | awk '/^passwordauthentication /{print $2}' || true)"
  kbd="$(sshd -T 2>/dev/null | awk '/^kbdinteractiveauthentication /{print $2}' || true)"
  pubkey="$(sshd -T 2>/dev/null | awk '/^pubkeyauthentication /{print $2}' || true)"

  [[ "$pubkey" == "yes" ]] && ok "SSH PubkeyAuthentication aktiv" || warn "SSH PubkeyAuthentication nicht aktiv/unklar"
  [[ "$passauth" == "no" ]] && ok "SSH Passwortlogin deaktiviert" || { warn "SSH Passwortlogin ist nicht deaktiviert"; warnc=$((warnc+1)); }
  [[ "$rootlogin" == "no" ]] && ok "SSH Root-Login deaktiviert" || { warn "SSH Root-Login ist nicht deaktiviert"; warnc=$((warnc+1)); }
  [[ "$kbd" == "no" ]] && ok "SSH Keyboard-Interactive deaktiviert" || { warn "SSH Keyboard-Interactive ist nicht deaktiviert"; warnc=$((warnc+1)); }

  echo
  if (( bad > 0 )); then
    printf '%b\n' "${C_RED}[ROT]${C_RESET} ${bad} kritische Punkte, ${warnc} Warnungen."
  elif (( warnc > 0 )); then
    printf '%b\n' "${C_YELLOW}[GELB]${C_RESET} Keine kritischen Punkte, aber ${warnc} Warnungen."
  else
    printf '%b\n' "${C_GREEN}[GRUEN]${C_RESET} Minimalcheck sieht sauber aus."
  fi
}

security_jellyfin_checklist() {
  load_env
  section "Jellyfin / UniFi Sicherheits-Checkliste"
  cat <<EOF
[ ] Jellyfin Domain in Cloudflare: DNS only / graue Wolke
[ ] Jellyfin Known Proxy gesetzt: ${VPS_WG_IP}
[ ] Jellyfin Account Lockout aktiv
[ ] Externe Benutzer sind keine Admins
[ ] Keine Admin-App/kein Admin-Konto fuer normales Streaming extern nutzen
[ ] User-Rechte begrenzt, keine unnoetigen Upload-/Admin-Rechte
[ ] Jellyfin aktuell halten
[ ] UniFi Firewall nicht any-any:
    Quelle: ${VPS_WG_IP}
    Ziel:   nur Backend-IP:Port, z.B. 192.168.10.99:8096/tcp
[ ] Auf dem VPS sind keine Backend-Ports direkt offen, z.B. kein 8096/tcp public
EOF
}

security_wireguard() { load_env; wg_status; }


# ------------------------------------------------------------
# Wartung / Updates
# ------------------------------------------------------------
show_version() {
  load_env
  section "HomeEdge Version"
  echo "Installierte Version: ${APP_VERSION}"
  echo "Befehl: homeedge"
  echo "Kompatibilitaets-Alias: edgectl"
  echo "Config: ${ENV_FILE}"
  echo "Update-Repo: ${HOMEEDGE_REPO}@${HOMEEDGE_BRANCH}"
  echo "Raw-Quelle:  $(_repo_raw_url)"
  [[ -n "${HOMEEDGE_UPDATE_URL:-}" ]] && echo "Update-URL:  ${HOMEEDGE_UPDATE_URL}"
}

system_update() {
  section "Systemupdates"
  apt-get update
  apt-get upgrade -y
  ok "Systemupdates abgeschlossen."
}

# Manuelles, sicheres Caddy/Docker-Update (Image mit --pull neu bauen). Bewusst
# NICHT automatisch - Container-Updates koennen Dienste ungeplant brechen.
caddy_update() {
  need_root; load_env
  section "Caddy / Docker neu bauen (manuelles Update)"
  info "OS-Updates/Zertifikate laufen automatisch. Caddy/Docker-Image ist ein MANUELLES Update."
  # 1) services.tsv validieren.
  require_valid_services || { err "services.tsv ungueltig - bitte zuerst: sudo homeedge repair-services"; return 1; }
  # 2) Backup anbieten/erstellen.
  maybe_backup_before_change
  # 3) Stack-Dateien sicherstellen (Dockerfile/compose/.env/Verzeichnisse, kein Dir-Caddyfile).
  _ensure_caddyfile_not_dir
  write_caddy_stack
  caddy_compose_file_exists || { err "Caddy Compose-Datei nicht gefunden: $CADDY_COMPOSE_FILE"; caddy_stack_repair_hint; return 1; }
  # 4) Image mit --pull neu bauen.
  info "Baue Caddy-Image neu (docker compose build --pull) - das kann dauern..."
  if ! caddy_compose build --pull >/dev/null 2>&1; then err "Caddy-Image-Build (--pull) fehlgeschlagen."; return 1; fi
  # Cloudflare-DNS-Modul im frischen Image verifizieren.
  if caddy_has_cloudflare_module; then ok "Cloudflare DNS Modul im neuen Image vorhanden."; else err "Cloudflare DNS Modul fehlt im neuen Image - Abbruch."; return 1; fi
  # 5) Caddyfile generieren/validieren (atomar, mit Rollback) BEVOR Container neu erstellt wird.
  if ! _caddy_prepare_config; then err "Abbruch: Konfiguration ungueltig, kein Rebuild. Letzte Caddyfile bleibt."; return 1; fi
  # 6) Container neu erstellen (mit Timeout + Diagnose bei Fehler).
  if ! caddy_compose_up recreate; then
    err "Caddy-Start (up -d --force-recreate) fehlgeschlagen. Vorherige Caddyfile bleibt - Rollback ueber Backup moeglich (sudo homeedge restore-config)."
    return 1
  fi
  # 7) Laufzeit pruefen.
  if caddy_is_running; then ok "Caddy neu gebaut und laeuft (running=true, restarting=false)."; else err "Caddy laeuft nicht (Restarting/exited). Logs: sudo homeedge caddy-logs"; return 1; fi
  # 8) Aktive Konfig validieren.
  if validate_caddyfile; then ok "Caddy Konfig valid."; else warn "Caddy Konfig konnte nicht bestaetigt werden - Logs pruefen."; fi
  # 9) Lokaler SNI-Test + Zertifikate abwarten (cert_rc=1 bei echtem ACME-Fehler).
  local cert_rc=0; wait_for_certs || cert_rc=$?
  # 10) Ergebnis.
  if (( cert_rc != 0 )); then
    err "Caddy/Docker-Update durchgefuehrt, aber Zertifikat fuer mind. eine Domain schlaegt fehl (siehe oben)."
    return 1
  fi
  ok "Caddy/Docker-Update abgeschlossen. Bestehende Domains sollten weiter per HTTPS erreichbar sein."
}

_repo_raw_url() {
  printf 'https://raw.githubusercontent.com/%s/%s/homeedge.sh' "${HOMEEDGE_REPO}" "${HOMEEDGE_BRANCH}"
}

configure_update_source() {
  load_env
  section "Update-URL konfigurieren"
  echo "Optional: direkte Raw-URL auf eine homeedge.sh, z. B. ein GitHub Release Asset."
  echo "Beispiel: https://github.com/USER/REPO/releases/latest/download/homeedge.sh"
  echo "Fuer normales Repo-Update brauchst du das nicht (siehe Repo-Quelle)."
  echo
  HOMEEDGE_UPDATE_URL="$(ask "Update-URL (leer lassen = keine)" "${HOMEEDGE_UPDATE_URL:-}")"
  save_env
  ok "Update-URL gespeichert."
}

configure_repo_source() {
  load_env
  section "GitHub-Repo als Update-Quelle konfigurieren"
  echo "Aktuelles Repo:   ${HOMEEDGE_REPO}"
  echo "Aktueller Branch: ${HOMEEDGE_BRANCH}"
  echo
  HOMEEDGE_REPO="$(ask "GitHub Repo (owner/repo)" "${HOMEEDGE_REPO}")"
  HOMEEDGE_BRANCH="$(ask "Branch oder Tag" "${HOMEEDGE_BRANCH}")"
  save_env
  ok "Repo-Quelle gespeichert: ${HOMEEDGE_REPO}@${HOMEEDGE_BRANCH}"
  echo "Raw-URL: $(_repo_raw_url)"
}

# Validiert eine heruntergeladene homeedge.sh und installiert sie atomar.
# Bei jedem Fehler bleibt die aktuelle Installation unveraendert.
# $1 = Pfad zur heruntergeladenen Datei
_install_homeedge_from_file() {
  local tmp="$1" old new_ver
  sed -i 's/\r$//' "$tmp" 2>/dev/null || true
  if [[ ! -s "$tmp" ]]; then err "Download ist leer. Abbruch, nichts geaendert."; return 1; fi
  if ! grep -q 'APP_NAME="HomeEdge"' "$tmp"; then
    err "Datei sieht nicht nach HomeEdge aus (evtl. 404/Fehlerseite). Abbruch, nichts geaendert."
    return 1
  fi
  if ! bash -n "$tmp"; then err "Syntaxpruefung fehlgeschlagen. Abbruch, nichts geaendert."; return 1; fi
  new_ver="$(grep -m1 '^APP_VERSION=' "$tmp" | cut -d'"' -f2 || true)"
  old="/usr/local/bin/homeedge.backup.$(date +%Y%m%d-%H%M%S)"
  cp -a /usr/local/bin/homeedge "$old" 2>/dev/null || true
  install -m 0755 "$tmp" /usr/local/bin/homeedge
  ln -sf /usr/local/bin/homeedge /usr/local/bin/edgectl
  ok "HomeEdge Script wurde aktualisiert auf Version: ${new_ver:-unbekannt}"
  info "Vorherige Version gesichert: ${old}"
  /usr/local/bin/homeedge --version || true
  # Migration mit der NEU installierten Version ausfuehren (Backup wurde vorher erstellt).
  # Das Script-Update selbst ist erfolgt; schlaegt die Migration fehl (z. B. kaputte
  # services.tsv), muss der GESAMTE Update-Prozess als nicht vollstaendig enden.
  echo
  info "Fuehre Migration/Reparatur mit der neuen Version aus..."
  if /usr/local/bin/homeedge migrate --no-backup; then
    return 0
  fi
  echo
  err "Migration nach Update nicht erfolgreich."
  info "Vorherige Version: ${old}"
  local lastbak; lastbak="$(ls -1t "${BACKUP_DIR}"/edge-backup-*.tar.gz 2>/dev/null | head -n1 || true)"
  [[ -n "$lastbak" ]] && info "Backup: ${lastbak}"
  info "Reparatur: sudo homeedge repair-services ; sudo homeedge migrate ; sudo homeedge health"
  return 1
}

# Repariert/aktualisiert eine bestehende Installation (idempotent).
homeedge_migrate() {
  need_root
  section "Migration / Reparatur bestehender Installation"
  [[ "${1:-}" == "--no-backup" ]] || maybe_backup_before_change
  load_env
  local migration_failed=0 services_ok=1
  # load_env hat fehlende Werte mit Defaults belegt (ENABLE_HTTP3=0, ENABLE_IPV6=0,
  # WG_MTU= leer, ...) und BESTEHENDE Werte aus der env beibehalten. save_env
  # bereinigt zugleich den Token. Es werden KEINE Legacy-Defaults erzwungen.
  save_env
  ok "Konfiguration repariert: Token bereinigt, fehlende Werte ergaenzt (bestehende beibehalten)."
  echo "ENABLE_HTTP3=${ENABLE_HTTP3:-0}  ENABLE_IPV6=${ENABLE_IPV6:-0}  WG_MTU=${WG_MTU:-auto}  CADDY_FAIL2BAN=${CADDY_FAIL2BAN:-0}"
  # Hinweise zu bestehenden, nicht-Standard-Werten (nur informieren, nicht aendern).
  [[ "${ENABLE_HTTP3:-0}" == "1" ]] && warn "HTTP/3 ist aktiv. UDP 443 wird geoeffnet. Fuer maximale Kompatibilitaet kann HTTP/3 deaktiviert werden (Caddy-Menue)."
  [[ -n "${WG_MTU:-}" ]] && warn "WG_MTU=${WG_MTU} ist gesetzt. Standard ist Auto/leer. Aendern ueber WireGuard -> MTU anzeigen/aendern."
  [[ "${CADDY_FAIL2BAN:-0}" == "0" ]] && info "caddy-auth Fail2ban ist deaktiviert. Aktivieren ueber Sicherheit -> Fail2ban."

  # Alte 4-Spalten-Eintraege migrieren, dann reparieren, dann ERNEUT validieren.
  migrate_services_4to5 || true
  if [[ -s "$SERVICES_FILE" ]] && ! validate_services_file >/dev/null 2>&1; then
    warn "services.tsv defekt - versuche automatische Reparatur..."
    repair_services --non-interactive || true
    if ! validate_services_file >/dev/null 2>&1; then
      services_ok=0; migration_failed=1
      err "services.tsv ist weiterhin ungueltig."
      err "Caddy Reload wird uebersprungen, damit die bestehende funktionierende Konfiguration aktiv bleibt."
      info "Reparatur: sudo homeedge repair-services"
    fi
  fi

  # WireGuard-Konfig neu schreiben (best effort, braucht wg).
  if command -v wg >/dev/null 2>&1; then write_wg_config 2>/dev/null && ok "WireGuard-Konfig (inkl. MTU) neu geschrieben." || warn "WireGuard-Konfig nicht aktualisiert."; fi
  # Caddyfile NUR neu erzeugen/laden, wenn services.tsv valide ist. Sonst bleibt
  # die laufende produktive Caddyfile unangetastet.
  if (( services_ok )); then
    if command -v docker >/dev/null 2>&1; then
      if ! reload_caddy; then
        # Umgebungsbedingte Reload-Probleme (Image fehlt / Validate-Timeout /
        # CTRL+C) duerfen die Migration NICHT hart als kaputt werten, solange
        # Caddy produktiv laeuft und die produktive Caddyfile valide ist. Nur
        # eine WIRKLICH ungueltige Config (oder ein Container-Ausfall) ist hart.
        if [[ "${CADDY_PREPARE_STATUS:-}" == "validate_env" ]] && caddy_is_running && validate_caddyfile; then
          warn "Caddy-Reload uebersprungen (${CADDY_VALIDATE_STATUS:-umgebungsbedingt}) - produktive Caddyfile laeuft und ist valide."
          info "Bei fehlendem Image: sudo homeedge caddy-rebuild"
        else
          warn "Caddy-Reload meldete Probleme (siehe oben)."
          migration_failed=1
        fi
      fi
    fi
  fi
  # Fail2ban mit Config-Test (best effort, aber Fehler sammeln).
  if command -v fail2ban-client >/dev/null 2>&1; then install_fail2ban || migration_failed=1; fi
  # UFW an Konfig angleichen (nicht-interaktiv, ohne Reset). Fehler nicht still
  # verschlucken - Hinweis geben; der finale Health-Check zeigt den UFW-Status.
  if command -v ufw >/dev/null 2>&1; then
    ufw_apply_auto || warn "UFW-Angleichung meldete Probleme - UFW-Status im Healthcheck pruefen (sudo homeedge firewall)."
  fi
  echo
  info "Healthcheck:"
  health_check || true   # Diagnose-Anzeige; harte Fehler werden oben separat erfasst.
  echo
  if (( migration_failed )); then
    err "Migration nicht vollstaendig abgeschlossen."
    (( ! services_ok )) && err "Hauptursache: services.tsv ungueltig -> sudo homeedge repair-services"
    info "Danach erneut: sudo homeedge migrate ; sudo homeedge health"
    return 1
  fi
  ok "Migration abgeschlossen."
  return 0
}

# Update direkt vom GitHub-Repo (raw.githubusercontent.com). Standardquelle.
homeedge_repo_update() {
  load_env
  section "HomeEdge aus GitHub-Repo aktualisieren"
  if ! command -v curl >/dev/null 2>&1; then err "curl ist nicht installiert."; return 1; fi
  local url; url="$(_repo_raw_url)"
  echo "Repo:                ${HOMEEDGE_REPO}"
  echo "Branch/Tag:          ${HOMEEDGE_BRANCH}"
  echo "Quelle:              ${url}"
  echo "Aktuell installiert: ${APP_VERSION}"
  echo
  if ! yesno "Neueste homeedge.sh aus diesem Repo laden und installieren?" "n"; then return; fi

  backup_create || true
  # KEIN RETURN-Trap (feuert bei verschachtelten Funktionen unerwartet erneut und
  # laeuft dann unter "set -u" auf ein ungesetztes $tmp). Explizit aufraeumen.
  local tmp; tmp="$(mktemp)"
  if ! curl -fsSL "$url" -o "$tmp"; then
    err "Download fehlgeschlagen. Pruefe Repo/Branch und ob homeedge.sh dort existiert."
    err "Versuchte URL: ${url}"
    rm -f "$tmp"; return 1
  fi
  # Optionale Checksumme: falls <url>.sha256 existiert, wird sie geprueft.
  local sum_remote sum_local
  if sum_remote="$(curl -fsSL "${url}.sha256" 2>/dev/null)" && [[ -n "$sum_remote" ]] && command -v sha256sum >/dev/null 2>&1; then
    sum_remote="$(awk '{print $1}' <<< "$sum_remote")"
    sum_local="$(sha256sum "$tmp" | awk '{print $1}')"
    if [[ "$sum_remote" != "$sum_local" ]]; then
      err "Checksumme stimmt nicht ueberein. Abbruch, nichts geaendert."
      err "erwartet: ${sum_remote}"; err "erhalten: ${sum_local}"
      rm -f "$tmp"; return 1
    fi
    ok "Checksumme verifiziert (sha256)."
  else
    info "Keine Checksumme gefunden (optional). Pruefung erfolgt ueber Marker + bash -n."
  fi
  local irc=0; _install_homeedge_from_file "$tmp" || irc=$?
  rm -f "$tmp"
  return "$irc"
}

# Update von einer frei konfigurierten Raw-URL (z. B. Release-Asset).
homeedge_self_update() {
  load_env
  section "HomeEdge aus Update-URL aktualisieren"
  if [[ -z "${HOMEEDGE_UPDATE_URL:-}" ]]; then
    warn "Keine Update-URL konfiguriert."
    configure_update_source
    load_env
  fi
  if [[ -z "${HOMEEDGE_UPDATE_URL:-}" ]]; then err "Keine Update-URL gesetzt."; return 1; fi

  echo "Quelle: ${HOMEEDGE_UPDATE_URL}"
  if ! yesno "Update von dieser Quelle herunterladen und installieren?" "n"; then return; fi

  backup_create || true
  # KEIN RETURN-Trap (siehe homeedge_repo_update) - explizit aufraeumen.
  local tmp; tmp="$(mktemp)"
  if ! curl -fsSL "$HOMEEDGE_UPDATE_URL" -o "$tmp"; then err "Download fehlgeschlagen."; rm -f "$tmp"; return 1; fi
  local irc=0; _install_homeedge_from_file "$tmp" || irc=$?
  rm -f "$tmp"
  return "$irc"
}

# Prueft, ob im Repo eine neuere Version liegt - ohne zu installieren.
check_for_update() {
  load_env
  section "Nach Update suchen"
  if ! command -v curl >/dev/null 2>&1; then err "curl ist nicht installiert."; return 1; fi
  local url remote_ver
  url="$(_repo_raw_url)"
  echo "Quelle:      ${url}"
  echo "Installiert: ${APP_VERSION}"
  remote_ver="$(curl -fsSL "$url" 2>/dev/null | grep -m1 '^APP_VERSION=' | cut -d'"' -f2 || true)"
  if [[ -z "$remote_ver" ]]; then
    warn "Konnte Remote-Version nicht ermitteln. Netzwerk, Repo oder Branch pruefen."
    return 1
  fi
  echo "Verfuegbar:  ${remote_ver}"
  echo
  local newest
  newest="$(printf '%s\n%s\n' "$APP_VERSION" "$remote_ver" | sort -V | tail -n1)"
  if [[ "$remote_ver" == "$APP_VERSION" ]]; then
    ok "HomeEdge ist aktuell."
  elif [[ "$newest" == "$remote_ver" ]]; then
    warn "Neue Version verfuegbar: ${remote_ver}"
    info "Aktualisieren: sudo homeedge self-update  (oder Menue -> aus GitHub aktualisieren)"
  else
    info "Installierte Version (${APP_VERSION}) ist neuer als die im Repo (${remote_ver})."
  fi
}

# Rollback auf eine zuvor gesicherte HomeEdge-Version.
homeedge_rollback() {
  need_root
  section "Rollback auf vorherige HomeEdge-Version"
  local backups=()
  mapfile -t backups < <(ls -1t /usr/local/bin/homeedge.backup.* 2>/dev/null || true)
  if (( ${#backups[@]} == 0 )); then
    err "Keine vorherige Version gefunden (/usr/local/bin/homeedge.backup.*)."
    return 1
  fi
  local i
  for i in "${!backups[@]}"; do
    printf '  %b%2d%b) %s\n' "$C_GREEN" "$((i+1))" "$C_RESET" "${backups[$i]}"
  done
  echo
  local choice; choice="$(ask "Version waehlen (0 = Abbruch)" "1")"
  [[ "$choice" =~ ^[0-9]+$ ]] || { err "Ungueltige Eingabe."; return 1; }
  (( choice == 0 )) && return 0
  if (( choice < 1 || choice > ${#backups[@]} )); then err "Ungueltige Nummer."; return 1; fi
  local target="${backups[$((choice-1))]}"
  if ! bash -n "$target"; then err "Backup-Datei ist syntaktisch fehlerhaft. Abbruch."; return 1; fi
  if ! yesno "Auf ${target} zuruecksetzen?" "n"; then warn "Abgebrochen."; return 0; fi
  cp -a /usr/local/bin/homeedge "/usr/local/bin/homeedge.backup.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
  install -m 0755 "$target" /usr/local/bin/homeedge
  ln -sf /usr/local/bin/homeedge /usr/local/bin/edgectl
  ok "Rollback abgeschlossen."
  /usr/local/bin/homeedge --version || true
}

# Bietet vor kritischen Aenderungen ein Backup an. Verhalten via BACKUP_BEHAVIOR:
# ask (Default, fragt), auto (immer Backup), never (nie).
maybe_backup_before_change() {
  load_env
  case "${BACKUP_BEHAVIOR:-ask}" in
    never) return 0 ;;
    auto) backup_create || warn "Backup fehlgeschlagen - fahre fort." ;;
    *) if yesno "Vor dieser Aenderung Backup erstellen?" "y"; then backup_create || warn "Backup fehlgeschlagen - fahre fort."; fi ;;
  esac
}


# ------------------------------------------------------------
# Strukturiertes Menue (Breadcrumb, ASCII-only)
# ------------------------------------------------------------
hmenu_head() {
  clear
  printf '%b\n' "${C_BOLD}${C_BLUE}============================================================${C_RESET}"
  printf '%b\n' "${C_DIM}HomeEdge > ${1}${C_RESET}"
  printf '%b\n' "${C_BOLD}${C_BLUE}============================================================${C_RESET}"
}
menu_back() { echo "   b) Zurueck"; echo "   0) Beenden"; line; }

# --- kleine Status-/Helfer-Funktionen fuer die Gruppen ---
caddy_status() {
  load_env
  section "Caddy / Docker Status"
  if systemctl is-active --quiet docker 2>/dev/null; then ok "Docker aktiv"; else err "Docker nicht aktiv"; fi
  case "$(caddy_stack_state)" in
    dir_missing)       err "Caddy Verzeichnis fehlt: $CADDY_DIR"; caddy_stack_repair_hint ;;
    caddyfile_missing) err "Caddyfile fehlt: ${CADDY_DIR}/Caddyfile"; caddy_stack_repair_hint ;;
    env_missing)       err "Caddy .env fehlt: ${CADDY_DIR}/.env"; caddy_stack_repair_hint ;;
    compose_missing)   err "Caddy Compose-Datei fehlt: $CADDY_COMPOSE_FILE"; caddy_stack_repair_hint ;;
    compose_invalid)   err "docker compose config ungueltig"; caddy_stack_repair_hint ;;
    no_container)      err "Caddy Container existiert nicht"; caddy_stack_repair_hint ;;
    restarting)        err "Caddy Container Restarting (Crash-Loop) - Logs: sudo homeedge caddy-logs" ;;
    exited)            err "Caddy Container exited (gestoppt) - Reparatur: sudo homeedge restart" ;;
    running)           ok "Caddy Container laeuft (running=true, restarting=false)" ;;
  esac
  docker ps -a --filter name=caddy-edge --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null || true
  echo
  if tcp_port_open 443; then ok "lauscht auf :443 (IPv4)"; else warn ":443 (IPv4) nicht sichtbar"; fi
  if caddy_listens_ipv6_443; then ok "lauscht auf :443 (IPv6)"; else info ":443 (IPv6) nicht sichtbar"; fi
  ss -tulpnH 2>/dev/null | grep ':443' | sed 's/^/  /' | mask_secrets || true
}

# Caddy-Logs mit explizitem Compose-Pfad (cwd-unabhaengig). Fallback: docker logs.
caddy_logs() {
  local n="${1:-120}"
  section "Caddy Logs (letzte ${n})"
  if caddy_compose_file_exists; then
    caddy_compose logs --tail "$n" 2>&1 | mask_secrets || docker logs --tail "$n" caddy-edge 2>&1 | mask_secrets || true
  else
    warn "Compose-Datei fehlt: $CADDY_COMPOSE_FILE - nutze 'docker logs caddy-edge'."
    docker logs --tail "$n" caddy-edge 2>&1 | mask_secrets || true
  fi
}

# IPv6-Statusuebersicht (extern Client -> VPS/Caddy).
ipv6_status() {
  load_env
  section "IPv6 Status (extern)"
  echo "ENABLE_IPV6: ${ENABLE_IPV6:-0}  (steuert NUR externen HTTPS-Zugriff 443/tcp v6)"
  info "WireGuard ist davon unabhaengig: bei UFW IPV6=yes kann der WG-UDP-Port auch via IPv6 erreichbar sein."
  local v6; v6="$(vps_ipv6)"
  [[ -n "$v6" ]] && ok "VPS hat globale IPv6: ${v6}" || warn "Keine globale IPv6-Adresse am VPS gefunden."
  if ufw_ipv6_enabled; then ok "UFW IPv6 aktiv (/etc/default/ufw: IPV6=yes)"; else warn "UFW IPv6 nicht aktiv (IPV6=yes fehlt)"; fi
  if caddy_listens_ipv6_443; then ok "Caddy lauscht auf IPv6 :443"; else info "Caddy lauscht (noch) nicht sichtbar auf IPv6 :443"; fi
  # Tatsaechliche UFW-443-Lage aus "ufw status" (nicht nur die ENV-Flags).
  local st; st="$(ufw status 2>/dev/null || true)"
  if grep -qiE '^Status: (active|aktiv)' <<<"$st"; then
    local t4=nein t6=nein u4=nein u6=nein
    grep -E '(^|[[:space:]])443/tcp([[:space:]]|$)' <<<"$st" | grep -qv '(v6)' && t4=ja
    grep -qE '443/tcp \(v6\)' <<<"$st" && t6=ja
    grep -E '(^|[[:space:]])443/udp([[:space:]]|$)' <<<"$st" | grep -qv '(v6)' && u4=ja
    grep -qE '443/udp \(v6\)' <<<"$st" && u6=ja
    echo "UFW 443-Regeln: tcp(v4)=${t4}  tcp(v6)=${t6}  udp(v4)=${u4}  udp(v6)=${u6}"
    if _ufw_verify_443 "$st" >/dev/null 2>&1; then
      ok "UFW 443-Regeln stimmen mit der Konfig ueberein (IPv6=${ENABLE_IPV6:-0}, HTTP/3=${ENABLE_HTTP3:-0})."
    else
      warn "UFW 443-Regeln weichen von der Konfig ab (IPv6=${ENABLE_IPV6:-0}, HTTP/3=${ENABLE_HTTP3:-0}):"
      _ufw_verify_443 "$st" || true
    fi
  else
    warn "UFW ist inaktiv - 443-Regeln koennen nicht via 'ufw status' verifiziert werden (sudo homeedge firewall)."
  fi
  echo "Lauschende :443 Sockets:"
  ss -tulpnH 2>/dev/null | grep ':443' | sed 's/^/  /' | mask_secrets || true
  echo
  info "IPv6 betrifft nur den externen Zugriff auf VPS/Caddy. Backend bleibt IPv4 ueber WireGuard."
}

# IPv6 extern aktivieren/deaktivieren.
ipv6_toggle() {
  need_root; load_env
  section "IPv6 extern aktivieren/deaktivieren"
  echo "Hinweis: IPv6 betrifft nur den externen Zugriff auf den VPS/Caddy."
  echo "Der Backend-Zugriff ins Heimnetz bleibt IPv4 ueber WireGuard."
  echo "Aktuell: ENABLE_IPV6=${ENABLE_IPV6:-0}"
  echo
  # Alten Wert merken, um bei fehlgeschlagener Verifikation sauber zurueckzurollen.
  local old_ipv6="${ENABLE_IPV6:-0}"
  if [[ "$old_ipv6" == "1" ]]; then
    if yesno "IPv6 extern deaktivieren?" "y"; then
      maybe_backup_before_change
      ENABLE_IPV6=0; save_env
      if ufw_apply_auto; then
        ok "IPv6 extern deaktiviert (443/tcp v6 geschlossen)."
      else
        ENABLE_IPV6="$old_ipv6"; save_env; ufw_apply_auto >/dev/null 2>&1 || true
        err "Umschaltung fehlgeschlagen - alter Zustand (ENABLE_IPV6=${old_ipv6}) wiederhergestellt."
      fi
    fi
  else
    if ! vps_has_global_ipv6; then warn "Dieser VPS hat keine globale IPv6-Adresse - IPv6 extern bringt aktuell nichts."; fi
    if yesno "IPv6 extern aktivieren?" "n"; then
      maybe_backup_before_change
      ENABLE_IPV6=1; save_env
      if ufw_apply_auto; then
        ok "IPv6 extern aktiviert (443/tcp v6 offen)."
        warn "Fuer Erreichbarkeit AAAA-Records auf die VPS-IPv6 setzen: $(vps_ipv6)"
      else
        ENABLE_IPV6="$old_ipv6"; save_env; ufw_apply_auto >/dev/null 2>&1 || true
        err "Umschaltung fehlgeschlagen - alter Zustand (ENABLE_IPV6=${old_ipv6}) wiederhergestellt."
      fi
    fi
  fi
  echo
  ipv6_status
}
show_caddyfile() {
  section "Caddyfile"
  if [[ -f "${CADDY_DIR}/Caddyfile" ]]; then mask_secrets < "${CADDY_DIR}/Caddyfile"; else warn "Keine Caddyfile vorhanden. Erst Dienst anlegen / reload."; fi
}
ufw_rules() { section "UFW Regeln"; ufw status numbered 2>/dev/null || warn "UFW nicht verfuegbar/aktiv."; }
route_test() {
  load_env
  section "Route zum Backend testen"
  local ip; ip="$(awk -F'\t' 'NF>=3{print $3; exit}' "$SERVICES_FILE" 2>/dev/null || true)"
  ip="$(ask "Backend-IP fuer Routen-Test" "${ip:-}")"
  [[ -z "$ip" ]] && { warn "Keine IP angegeben."; return; }
  ip route get "$ip" 2>&1 || true
}
handshake_check() {
  load_env
  section "WireGuard Handshake"
  local hs now age
  hs="$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')"
  now="$(date +%s)"
  if [[ -z "${hs:-}" || "$hs" == "0" ]]; then err "Kein Handshake. Tunnel evtl. nicht aktiv oder UniFi-Key fehlt."; return; fi
  age=$((now-hs))
  if (( age < 600 )); then ok "Letzter Handshake vor ${age}s"; elif (( age < 3600 )); then warn "Letzter Handshake vor ${age}s"; else err "Handshake zu alt: ${age}s"; fi
}
verify_current_token() {
  load_env
  section "Cloudflare Token testen"
  [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || { err "Kein Token gesetzt."; return 1; }
  if verify_cloudflare_token "$CLOUDFLARE_API_TOKEN"; then
    ok "Token ist gueltig (Cloudflare bestaetigt)."
  else
    local rc=$?
    if [[ "$rc" -eq 2 ]]; then warn "curl fehlt - kann nicht pruefen."; else err "Token ungueltig oder nicht bestaetigt."; fi
  fi
}
dns_challenge_test() {
  load_env
  section "Cloudflare DNS-Challenge pruefen"
  echo "Caddy nutzt DNS-01 ueber das caddy-dns/cloudflare Modul."
  if caddy_is_running; then
    if docker exec caddy-edge caddy list-modules 2>/dev/null | grep -q 'cloudflare'; then ok "Cloudflare DNS-Modul im Caddy-Build vorhanden."; else err "Cloudflare DNS-Modul fehlt - Caddy neu bauen (Wartung -> Docker/Caddy neu bauen)."; fi
  else
    warn "Caddy laeuft nicht - Modulpruefung uebersprungen."
  fi
  verify_current_token
}
restart_services() {
  need_root; load_env
  section "Dienste neu starten"
  if ! yesno "Caddy, WireGuard und Fail2ban neu starten?" "n"; then warn "Abgebrochen."; return; fi
  if caddy_compose_file_exists; then caddy_compose restart >/dev/null 2>&1 && ok "Caddy neu gestartet." || warn "Caddy-Neustart fehlgeschlagen."; else warn "Caddy Compose-Datei fehlt: $CADDY_COMPOSE_FILE (sudo homeedge caddy-rebuild)"; fi
  restart_wg
  systemctl restart fail2ban 2>/dev/null && ok "Fail2ban neu gestartet." || warn "Fail2ban nicht neu gestartet."
}
do_reboot() {
  need_root
  section "System rebooten"
  warn "Der VPS wird neu gestartet. Die SSH-Verbindung bricht ab."
  if yesno "Jetzt rebooten?" "n"; then reboot; else warn "Abgebrochen."; fi
}
ufw_logs() {
  section "UFW Logs"
  if [[ -f /var/log/ufw.log ]]; then tail -n 100 /var/log/ufw.log; else journalctl -k 2>/dev/null | grep -i 'UFW' | tail -n 100 || warn "Keine UFW-Logs gefunden."; fi
}
diag_report() {
  need_root; load_env
  # Diagnose muss gerade bei Fehlern komplett durchlaufen - keine harten
  # Abbrueche durch set -e oder durch Funktionen, die bei kaputter services.tsv
  # mit return 1 aussteigen (Bug P2).
  set +e
  section "Diagnosebericht erstellen"
  # services.tsv vorab pruefen (Bug P2). Fuer die Diagnose NICHT abbrechen, da
  # der Bericht gerade bei defekter Konfig nuetzlich ist - aber klar markieren.
  local svc_state="ok"
  if ! validate_services_file >/dev/null 2>&1; then
    err "services.tsv ist ungueltig."
    printf '%s\n' "Bitte ausfuehren:"
    printf '%s\n' "sudo homeedge repair-services"
    svc_state="UNGUELTIG (sudo homeedge repair-services)"
  fi
  local f="${EDGE_DIR}/diagnose-$(date +%Y%m%d-%H%M%S).txt"
  {
    echo "HomeEdge Diagnose $(date -Is)"
    echo "Version: ${APP_VERSION}"
    echo "Host: $(hostname)   Kernel: $(uname -r)"
    [[ -r /etc/os-release ]] && { . /etc/os-release 2>/dev/null; echo "OS: ${PRETTY_NAME:-unbekannt}"; }
    echo "Update-Repo: ${HOMEEDGE_REPO}@${HOMEEDGE_BRANCH}"
    echo "services.tsv: ${svc_state}"
    echo "ENABLE_HTTP3=${ENABLE_HTTP3}  WG_MTU=${WG_MTU}  CADDY_FAIL2BAN=${CADDY_FAIL2BAN}  BACKUP_BEHAVIOR=${BACKUP_BEHAVIOR}  EXPERT_MODE=${EXPERT_MODE}"
    echo
    echo "## services.tsv"
    echo "Aktive Datei: ${SERVICES_FILE}"
    if [[ "$svc_state" != "ok" ]]; then
      echo "Status: UNGUELTIG - jede Zeile muss exakt 5 Tab-Felder haben:"
      echo "  domain<TAB>scheme<TAB>backend<TAB>port<TAB>profile"
      echo "Feldanalyse (Felder pro Zeile):"
      awk -F'\t' '{print "  " NR ": Felder=" NF " | " $0}' "$SERVICES_FILE" 2>/dev/null | head -50
      echo "Letzte Sicherungen:"
      ls -1t "${SERVICES_FILE}".broken.* 2>/dev/null | head -5 | sed 's/^/  /' || true
      ls -1t "${SERVICES_FILE}".repair-failed.* 2>/dev/null | head -5 | sed 's/^/  /' || true
      echo "Reparatur: sudo homeedge repair-services"
    else
      echo "Status: valide"
    fi
    echo
    echo "## Werte"; show_values
    echo; echo "## Domains/DNS"; domains_status
    echo; echo "## Offene Ports (ss -tulpn)"; ss -tulpn 2>/dev/null
    echo; echo "## Docker"; docker ps -a 2>/dev/null
    echo; echo "## Caddy Stack"
    echo "Status: $(caddy_stack_state)"
    echo "Verzeichnis ${CADDY_DIR}:"; ls -la "$CADDY_DIR" 2>/dev/null || echo "  (fehlt)"
    echo "docker compose config:"; caddy_compose config >/dev/null 2>&1 && echo "  OK" || echo "  ungueltig/fehlt"
    echo; echo "## WireGuard"; wg show 2>/dev/null
    echo; echo "## WireGuard Konfig (/etc/wireguard)"; ls -l /etc/wireguard 2>/dev/null; grep -RnE '^(Address|ListenPort|MTU|AllowedIPs|PersistentKeepalive)' /etc/wireguard 2>/dev/null
    echo; echo "## Routen"; ip route 2>/dev/null
    echo; echo "## UFW"; ufw status verbose 2>/dev/null
    echo; echo "## Fail2ban"; fail2ban-client status 2>/dev/null; for j in sshd caddy-auth; do echo "- jail $j:"; fail2ban-client status "$j" 2>/dev/null; done
    echo; echo "## Caddyfile"; [[ -f "${CADDY_DIR}/Caddyfile" ]] && cat "${CADDY_DIR}/Caddyfile" || echo "(keine aktive Caddyfile)"
    echo; echo "## Caddyfile.failed (letzte ungueltige Generierung, falls vorhanden)"
    if [[ -f "${CADDY_DIR}/Caddyfile.failed" ]]; then
      echo "Datei: ${CADDY_DIR}/Caddyfile.failed"
      echo "--- erste/letzte Zeilen (Secrets maskiert) ---"
      head -n 20 "${CADDY_DIR}/Caddyfile.failed" 2>/dev/null
      echo "..."
      tail -n 10 "${CADDY_DIR}/Caddyfile.failed" 2>/dev/null
    else
      echo "(keine)"
    fi
    echo; echo "## caddy-validate Log (tail)"; [[ -f "$CADDY_VALIDATE_LOG" ]] && tail -n 40 "$CADDY_VALIDATE_LOG" 2>/dev/null || echo "(kein Log: ${CADDY_VALIDATE_LOG})"
    echo; echo "## Caddy Cloudflare-DNS-Modul"; if docker exec caddy-edge caddy list-modules 2>/dev/null | grep -q 'dns.providers.cloudflare'; then echo "vorhanden"; else echo "FEHLT oder Container laeuft nicht (sudo homeedge caddy-rebuild)"; fi
    echo; echo "## Zertifikate (lokaler SNI-Check)"; check_certs 2>/dev/null
    echo; echo "## Speicher/Disk"; free -h 2>/dev/null; echo; df -h / 2>/dev/null
    echo; echo "## Caddy Logs (tail)"; if caddy_compose_file_exists; then caddy_compose logs --tail 80 2>/dev/null; else docker logs --tail 80 caddy-edge 2>/dev/null; fi
  } 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g' | mask_secrets > "$f"
  chmod 600 "$f"
  ok "Diagnosebericht gespeichert: $f (Secrets maskiert)."
  warn "Bericht kann WireGuard-PublicKeys/IPs enthalten - vor Weitergabe pruefen."
}
show_last_error() {
  section "Letzte Fehler"
  echo "## systemd (Prioritaet error, letzte 30):"
  journalctl -p err -n 30 --no-pager 2>/dev/null | mask_secrets || warn "journalctl nicht verfuegbar."
  echo
  echo "## Caddy (Fehlerzeilen, letzte 20):"
  docker logs --tail 200 caddy-edge 2>&1 | grep -iE 'error|fail' | tail -n 20 | mask_secrets || true
}
edit_acme_email() {
  need_root; load_env
  section "ACME E-Mail aendern"
  maybe_backup_before_change
  ACME_EMAIL="$(ask "ACME E-Mail (Let's Encrypt)" "$ACME_EMAIL")"
  save_env; write_caddy_stack; reload_caddy
  ok "ACME E-Mail gespeichert."
}
backup_behavior_toggle() {
  need_root; load_env
  section "Standard Backup-Verhalten"
  echo "Aktuell: ${BACKUP_BEHAVIOR}"
  echo "  1) ask   - vor kritischen Aenderungen fragen (Standard)"
  echo "  2) auto  - immer automatisch ein Backup"
  echo "  3) never - nie automatisch"
  local c; c="$(ask "Auswahl" "1")"
  case "$c" in 1) BACKUP_BEHAVIOR=ask ;; 2) BACKUP_BEHAVIOR=auto ;; 3) BACKUP_BEHAVIOR=never ;; *) warn "Unveraendert."; return ;; esac
  save_env; ok "Backup-Verhalten: ${BACKUP_BEHAVIOR}"
}
expert_mode_toggle() {
  need_root; load_env
  section "Expertenmodus"
  if [[ "${EXPERT_MODE:-0}" == "1" ]]; then
    if yesno "Expertenmodus deaktivieren?" "y"; then EXPERT_MODE=0; save_env; ok "Expertenmodus aus."; fi
  else
    warn "Expertenmodus ist fuer erfahrene Nutzer gedacht."
    if yesno "Expertenmodus aktivieren?" "n"; then EXPERT_MODE=1; save_env; ok "Expertenmodus an."; fi
  fi
}

# --- Gruppen-Untermenues ---
sm_status() {
  need_root; set +e
  while true; do
    hmenu_head "Status / Ampel"
    menu_item 1 "Gesamtstatus anzeigen"
    menu_item 2 "Ampel-Check komplett"
    menu_item 3 "Offene Ports anzeigen"
    menu_item 4 "Docker / Caddy Status"
    menu_item 5 "WireGuard Status"
    menu_item 6 "Zertifikatsstatus"
    menu_item 7 "DNS Status pro Domain"
    menu_item 8 "IPv6 Status (extern)"
    menu_item 9 "Server Auslastung"
    menu_item 10 "Setup verifizieren (Wizard-Abschluss)"
    menu_item 11 "Migrationsmodus an/aus (DNS-Umzug)"
    menu_back
    read -rp "Auswahl: " c
    case "$c" in
      1) status_all; pause ;;
      2) health_check; pause ;;
      3) security_ports; pause ;;
      4) caddy_status; pause ;;
      5) load_env; wg_status; pause ;;
      6) check_certs; pause ;;
      7) domains_status; pause ;;
      8) ipv6_status; pause ;;
      9) system_usage; pause ;;
      10) verify_setup; pause ;;
      11) load_env
          if [[ "${MIGRATION_MODE:-0}" == "1" ]]; then
            if yesno "Migrationsmodus ausschalten (DNS muss dann auf diesen VPS zeigen)?" "n"; then MIGRATION_MODE=0; save_env; ok "MIGRATION_MODE=0"; fi
          else
            if yesno "Migrationsmodus einschalten (DNS darf noch auf alten VPS zeigen)?" "y"; then MIGRATION_MODE=1; save_env; ok "MIGRATION_MODE=1"; fi
          fi
          pause ;;
      b|B) return ;; 0) exit 0 ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}
sm_services() {
  need_root; set +e
  while true; do
    hmenu_head "Domains & Dienste"
    menu_item 1 "Dienste anzeigen"
    menu_item 2 "Dienst hinzufuegen"
    menu_item 3 "Dienst bearbeiten"
    menu_item 4 "Dienst loeschen"
    menu_item 5 "Domain lokal per SNI testen"
    menu_item 6 "Backend direkt testen"
    menu_item 7 "Caddyfile aus Diensten neu generieren"
    menu_item 8 "Caddyfile anzeigen"
    menu_item 9 "services.tsv reparieren"
    menu_back
    read -rp "Auswahl: " c
    case "$c" in
      1) list_services; pause ;;
      2) add_service; pause ;;
      3) edit_service; pause ;;
      4) delete_service; pause ;;
      5) test_domain; pause ;;
      6) test_backends; pause ;;
      7) reload_caddy; pause ;;
      8) show_caddyfile; pause ;;
      9) repair_services; pause ;;
      b|B) return ;; 0) exit 0 ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}
sm_wg() {
  need_root; set +e
  while true; do
    hmenu_head "WireGuard Tunnel"
    menu_item 1 "Tunnel Status anzeigen"
    menu_item 2 "WireGuard Werte fuer UniFi anzeigen"
    menu_item 3 "UniFi Public Key aendern"
    menu_item 4 "Preshared Key neu generieren"
    menu_item 5 "Backend-Netze hinter UniFi aendern"
    menu_item 6 "MTU anzeigen/aendern"
    menu_item 7 "WireGuard neu starten"
    menu_item 8 "Route zum Backend testen"
    menu_item 9 "Handshake pruefen"
    menu_back
    read -rp "Auswahl: " c
    case "$c" in
      1) load_env; wg_status; pause ;;
      2) wg_values; pause ;;
      3) set_wg_key; pause ;;
      4) regenerate_psk; pause ;;
      5) edit_backend_networks; pause ;;
      6) edit_wg_mtu; pause ;;
      7) restart_wg; ok "WireGuard-Neustart angestossen."; pause ;;
      8) route_test; pause ;;
      9) handshake_check; pause ;;
      b|B) return ;; 0) exit 0 ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}
sm_caddy() {
  need_root; set +e
  while true; do
    hmenu_head "Caddy / HTTPS / Cloudflare"
    menu_item 1 "Caddy Status"
    menu_item 2 "Caddy reload (Caddyfile neu erzeugen)"
    menu_item 3 "Caddy restart / neu bauen"
    menu_item 4 "Caddy Stack neu erstellen (caddy-rebuild)"
    menu_item 5 "Caddy Logs anzeigen"
    menu_item 6 "Zertifikate anzeigen"
    menu_item 7 "Cloudflare API Token aendern"
    menu_item 8 "Cloudflare Token testen"
    menu_item 9 "DNS Challenge pruefen"
    menu_item 10 "HTTP/3 aktivieren/deaktivieren"
    menu_item 11 "IPv6 extern aktivieren/deaktivieren"
    menu_item 12 "IPv6 Status anzeigen"
    menu_back
    read -rp "Auswahl: " c
    case "$c" in
      1) caddy_status; pause ;;
      2) reload_caddy; pause ;;
      3) restart_caddy; pause ;;
      4) caddy_rebuild; pause ;;
      5) caddy_logs; pause ;;
      6) check_certs; pause ;;
      7) change_cloudflare_token; pause ;;
      8) verify_current_token; pause ;;
      9) dns_challenge_test; pause ;;
      10) security_http3_toggle; pause ;;
      11) ipv6_toggle; pause ;;
      12) ipv6_status; pause ;;
      b|B) return ;; 0) exit 0 ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}
sm_fail2ban() {
  need_root; set +e
  while true; do
    hmenu_head "Sicherheit > Fail2ban"
    load_env
    echo "   caddy-auth: $([[ "${CADDY_FAIL2BAN}" == "1" ]] && echo aktiv || echo inaktiv)  (maxretry=${F2B_CADDY_MAXRETRY} findtime=${F2B_CADDY_FINDTIME} bantime=${F2B_CADDY_BANTIME})"
    line
    menu_item 1 "Fail2ban Status"
    menu_item 2 "Gebannte IPs anzeigen"
    menu_item 3 "IP aus Liste entbannen"
    menu_item 4 "IP manuell entbannen"
    menu_item 5 "caddy-auth temporaer deaktivieren"
    menu_item 6 "caddy-auth wieder aktivieren"
    menu_item 7 "Schwellenwerte anzeigen/aendern"
    menu_item 8 "Fail2ban Config testen"
    menu_item 9 "Fail2ban neu starten"
    menu_back
    read -rp "Auswahl: " c
    case "$c" in
      1) f2b_status_overview; pause ;;
      2) f2b_show_banned_ips; pause ;;
      3) f2b_unban_select; pause ;;
      4) f2b_unban_manual; pause ;;
      5) f2b_caddy_disable; pause ;;
      6) f2b_caddy_enable; pause ;;
      7) f2b_thresholds; pause ;;
      8) f2b_test_config; pause ;;
      9) f2b_just_restart; pause ;;
      b|B) return ;; 0) exit 0 ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}
sm_security() {
  need_root; set +e
  while true; do
    hmenu_head "Sicherheit"
    menu_item 1 "Security Ampel"
    menu_item 2 "UFW Status"
    menu_item 3 "UFW Regeln anzeigen"
    menu_item 4 "Fail2ban verwalten"
    menu_item 5 "CrowdSec verwalten"
    menu_item 6 "SSH Hardening pruefen"
    menu_item 7 "Jellyfin Sicherheitscheckliste"
    menu_item 8 "Firewall neu anwenden"
    menu_back
    read -rp "Auswahl: " c
    case "$c" in
      1) security_minimal_check; pause ;;
      2) security_firewall; pause ;;
      3) ufw_rules; pause ;;
      4) sm_fail2ban ;;
      5) sm_crowdsec ;;
      6) security_ssh_status; pause ;;
      7) security_jellyfin_checklist; pause ;;
      8) apply_firewall; pause ;;
      b|B) return ;; 0) exit 0 ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}
sm_backup() {
  need_root; set +e
  while true; do
    hmenu_head "Backup & Restore"
    warn "Backups enthalten Secrets (WireGuard Keys, PSK, Cloudflare Token). Nicht unverschluesselt teilen."
    echo "   Hinweis: Vor jedem Restore wird automatisch ein Pre-Restore-Backup erstellt."
    line
    menu_item 1 "Backup erstellen"
    menu_item 2 "Backups anzeigen"
    menu_item 3 "Komplettes Restore (Software + Config)"
    menu_item 4 "Config Restore (nur Konfiguration)"
    menu_item 5 "Backup exportieren"
    menu_item 6 "Backup loeschen"
    menu_back
    read -rp "Auswahl: " c
    case "$c" in
      1) backup_create; pause ;;
      2) backup_list; pause ;;
      3) backup_restore; pause ;;
      4) restore_config; pause ;;
      5) backup_export_to_path; pause ;;
      6) backup_delete; pause ;;
      b|B) return ;; 0) exit 0 ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}
# Zeigt klar, was automatisch und was manuell aktualisiert wird (Bug P1).
update_policy_info() {
  info "OS-Sicherheitsupdates: automatisch (unattended-upgrades)"
  info "TLS-Zertifikate: automatisch durch Caddy (Let's Encrypt / DNS-01)"
  info "Caddy/Docker-Image: MANUELL ueber Updates & Wartung -> Docker / Caddy neu bauen"
  info "Caddy Cloudflare DNS Plugin: MANUELL (beim Caddy-Neubau enthalten)"
  info "HomeEdge selbst: MANUELL per Update (Updates & Wartung -> HomeEdge aktualisieren)"
  info "Hinweis: automatische Container-/Image-Updates sind bewusst NICHT aktiv (koennten Dienste ungeplant brechen)."
}

sm_updates() {
  need_root; set +e
  while true; do
    hmenu_head "Updates & Wartung"
    update_policy_info
    echo
    menu_item 1 "HomeEdge Version anzeigen"
    menu_item 2 "Nach Update suchen"
    menu_item 3 "HomeEdge aktualisieren"
    menu_item 4 "Systemupdates installieren"
    menu_item 5 "Docker / Caddy neu bauen"
    menu_item 6 "Server Auslastung anzeigen"
    menu_item 7 "Dienste neu starten"
    menu_item 8 "Rollback auf letztes Backup"
    menu_item 9 "System rebooten"
    menu_back
    read -rp "Auswahl: " c
    case "$c" in
      1) show_version; pause ;;
      2) check_for_update; pause ;;
      3) homeedge_repo_update; pause ;;
      4) system_update; pause ;;
      5) caddy_update; pause ;;
      6) system_usage; pause ;;
      7) restart_services; pause ;;
      8) homeedge_rollback; pause ;;
      9) do_reboot; pause ;;
      b|B) return ;; 0) exit 0 ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}
sm_logs() {
  need_root; set +e
  while true; do
    hmenu_head "Logs & Diagnose"
    menu_item 1 "Caddy Logs anzeigen"
    menu_item 2 "WireGuard Diagnose"
    menu_item 3 "Fail2ban Logs"
    menu_item 4 "UFW Logs"
    menu_item 5 "Docker Status / Logs"
    menu_item 6 "Diagnosebericht erstellen"
    menu_item 7 "Letzten Fehler anzeigen"
    menu_back
    read -rp "Auswahl: " c
    case "$c" in
      1) section "Caddy Logs"; docker logs --tail 100 caddy-edge 2>&1 | mask_secrets || true; pause ;;
      2) section "WireGuard Diagnose"; wg show 2>/dev/null || true; echo; ip -br addr show 2>/dev/null || true; pause ;;
      3) f2b_show_log ;;
      4) ufw_logs; pause ;;
      5) section "Docker"; docker ps -a 2>/dev/null || true; echo; docker logs --tail 50 caddy-edge 2>&1 | mask_secrets || true; pause ;;
      6) diag_report; pause ;;
      7) show_last_error; pause ;;
      b|B) return ;; 0) exit 0 ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}
sm_settings() {
  need_root; set +e
  while true; do
    hmenu_head "Einstellungen"
    menu_item 1 "Globale Konfiguration anzeigen"
    menu_item 2 "ACME E-Mail aendern"
    menu_item 3 "Cloudflare API Token aendern"
    menu_item 4 "VPS IP / Interface pruefen"
    menu_item 5 "Standard Backup-Verhalten"
    menu_item 6 "Expertenmodus aktivieren/deaktivieren"
    menu_item 7 "Alle globalen Einstellungen (Assistent)"
    menu_back
    read -rp "Auswahl: " c
    case "$c" in
      1) show_values; pause ;;
      2) edit_acme_email; pause ;;
      3) change_cloudflare_token; pause ;;
      4) show_network_interfaces; pause ;;
      5) backup_behavior_toggle; pause ;;
      6) expert_mode_toggle; pause ;;
      7) edit_settings; pause ;;
      b|B) return ;; 0) exit 0 ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}

sm_monitoring() {
  need_root; set +e
  while true; do
    hmenu_head "Monitoring / Beszel Agent"
    if beszel_installed; then info "Beszel Agent ist installiert ($(beszel_version))."; else info "Beszel Agent ist NICHT installiert."; fi
    info "Pull-Modus: Agent-Port NUR ueber WireGuard fuer die Hub-IP - nie oeffentlich. WebSocket-Modus: keine eingehende Freigabe."
    line
    menu_item 1 "Beszel Agent installieren"
    menu_item 2 "Konfigurieren / Port, Modus oder Hub-IP aendern"
    menu_item 3 "Beszel Agent Status anzeigen"
    menu_item 4 "Beszel Agent Logs anzeigen"
    menu_item 5 "Beszel Agent neu starten"
    menu_item 6 "Beszel Agent aktualisieren"
    menu_item 7 "Beszel Agent deinstallieren"
    menu_item 8 "Firewall-Regeln pruefen"
    menu_back
    read -rp "Auswahl: " c
    case "$c" in
      1) beszel_install; pause ;;
      2) beszel_reconfigure; pause ;;
      3) beszel_status; pause ;;
      4) beszel_logs -f ;;
      5) beszel_restart; pause ;;
      6) beszel_update; pause ;;
      7) beszel_uninstall; pause ;;
      8) beszel_check_firewall; pause ;;
      b|B) return ;; 0) exit 0 ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}

menu() {
  need_root
  set +e  # interaktive Menues: ein fehlschlagender Handler darf das Skript nicht beenden
  while true; do
    load_env
    hmenu_head "Hauptmenue"
    printf '  %bVPS%b %s   %bWG%b %s:%s   %bCaddy%b %s\n' "$C_CYAN" "$C_RESET" "${VPS_PUBLIC_HOST:-?}" "$C_CYAN" "$C_RESET" "$WG_IF" "$WG_PORT" "$C_CYAN" "$C_RESET" "$(caddy_is_running && echo laeuft || echo "nicht aktiv")"
    line
    menu_item 1 "Status / Ampel"
    menu_item 2 "Domains & Dienste"
    menu_item 3 "WireGuard Tunnel"
    menu_item 4 "Caddy / HTTPS / Cloudflare"
    menu_item 5 "Sicherheit"
    menu_item 6 "Backup & Restore"
    menu_item 7 "Updates & Wartung"
    menu_item 8 "Logs & Diagnose"
    menu_item 9 "Einstellungen"
    menu_item 10 "Monitoring / Beszel Agent (optional)"
    menu_item 0 "Beenden"
    line
    read -rp "Auswahl: " choice
    case "$choice" in
      1) sm_status ;;
      2) sm_services ;;
      3) sm_wg ;;
      4) sm_caddy ;;
      5) sm_security ;;
      6) sm_backup ;;
      7) sm_updates ;;
      8) sm_logs ;;
      9) sm_settings ;;
      10) sm_monitoring ;;
      0) exit 0 ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}

case "${1:-menu}" in
  --version|version) echo "${APP_NAME} ${APP_VERSION}" ;;
  menu) menu ;;
  values) show_values ;;
  status) status_all ;;
  health|ampel) health_check ;;
  usage|auslastung) system_usage ;;
  fail2ban|f2b) sm_fail2ban ;;
  network|interfaces|net) sm_settings ;;
  backup|restore|backup-menu) sm_backup ;;
  restore-config) need_root; restore_config ;;
  repair-services) need_root; repair_services "${2:-}" ;;
  validate-services) if validate_services_file; then ok "services.tsv valide."; else err "services.tsv ungueltig."; exit 1; fi ;;
  verify-setup|verify|apply-verify) verify_setup "${2:-}" ;;
  diagnose|diag) need_root; diag_report ;;
  migration-mode) need_root; load_env
    case "${2:-}" in
      on|1) MIGRATION_MODE=1; save_env; ok "MIGRATION_MODE=1 (DNS-Umzug laeuft - DNS auf altem VPS wird nur als Warnung gewertet)." ;;
      off|0) MIGRATION_MODE=0; save_env; ok "MIGRATION_MODE=0 (DNS muss auf diesen VPS zeigen)." ;;
      *) echo "Aktuell: MIGRATION_MODE=${MIGRATION_MODE:-0}"; echo "Nutzung: sudo homeedge migration-mode on|off" ;;
    esac ;;
  update|updates|wartung) sm_updates ;;
  update-policy|update-info) section "Update-Verhalten"; update_policy_info ;;
  caddy-update|caddy-rebuild-pull) need_root; caddy_update ;;
  migrate) need_root; homeedge_migrate "${2:-}" ;;
  mtu) need_root; edit_wg_mtu ;;
  self-update|update-repo|repo-update) need_root; homeedge_repo_update ;;
  check-update|check-updates) check_for_update ;;
  rollback) need_root; homeedge_rollback ;;
  update-url) need_root; homeedge_self_update ;;
  set-repo) need_root; configure_repo_source ;;
  backup-create) backup_create ;;
  backup-list) backup_list ;;
  show-interfaces) show_network_interfaces ;;
  select-interface) select_ext_interface ;;
  f2b-status) f2b_status_overview ;;
  f2b-banned) f2b_show_banned_ips ;;
  security|sec) sm_security ;;
  security-check|minimal-check) security_minimal_check ;;
  ports) security_ports ;;
  certs|cert-check) check_certs ;;
  test-domain) test_domain "${2:-}" ;;
  domains|dns) domains_status ;;
  ipv6) need_root; ipv6_toggle ;;
  ipv6-status) ipv6_status ;;
  set-token|cf-token) need_root; change_cloudflare_token ;;
  wg-menu) sm_wg ;;
  wg-values) wg_values ;;
  wg-status) wg_status ;;
  set-wg-public-key) set_wg_key ;;
  add-service) add_service ;;
  edit-service) edit_service ;;
  delete-service) delete_service ;;
  list-services) list_services ;;
  reload) reload_caddy ;;
  restart) restart_caddy ;;
  caddy-rebuild|rebuild-caddy) need_root; caddy_rebuild ;;
  caddy-logs|caddy-log) caddy_logs "${2:-120}" ;;
  monitoring|beszel) sm_monitoring ;;
  beszel-install) beszel_install ;;
  beszel-reconfigure|beszel-config) beszel_reconfigure ;;
  beszel-status) beszel_status ;;
  beszel-logs) beszel_logs "${2:-tail}" ;;
  beszel-restart) beszel_restart ;;
  beszel-update) beszel_update ;;
  beszel-uninstall) beszel_uninstall ;;
  beszel-check-firewall|beszel-lockdown) beszel_check_firewall ;;
  crowdsec|cs) sm_crowdsec ;;
  crowdsec-install) need_root; crowdsec_install ;;
  crowdsec-status) need_root; crowdsec_status ;;
  crowdsec-selftest) need_root; crowdsec_selftest ;;
  crowdsec-whitelist) need_root; crowdsec_whitelist_show ;;
  crowdsec-whitelist-edit) need_root; crowdsec_whitelist_menu ;;
  crowdsec-alerts) need_root; crowdsec_alerts ;;
  crowdsec-decisions) need_root; crowdsec_decisions ;;
  crowdsec-metrics) need_root; crowdsec_metrics ;;
  crowdsec-collections) need_root; crowdsec_collections ;;
  crowdsec-unban) need_root; crowdsec_unban "${2:-}" ;;
  crowdsec-update) need_root; crowdsec_update ;;
  crowdsec-console) need_root; crowdsec_console_enroll "${2:-}" ;;
  crowdsec-console-status) need_root; crowdsec_console_status ;;
  crowdsec-disable) need_root; crowdsec_disable ;;
  test-backends) test_backends ;;
  logs) show_logs ;;
  firewall) apply_firewall ;;
  settings) edit_settings ;;
  apply-all) apply_all ;;
  *) echo "Nutzung: sudo homeedge menu|health|certs|status|values|domains|test-domain|wg-menu|fail2ban|usage|network|backup|restore-config|repair-services|validate-services|verify-setup|migration-mode|wg-values|add-service|reload|restart|caddy-rebuild|caddy-logs|caddy-update|monitoring|beszel-install|beszel-reconfigure|beszel-status|beszel-logs|beszel-restart|beszel-update|beszel-uninstall|beszel-check-firewall|crowdsec|crowdsec-install|crowdsec-status|crowdsec-selftest|crowdsec-whitelist|crowdsec-whitelist-edit|crowdsec-alerts|crowdsec-decisions|crowdsec-metrics|crowdsec-collections|crowdsec-unban|crowdsec-update|crowdsec-console|crowdsec-console-status|crowdsec-disable|set-token|self-update|check-update|rollback|set-repo"; exit 1 ;;
esac
