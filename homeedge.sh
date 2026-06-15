#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="HomeEdge"
APP_CMD="homeedge"
APP_VERSION="0.9.3-homeedge"

CFG_DIR="/etc/homeedge"
EDGE_DIR="/root/homeedge"
CADDY_DIR="/opt/caddy-edge"
SERVICES_FILE="${CFG_DIR}/services.tsv"
ENV_FILE="${CFG_DIR}/homeedge.env"
KEY_DIR="${CFG_DIR}/keys"

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
ask_secret() { local p="$1" v; read -rsp "$p: " v; echo; echo "$v"; }
yesno() { local p="$1" d="${2:-n}" a; read -rp "$p [$d]: " a; a="${a:-$d}"; [[ "$a" =~ ^([YyJj]|yes|YES|Yes|ja|JA|Ja)$ ]]; }
q() { printf '%q' "$1"; }
pause() { echo; read -rp "Enter druecken zum Fortfahren..."; }

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
  ENABLE_HTTP3="${ENABLE_HTTP3:-1}"; HOMEEDGE_UPDATE_URL="${HOMEEDGE_UPDATE_URL:-}"
  HOMEEDGE_REPO="${HOMEEDGE_REPO:-fdreckmann/homedge}"; HOMEEDGE_BRANCH="${HOMEEDGE_BRANCH:-main}"
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    # Neue Variablen, die in aelteren Env-Dateien fehlen koennen, absichern:
    ENABLE_HTTP3="${ENABLE_HTTP3:-1}"; HOMEEDGE_UPDATE_URL="${HOMEEDGE_UPDATE_URL:-}"
    HOMEEDGE_REPO="${HOMEEDGE_REPO:-fdreckmann/homedge}"; HOMEEDGE_BRANCH="${HOMEEDGE_BRANCH:-main}"
  fi
}

save_env() {
  umask 077
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
ENABLE_HTTP3=$(q "${ENABLE_HTTP3:-1}")
HOMEEDGE_UPDATE_URL=$(q "${HOMEEDGE_UPDATE_URL:-}")
HOMEEDGE_REPO=$(q "${HOMEEDGE_REPO:-fdreckmann/homedge}")
HOMEEDGE_BRANCH=$(q "${HOMEEDGE_BRANCH:-main}")
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
  if [[ -f "$SERVICES_FILE" ]]; then
    while IFS=$'\t' read -r domain scheme ip port; do [[ -z "${domain:-}" ]] && continue; echo "  ${VPS_WG_IP} -> ${ip}:${port}/tcp  (${domain})" >> "${EDGE_DIR}/unifi-wireguard-werte.txt"; done < "$SERVICES_FILE"
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
  CLIENT_PUBLIC_KEY="$(ask "UniFi/Client PublicKey" "${CLIENT_PUBLIC_KEY:-}")"
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
  WG_PORT="$(ask "WireGuard UDP Port" "$WG_PORT")"
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

toggle_psk() {
  load_env
  if [[ "$USE_PSK" == "1" ]]; then
    if yesno "PresharedKey deaktivieren?" "n"; then USE_PSK="0"; save_env; write_wg_config; write_unifi_values; restart_wg; warn "PresharedKey auch in UniFi entfernen."; fi
  else
    if yesno "PresharedKey aktivieren?" "y"; then USE_PSK="1"; generate_keys; save_env; write_wg_config; write_unifi_values; restart_wg; warn "PresharedKey aus wg-values in UniFi eintragen."; fi
  fi
}

wg_submenu() {
  need_root
  while true; do
    load_env
    menu_head "HomeEdge - WireGuard konfigurieren"
    printf '  %bInterface%b: %s    %bPort%b: %s/udp\n' "$C_CYAN" "$C_RESET" "$WG_IF" "$C_CYAN" "$C_RESET" "$WG_PORT"
    printf '  %bVPS%b:       %s    %bClient%b: %s\n' "$C_CYAN" "$C_RESET" "$VPS_WG_ADDR" "$C_CYAN" "$C_RESET" "$CLIENT_WG_ADDR"
    printf '  %bBackend-Netze%b: %s\n' "$C_CYAN" "$C_RESET" "$HOME_SUBNET"
    printf '  %bUniFi PublicKey%b: %s    %bPSK%b: %s\n' "$C_CYAN" "$C_RESET" "$([[ -n "${CLIENT_PUBLIC_KEY:-}" ]] && echo gesetzt || echo fehlt)" "$C_CYAN" "$C_RESET" "$([[ "$USE_PSK" == "1" ]] && echo aktiv || echo aus)"
    line
    menu_item 1 "WireGuard/UniFi Werte anzeigen"
    menu_item 2 "WireGuard Status anzeigen"
    menu_item 3 "UniFi PublicKey setzen/aendern"
    menu_item 4 "WG Interface-Name aendern"
    menu_item 5 "WG UDP-Port aendern"
    menu_item 6 "VPS WG-Adresse aendern"
    menu_item 7 "UniFi/Client WG-Adresse aendern"
    menu_item 8 "Backend-Netze hinter UniFi aendern"
    menu_item 9 "PresharedKey an/aus"
    menu_item 10 "PresharedKey neu erzeugen"
    menu_item 11 "VPS WireGuard Keys neu erzeugen"
    menu_item 12 "WG-Konfig neu schreiben + Dienst neu starten"
    menu_item 13 "WG-Konfig anzeigen, Secrets maskiert"
    menu_item 14 "Backends testen"
    menu_item 0 "Zurueck"
    line
    read -rp "Auswahl: " choice
    case "$choice" in
      1) wg_values; pause ;;
      2) wg_status; pause ;;
      3) set_wg_key; pause ;;
      4) edit_wg_interface; pause ;;
      5) edit_wg_port; pause ;;
      6) edit_vps_wg_addr; pause ;;
      7) edit_client_wg_addr; pause ;;
      8) edit_backend_networks; pause ;;
      9) toggle_psk; pause ;;
      10) regenerate_psk; restart_wg; pause ;;
      11) regenerate_server_keys; restart_wg; pause ;;
      12) write_wg_config; write_unifi_values; restart_wg; ok "WireGuard-Konfig neu geschrieben."; pause ;;
      13) show_wg_config; pause ;;
      14) test_backends; pause ;;
      0) return ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}

# ------------------------------------------------------------
# Caddy / Fail2ban / Services
# ------------------------------------------------------------
write_caddy_stack() {
  load_env; mkdir -p "${CADDY_DIR}/data" "${CADDY_DIR}/config" "${CADDY_DIR}/logs"
  cat > "${CADDY_DIR}/.env" <<EOCADDY
ACME_EMAIL=${ACME_EMAIL}
CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}
EOCADDY
  chmod 600 "${CADDY_DIR}/.env"
  cat > "${CADDY_DIR}/Dockerfile" <<'EOCADDY'
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare
FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
EOCADDY
  cat > "${CADDY_DIR}/docker-compose.yml" <<EOCADDY
services:
  caddy:
    build: .
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

generate_caddyfile() {
  load_env; mkdir -p "$CADDY_DIR"; touch "$SERVICES_FILE"
  cat > "${CADDY_DIR}/Caddyfile" <<EOCADDY
{
    email {\$ACME_EMAIL}
    auto_https disable_redirects
EOCADDY

  if [[ "${ENABLE_HTTP3:-1}" != "1" ]]; then
    cat >> "${CADDY_DIR}/Caddyfile" <<'EOCADDY'
    servers {
        protocols h1 h2
    }
EOCADDY
  fi

  cat >> "${CADDY_DIR}/Caddyfile" <<'EOCADDY'
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
  while IFS=$'\t' read -r domain scheme ip port; do
    [[ -z "${domain:-}" ]] && continue
    cat >> "${CADDY_DIR}/Caddyfile" <<EOCADDY

${domain} {
    import common
EOCADDY
    if [[ "$scheme" == "https" ]]; then
      cat >> "${CADDY_DIR}/Caddyfile" <<EOCADDY
    reverse_proxy https://${ip}:${port} {
        transport http { tls_insecure_skip_verify }
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
    }
}
EOCADDY
    else
      cat >> "${CADDY_DIR}/Caddyfile" <<EOCADDY
    reverse_proxy http://${ip}:${port} {
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        header_up X-Forwarded-Host {host}
    }
}
EOCADDY
    fi
  done < "$SERVICES_FILE"
}

reload_caddy() {
  load_env; write_caddy_stack; generate_caddyfile; cd "$CADDY_DIR"
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^caddy-edge$'; then
    docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile || { err "Caddyfile ungueltig. Reload abgebrochen."; return 1; }
    docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile || docker compose up -d
  else
    docker compose build
    docker compose up -d
  fi
}

restart_caddy() { load_env; write_caddy_stack; generate_caddyfile; cd "$CADDY_DIR"; docker compose build; docker compose up -d; }

install_fail2ban() {
  load_env; mkdir -p /etc/fail2ban/jail.d
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
maxretry = 10
findtime = 10m
bantime = 1h
port = https
EOF2
  else
    rm -f /etc/fail2ban/jail.d/caddy-auth.local
  fi
  systemctl enable --now fail2ban; systemctl restart fail2ban
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

fail2ban_submenu() {
  need_root
  while true; do
    menu_head "HomeEdge - Fail2ban verwalten"
    menu_item 1 "Status anzeigen"
    menu_item 2 "Gebannte IPs anzeigen"
    menu_item 3 "IP aus Liste auswaehlen und entbannen"
    menu_item 4 "IP manuell entbannen"
    menu_item 5 "Fail2ban-Logs anzeigen"
    menu_item 6 "Filter testen"
    menu_item 7 "Fail2ban neu konfigurieren"
    menu_item 8 "Fail2ban neu starten"
    menu_item 0 "Zurueck"
    line
    read -rp "Auswahl: " choice
    case "$choice" in
      1) f2b_status_overview; pause ;;
      2) f2b_show_banned_ips; pause ;;
      3) f2b_unban_select; pause ;;
      4) f2b_unban_manual; pause ;;
      5) f2b_show_log ;;
      6) f2b_test_filter; pause ;;
      7) f2b_reconfigure; pause ;;
      8) f2b_just_restart; pause ;;
      0) return ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}

apply_firewall() {
  load_env
  section "Firewall neu anwenden"
  local cur_ssh_port; cur_ssh_port="$(awk '{print $4}' <<< "${SSH_CONNECTION:-}")"
  echo "UFW wird gesetzt: SSH ${SSH_PORT}/tcp, HTTPS 443/tcp, WireGuard ${WG_PORT}/udp"
  if [[ -n "$cur_ssh_port" && "$cur_ssh_port" != "${SSH_PORT}" ]]; then
    info "Aktive SSH-Sitzung laeuft auf Port ${cur_ssh_port}/tcp - dieser bleibt zusaetzlich offen (Schutz vor Aussperren)."
  fi
  warn "Achtung: falscher SSH-Port kann dich aussperren."
  read -rp "Firewall anwenden? [n]: " a; [[ "$a" =~ ^([YyJj]|yes|ja)$ ]] || return
  maybe_backup_before_change
  ufw --force reset; ufw default deny incoming; ufw default allow outgoing
  ufw allow "${SSH_PORT}/tcp"; ufw allow "443/tcp"; ufw allow "${WG_PORT}/udp"
  [[ -n "$cur_ssh_port" && "$cur_ssh_port" != "${SSH_PORT}" ]] && ufw allow "${cur_ssh_port}/tcp"
  ufw --force enable
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
  printf '%-28s %s\n' "Caddy HTTP/3 UDP443:" "$([[ "${ENABLE_HTTP3:-1}" == "1" ]] && echo aktiv || echo deaktiviert)"
  echo
  printf '%b\n' "${C_BOLD}Externe Dienste:${C_RESET}"
  list_services
}

list_services() { if [[ ! -f "$SERVICES_FILE" || ! -s "$SERVICES_FILE" ]]; then warn "Keine Dienste vorhanden."; return; fi; nl -w2 -s'. ' "$SERVICES_FILE" | sed $'s/\t/ | /g'; }

validate_service() {
  local domain="$1" scheme="$2" ip="$3" port="$4"
  if [[ -z "$domain" || "$domain" =~ [[:space:]] ]]; then err "Ungueltige Domain (leer oder enthaelt Leerzeichen)."; return 1; fi
  if [[ "$scheme" != "http" && "$scheme" != "https" ]]; then err "Scheme muss 'http' oder 'https' sein."; return 1; fi
  if [[ -z "$ip" || "$ip" =~ [[:space:]] ]]; then err "Ungueltige Backend-Adresse (leer oder enthaelt Leerzeichen)."; return 1; fi
  if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then err "Ungueltiger Port: '$port' (erwartet 1-65535)."; return 1; fi
  return 0
}

add_service() {
  load_env; touch "$SERVICES_FILE"
  section "Neuen externen Dienst hinzufuegen"
  local domain scheme ip port
  domain="$(ask "Domain, z.B. jellyfin.example.de")"; scheme="$(ask "Backend Scheme http/https" "http")"; ip="$(ask "Backend IP im Heimnetz")"; port="$(ask "Backend Port")"
  validate_service "$domain" "$scheme" "$ip" "$port" || return 1
  printf "%s\t%s\t%s\t%s\n" "$domain" "$scheme" "$ip" "$port" >> "$SERVICES_FILE"
  write_unifi_values; reload_caddy
  ok "Dienst hinzugefuegt."
  warn "UniFi Firewall erlauben: ${VPS_WG_IP} -> ${ip}:${port}/tcp"
}

edit_service() {
  [[ -f "$SERVICES_FILE" && -s "$SERVICES_FILE" ]] || { warn "Keine Dienste vorhanden."; return; }
  list_services; local num; num="$(ask "Nummer aendern")"; mapfile -t lines < "$SERVICES_FILE"; local idx=$((num-1))
  if (( idx < 0 || idx >= ${#lines[@]} )); then err "Ungueltige Nummer."; return; fi
  local old_domain old_scheme old_ip old_port; IFS=$'\t' read -r old_domain old_scheme old_ip old_port <<< "${lines[$idx]}"
  local domain scheme ip port
  domain="$(ask "Domain" "$old_domain")"; scheme="$(ask "Backend Scheme http/https" "$old_scheme")"; ip="$(ask "Backend IP" "$old_ip")"; port="$(ask "Backend Port" "$old_port")"
  validate_service "$domain" "$scheme" "$ip" "$port" || return 1
  lines[$idx]="${domain}"$'\t'"${scheme}"$'\t'"${ip}"$'\t'"${port}"; printf "%s\n" "${lines[@]}" > "$SERVICES_FILE"
  write_unifi_values; reload_caddy; ok "Dienst aktualisiert."
}

delete_service() {
  [[ -f "$SERVICES_FILE" && -s "$SERVICES_FILE" ]] || { warn "Keine Dienste vorhanden."; return; }
  list_services; local num; num="$(ask "Nummer loeschen")"; mapfile -t lines < "$SERVICES_FILE"; local idx=$((num-1))
  if (( idx < 0 || idx >= ${#lines[@]} )); then err "Ungueltige Nummer."; return; fi
  unset 'lines[$idx]'; printf "%s\n" "${lines[@]}" > "$SERVICES_FILE"; write_unifi_values; reload_caddy; ok "Dienst geloescht."
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
  VPS_PUBLIC_HOST="$(ask "VPS Public Host/IP" "$VPS_PUBLIC_HOST")"; SSH_PORT="$(ask "SSH Port" "$SSH_PORT")"
  ACME_EMAIL="$(ask "ACME E-Mail" "$ACME_EMAIL")"
  if yesno "Cloudflare Token aendern?" "n"; then CLOUDFLARE_API_TOKEN="$(ask_secret "Neuer Cloudflare Token")"; fi
  if yesno "Caddy/Jellyfin Fail2ban aktivieren?" "$([[ "$CADDY_FAIL2BAN" == "1" ]] && echo y || echo n)"; then CADDY_FAIL2BAN="1"; else CADDY_FAIL2BAN="0"; fi
  save_env; write_unifi_values; reload_caddy; install_fail2ban
  ok "Globale Einstellungen gespeichert. WireGuard aenderst du jetzt separat im WireGuard-Menue."
}

test_backends() {
  [[ -f "$SERVICES_FILE" && -s "$SERVICES_FILE" ]] || { warn "Keine Dienste vorhanden."; return; }
  section "Backend-Test"
  while IFS=$'\t' read -r domain scheme ip port; do
    [[ -z "${domain:-}" ]] && continue; printf '%b\n' "${C_BOLD}${domain}${C_RESET} -> ${scheme}://${ip}:${port}"
    if [[ "$scheme" == "https" ]]; then curl -k -I --connect-timeout 5 "https://${ip}:${port}" || true; else curl -I --connect-timeout 5 "http://${ip}:${port}" || true; fi; echo
  done < "$SERVICES_FILE"
}

status_all() {
  section "Status"
  show_values || true
  section "WireGuard"; wg show 2>/dev/null || true
  section "Docker"; docker ps 2>/dev/null || true
  section "Caddy Logs"; docker logs --tail 30 caddy-edge 2>/dev/null || true
  section "Fail2ban"; fail2ban-client status 2>/dev/null || true; fail2ban-client status sshd 2>/dev/null || true; fail2ban-client status caddy-auth 2>/dev/null || true
  section "UFW"; ufw status verbose 2>/dev/null || true
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
  case "$c" in 1) docker logs -f --tail 100 caddy-edge ;; 2) tail -f "${CADDY_DIR}/logs/access.log" ;; 3) tail -f /var/log/fail2ban.log ;; 4) watch -n 2 wg show ;; 0) return ;; *) err "Ungueltig." ;; esac
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
# Backup / Restore
# ------------------------------------------------------------
BACKUP_DIR="${EDGE_DIR}/backups"

backup_create() {
  need_root
  load_env
  section "Backup erstellen"
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
  [[ -d /etc/homeedge ]] && items+=("etc/homeedge")
  [[ -d /etc/wireguard ]] && items+=("etc/wireguard")
  [[ -d /opt/caddy-edge ]] && items+=("opt/caddy-edge/Caddyfile" "opt/caddy-edge/Dockerfile" "opt/caddy-edge/docker-compose.yml" "opt/caddy-edge/.env" "opt/caddy-edge/data" "opt/caddy-edge/config")
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

backup_restore() {
  need_root
  section "Backup wiederherstellen"
  local f
  f="$(backup_select_file)" || return 0
  echo
  warn "Restore stellt Konfigurationen wieder her. Aktueller Zustand wird vorher gesichert."
  warn "Backup enthaelt Secrets und ueberschreibt u.a. HomeEdge, WireGuard, Caddy und Fail2ban-Konfig."
  echo
  tar -tzf "$f" | sed -n '1,60p'
  echo
  if ! yesno "Dieses Backup wirklich wiederherstellen?" "n"; then
    warn "Abgebrochen."
    return 0
  fi

  backup_create || true

  info "Dienste werden kurz gestoppt/neugeladen..."
  systemctl stop "wg-quick@${WG_IF:-unifi}" 2>/dev/null || true

  tar -xzf "$f" -C /
  chmod 600 /etc/homeedge/homeedge.env 2>/dev/null || true
  chmod 600 /etc/wireguard/*.conf /etc/wireguard/*.template 2>/dev/null || true
  if [[ -f /usr/local/bin/homeedge ]]; then
    chmod +x /usr/local/bin/homeedge 2>/dev/null || true
    ln -sf /usr/local/bin/homeedge /usr/local/bin/edgectl 2>/dev/null || true
  fi

  load_env || true
  if [[ -d "$CADDY_DIR" && -f "$CADDY_DIR/docker-compose.yml" ]]; then
    (cd "$CADDY_DIR" && docker compose up -d) || warn "Caddy konnte nicht automatisch gestartet werden. Bitte pruefen."
  fi
  systemctl restart fail2ban 2>/dev/null || true
  restart_wg || true

  ok "Restore abgeschlossen."
  warn "Bitte pruefen: sudo homeedge health"
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

backup_submenu() {
  need_root
  while true; do
    menu_head "HomeEdge - Backup / Restore"
    menu_item 1 "Backup jetzt erstellen"
    menu_item 2 "Backups anzeigen"
    menu_item 3 "Backup-Inhalt anzeigen"
    menu_item 4 "Backup wiederherstellen"
    menu_item 5 "Backup exportieren/kopieren"
    menu_item 6 "Backup loeschen"
    menu_item 0 "Zurueck"
    line
    read -rp "Auswahl: " choice
    case "$choice" in
      1) backup_create; pause ;;
      2) backup_list; pause ;;
      3) backup_show_content; pause ;;
      4) backup_restore; pause ;;
      5) backup_export_to_path; pause ;;
      6) backup_delete; pause ;;
      0) return ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
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

network_submenu() {
  need_root
  while true; do
    load_env
    menu_head "HomeEdge - Netzwerk / Interfaces"
    local def src
    def="$(default_interface)"; src="$(default_source_ip)"
    printf '  %bAktuelles EXT_IF%b: %s\n' "$C_CYAN" "$C_RESET" "${EXT_IF:-<leer>}"
    printf '  %bDefault-Interface%b: %s\n' "$C_CYAN" "$C_RESET" "${def:-<keins>}"
    printf '  %bSource-IP Internet%b: %s\n' "$C_CYAN" "$C_RESET" "${src:-<keine>}"
    line
    menu_item 1 "Netzwerkadapter mit IPs anzeigen"
    menu_item 2 "Externes Interface aus Liste auswaehlen"
    menu_item 3 "Default-Route anzeigen"
    menu_item 4 "IP-Adressen kompakt anzeigen"
    menu_item 5 "Route zu 1.1.1.1 testen"
    menu_item 0 "Zurueck"
    line
    read -rp "Auswahl: " choice
    case "$choice" in
      1) show_network_interfaces; pause ;;
      2) select_ext_interface; pause ;;
      3) section "Default-Route"; ip route show default || true; pause ;;
      4) section "IP-Adressen"; ip -br addr; pause ;;
      5) section "Route-Test"; ip route get 1.1.1.1 || true; pause ;;
      0) return ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}

apply_all() { need_root; generate_keys; write_wg_config; write_unifi_values; reload_caddy; install_fail2ban; restart_wg; }

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
  else
    detail="$(tr '\n' ' ' < "$tmp" | cut -c1-140)"
    _health_line red "TLS ${domain}" "Fehler: ${detail:-kein TLS/Cert}"
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

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^caddy-edge$'; then
    err "Caddy laeuft nicht. Zertifikate koennen nicht sauber getestet werden."
    return 1
  fi

  while IFS=$'\t' read -r domain scheme ip port; do
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
  [[ -f "$SERVICES_FILE" && -s "$SERVICES_FILE" ]] && _health_line green "Externe Dienste" "konfiguriert" || _health_line yellow "Externe Dienste" "keine Dienste eingetragen"

  if systemctl is-active --quiet docker 2>/dev/null; then _health_line green "Docker" "aktiv"; else _health_line red "Docker" "nicht aktiv"; fi

  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^caddy-edge$'; then
    _health_line green "Caddy Container" "laeuft"
    if (cd "$CADDY_DIR" && docker compose exec -T caddy caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1); then
      _health_line green "Caddy Konfig" "valid"
    else
      _health_line red "Caddy Konfig" "ungueltig oder nicht pruefbar"
    fi
  else
    _health_line red "Caddy Container" "laeuft nicht"
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

  if [[ -f "$SERVICES_FILE" && -s "$SERVICES_FILE" ]]; then
    local domain scheme ip port route code rc url tmp msg dns
    while IFS=$'\t' read -r domain scheme ip port; do
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
  fi

  check_certs || true

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
  info "127.0.0.1:2019 ist Caddy Admin API nur lokal und von außen nicht erreichbar. Das ist ok."
  if ss -u -lpnH 2>/dev/null | awk '{print $5}' | grep -qE '(^|:)443$'; then
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
  section "Caddy HTTP/3 / UDP 443"
  if [[ "${ENABLE_HTTP3:-1}" == "1" ]]; then
    warn "HTTP/3 ist aktuell aktiv. Dadurch lauscht Caddy zusaetzlich auf UDP 443."
    if yesno "HTTP/3 deaktivieren und Caddy neu laden?" "y"; then
      ENABLE_HTTP3="0"; save_env; reload_caddy
      ok "HTTP/3 deaktiviert. Pruefe danach: sudo ss -tulpn"
    fi
  else
    info "HTTP/3 ist aktuell deaktiviert. Caddy nutzt nur HTTP/1.1 und HTTP/2."
    if yesno "HTTP/3 wieder aktivieren?" "n"; then
      ENABLE_HTTP3="1"; save_env; reload_caddy
      ok "HTTP/3 aktiviert. UDP 443 kann danach wieder sichtbar sein."
    fi
  fi
}

security_minimal_check() {
  load_env
  section "Minimal-Sicherheitscheck"

  local bad=0 warnc=0

  if ufw status 2>/dev/null | grep -qi "Status: active\|Status: aktiv"; then ok "UFW aktiv"; else err "UFW nicht aktiv"; bad=$((bad+1)); fi
  if systemctl is-active --quiet fail2ban 2>/dev/null; then ok "Fail2ban aktiv"; else err "Fail2ban nicht aktiv"; bad=$((bad+1)); fi
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^caddy-edge$'; then ok "Caddy Container laeuft"; else err "Caddy Container laeuft nicht"; bad=$((bad+1)); fi
  if ip link show "$WG_IF" >/dev/null 2>&1; then ok "WireGuard Interface ${WG_IF} vorhanden"; else err "WireGuard Interface fehlt"; bad=$((bad+1)); fi

  if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE "(^|:)${SSH_PORT}$"; then ok "SSH Port ${SSH_PORT}/tcp offen"; else warn "SSH Port ${SSH_PORT}/tcp nicht sichtbar"; warnc=$((warnc+1)); fi
  if ss -tlnH 2>/dev/null | awk '{print $4}' | grep -qE '(^|:)443$'; then ok "HTTPS 443/tcp offen"; else err "HTTPS 443/tcp nicht offen"; bad=$((bad+1)); fi
  if ss -ulnH 2>/dev/null | awk '{print $4}' | grep -qE "(^|:)${WG_PORT}$"; then ok "WireGuard ${WG_PORT}/udp offen"; else err "WireGuard ${WG_PORT}/udp nicht offen"; bad=$((bad+1)); fi

  if ss -u -lpnH 2>/dev/null | awk '{print $5}' | grep -qE '(^|:)443$'; then
    if [[ "${ENABLE_HTTP3:-1}" == "1" ]]; then warn "UDP 443 offen wegen HTTP/3/QUIC (optional)"; warnc=$((warnc+1)); else warn "UDP 443 offen, obwohl HTTP/3 deaktiviert sein sollte"; warnc=$((warnc+1)); fi
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

security_submenu() {
  need_root
  while true; do
    menu_head "HomeEdge - Sicherheitsmenue"
    menu_item 1 "Ampel-Check komplett"
    menu_item 2 "Offene Ports anzeigen und bewerten"
    menu_item 3 "UFW Status anzeigen"
    menu_item 4 "SSH-Hardening pruefen"
    menu_item 5 "Fail2ban pruefen"
    menu_item 6 "Caddy / Zertifikate pruefen"
    menu_item 7 "WireGuard pruefen"
    menu_item 8 "HTTP/3 UDP 443 aktivieren/deaktivieren"
    menu_item 9 "Jellyfin/UniFi Sicherheitscheckliste"
    menu_item 0 "Zurueck"
    line
    read -rp "Auswahl: " choice
    case "$choice" in
      1) health_check; pause ;;
      2) security_ports; pause ;;
      3) security_firewall; pause ;;
      4) security_ssh_status; pause ;;
      5) security_fail2ban; pause ;;
      6) check_certs; pause ;;
      7) security_wireguard; pause ;;
      8) security_http3_toggle; pause ;;
      9) security_jellyfin_checklist; pause ;;
      0) return ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}

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

caddy_update() {
  section "Caddy / Docker aktualisieren"
  if [[ ! -f "${CADDY_DIR}/docker-compose.yml" ]]; then err "Caddy Compose-Datei nicht gefunden."; return 1; fi
  cd "$CADDY_DIR"
  docker compose build --pull
  docker compose up -d
  ok "Caddy wurde neu gebaut/gestartet."
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
  ok "HomeEdge aktualisiert auf Version: ${new_ver:-unbekannt}"
  info "Vorherige Version gesichert: ${old}"
  /usr/local/bin/homeedge --version || true
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
  local tmp; tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  if ! curl -fsSL "$url" -o "$tmp"; then
    err "Download fehlgeschlagen. Pruefe Repo/Branch und ob homeedge.sh dort existiert."
    err "Versuchte URL: ${url}"
    return 1
  fi
  # Optionale Checksumme: falls <url>.sha256 existiert, wird sie geprueft.
  local sum_remote sum_local
  if sum_remote="$(curl -fsSL "${url}.sha256" 2>/dev/null)" && [[ -n "$sum_remote" ]] && command -v sha256sum >/dev/null 2>&1; then
    sum_remote="$(awk '{print $1}' <<< "$sum_remote")"
    sum_local="$(sha256sum "$tmp" | awk '{print $1}')"
    if [[ "$sum_remote" != "$sum_local" ]]; then
      err "Checksumme stimmt nicht ueberein. Abbruch, nichts geaendert."
      err "erwartet: ${sum_remote}"; err "erhalten: ${sum_local}"
      return 1
    fi
    ok "Checksumme verifiziert (sha256)."
  else
    info "Keine Checksumme gefunden (optional). Pruefung erfolgt ueber Marker + bash -n."
  fi
  _install_homeedge_from_file "$tmp" || return 1
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
  local tmp; tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN
  if ! curl -fsSL "$HOMEEDGE_UPDATE_URL" -o "$tmp"; then err "Download fehlgeschlagen."; return 1; fi
  _install_homeedge_from_file "$tmp" || return 1
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

# Bietet vor kritischen Aenderungen ein Backup an (Default Ja).
maybe_backup_before_change() {
  if yesno "Vor dieser Aenderung Backup erstellen?" "y"; then
    backup_create || warn "Backup fehlgeschlagen - fahre fort."
  fi
}

updates_submenu() {
  need_root
  while true; do
    menu_head "HomeEdge - Wartung / Updates"
    menu_item 1 "HomeEdge-Version anzeigen"
    menu_item 2 "Nach Update suchen"
    menu_item 3 "HomeEdge aus GitHub aktualisieren (empfohlen)"
    menu_item 4 "Caddy/Docker neu bauen und aktualisieren"
    menu_item 5 "Systemupdates installieren"
    menu_item 6 "Backup vor Update erstellen"
    menu_item 7 "Rollback auf letztes Backup"
    menu_item 8 "Update-Quelle (Repo/Branch) konfigurieren"
    menu_item 9 "Update von fester URL (Release-Asset)"
    menu_item 0 "Zurueck"
    line
    read -rp "Auswahl: " choice
    case "$choice" in
      1) show_version; pause ;;
      2) check_for_update; pause ;;
      3) homeedge_repo_update; pause ;;
      4) caddy_update; pause ;;
      5) system_update; pause ;;
      6) backup_create; pause ;;
      7) homeedge_rollback; pause ;;
      8) configure_repo_source; pause ;;
      9) homeedge_self_update; pause ;;
      0) return ;;
      *) err "Ungueltige Auswahl."; sleep 1 ;;
    esac
  done
}

menu() {
  need_root
  while true; do
    load_env
    menu_head "HomeEdge - Secure VPS Gateway for Home Services"
    printf '  %bVPS%b %s  %bWG%b %s:%s  %bCaddy%b %s\n' "$C_CYAN" "$C_RESET" "${VPS_PUBLIC_HOST:-?}" "$C_CYAN" "$C_RESET" "$WG_IF" "$WG_PORT" "$C_CYAN" "$C_RESET" "$(docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^caddy-edge$' && echo laeuft || echo unbekannt)"
    line
    menu_item 1 "Uebersicht / aktuelle Werte"
    menu_item 2 "Ampel-Check: Sicherheit / Aktiv / Zertifikate"
    menu_item 3 "Status anzeigen"
    menu_item 4 "Externe Dienste anzeigen"
    menu_item 5 "Externen Dienst hinzufuegen"
    menu_item 6 "Externen Dienst aendern"
    menu_item 7 "Externen Dienst loeschen"
    menu_item 8 "Globale Einstellungen aendern (VPS, SSH, Cloudflare, Fail2ban)"
    menu_item 9 "WireGuard konfigurieren"
    menu_item 10 "Backends testen"
    menu_item 11 "Zertifikate pruefen"
    menu_item 12 "Caddyfile neu erzeugen + reload"
    menu_item 13 "Caddy neu starten / neu bauen"
    menu_item 14 "Logs anzeigen"
    menu_item 15 "Fail2ban verwalten"
    menu_item 16 "Firewall neu anwenden"
    menu_item 17 "Sicherheitsmenue"
    menu_item 18 "Server-Auslastung anzeigen"
    menu_item 19 "Netzwerk / Interfaces"
    menu_item 20 "Backup / Restore"
    menu_item 21 "Wartung / Updates"
    menu_item 0 "Ende"
    line
    read -rp "Auswahl: " choice
    case "$choice" in
      1) show_values; pause ;;
      2) health_check; pause ;;
      3) status_all; pause ;;
      4) list_services; pause ;;
      5) add_service; pause ;;
      6) edit_service; pause ;;
      7) delete_service; pause ;;
      8) edit_settings; pause ;;
      9) wg_submenu ;;
      10) test_backends; pause ;;
      11) check_certs; pause ;;
      12) generate_caddyfile; reload_caddy; pause ;;
      13) restart_caddy; pause ;;
      14) show_logs ;;
      15) fail2ban_submenu ;;
      16) apply_firewall; pause ;;
      17) security_submenu ;;
      18) system_usage; pause ;;
      19) network_submenu ;;
      20) backup_submenu ;;
      21) updates_submenu ;;
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
  fail2ban|f2b) fail2ban_submenu ;;
  network|interfaces|net) network_submenu ;;
  backup|restore|backup-menu) backup_submenu ;;
  update|updates|wartung) updates_submenu ;;
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
  security|sec) security_submenu ;;
  security-check|minimal-check) security_minimal_check ;;
  ports) security_ports ;;
  certs|cert-check) check_certs ;;
  wg-menu) wg_submenu ;;
  wg-values) wg_values ;;
  wg-status) wg_status ;;
  set-wg-public-key) set_wg_key ;;
  add-service) add_service ;;
  edit-service) edit_service ;;
  delete-service) delete_service ;;
  list-services) list_services ;;
  reload) generate_caddyfile; reload_caddy ;;
  restart) restart_caddy ;;
  test-backends) test_backends ;;
  logs) show_logs ;;
  firewall) apply_firewall ;;
  settings) edit_settings ;;
  apply-all) apply_all ;;
  *) echo "Nutzung: sudo homeedge menu|health|certs|status|values|wg-menu|fail2ban|usage|network|backup|wg-values|add-service|reload|self-update|check-update|rollback|set-repo"; exit 1 ;;
esac
