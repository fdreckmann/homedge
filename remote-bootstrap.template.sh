#!/usr/bin/env bash
set -Eeuo pipefail

# Dieses Bootstrap-Script enthaelt eingebettete Secrets (base64) wie den
# Cloudflare API Token. Beim Beenden raeumen wir die temporaere Datei weg,
# damit keine Secrets in /tmp liegen bleiben.
trap 'rm -f "${BASH_SOURCE[0]}" /tmp/edge-bootstrap.sh /tmp/edge-bootstrap-direct.sh 2>/dev/null || true' EXIT

b64d() { printf '%s' "$1" | base64 -d; }

EXT_IF="$(b64d "__EXT_IF_B64__")"
VPS_PUBLIC_HOST="$(b64d "__VPS_PUBLIC_HOST_B64__")"
SSH_PORT="$(b64d "__SSH_PORT_B64__")"
WG_IF="$(b64d "__WG_IF_B64__")"
WG_PORT="$(b64d "__WG_PORT_B64__")"
WG_MTU="$(b64d "__WG_MTU_B64__")"; WG_MTU="${WG_MTU:-1280}"
VPS_WG_ADDR="$(b64d "__VPS_WG_ADDR_B64__")"
CLIENT_WG_ADDR="$(b64d "__CLIENT_WG_ADDR_B64__")"
HOME_SUBNET="$(b64d "__HOME_SUBNET_B64__")"
ACME_EMAIL="$(b64d "__ACME_EMAIL_B64__")"
CLOUDFLARE_API_TOKEN="$(b64d "__CF_TOKEN_B64__" | tr -d '\r\n[:space:]')"
USE_PSK="$(b64d "__USE_PSK_B64__")"
CADDY_FAIL2BAN="$(b64d "__CADDY_FAIL2BAN_B64__")"
ENABLE_HTTP3="$(b64d "__ENABLE_HTTP3_B64__")"; ENABLE_HTTP3="${ENABLE_HTTP3:-0}"
CLIENT_PUBLIC_KEY="$(b64d "__CLIENT_PUBLIC_KEY_B64__")"
SERVICES_TSV="$(b64d "__SERVICES_TSV_B64__")"
SWAP_MB="$(b64d "__SWAP_MB_B64__")"
CREATE_ADMIN="$(b64d "__CREATE_ADMIN_B64__")"
ADMIN_USER="$(b64d "__ADMIN_USER_B64__")"
ADMIN_PUBKEY="$(b64d "__ADMIN_PUBKEY_B64__")"
HOMEEDGE_B64="__HOMEEDGE_B64__"

VPS_WG_IP="${VPS_WG_ADDR%%/*}"
CLIENT_WG_IP="${CLIENT_WG_ADDR%%/*}"

CFG_DIR="/etc/homeedge"
EDGE_DIR="/root/homeedge"
CADDY_DIR="/opt/caddy-edge"
SERVICES_FILE="${CFG_DIR}/services.tsv"
ENV_FILE="${CFG_DIR}/homeedge.env"
KEY_DIR="${CFG_DIR}/keys"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Dieses Script muss als root auf dem VPS laufen."
  exit 1
fi

mkdir -p "$CFG_DIR" "$EDGE_DIR" "$KEY_DIR" "$CADDY_DIR"

DATE_TAG="$(date +%Y%m%d-%H%M%S)"
mkdir -p "${EDGE_DIR}/backup-${DATE_TAG}"
ss -ltnp > "${EDGE_DIR}/backup-${DATE_TAG}/ss-before.txt" || true
ip route > "${EDGE_DIR}/backup-${DATE_TAG}/routes-before.txt" || true
command -v iptables-save >/dev/null 2>&1 && iptables-save > "${EDGE_DIR}/backup-${DATE_TAG}/iptables-before.rules" || true
wg show > "${EDGE_DIR}/backup-${DATE_TAG}/wg-before.txt" 2>/dev/null || true

echo "[1/10] Basispakete installieren..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl gnupg lsb-release apt-transport-https \
  wireguard iptables fail2ban \
  unattended-upgrades jq nano dnsutils net-tools ufw logrotate sudo

echo "[2/10] Swap vorbereiten..."
if [[ ! -f /swapfile ]]; then
  fallocate -l "${SWAP_MB}M" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="${SWAP_MB}"
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile none swap sw 0 0" >> /etc/fstab
else
  swapon /swapfile 2>/dev/null || true
fi

echo "[3/10] IP Forwarding aktivieren..."
# Nur IPv4-Forwarding noetig (Backend-Weg laeuft IPv4 ueber WireGuard).
# IPv6-Forwarding wird NICHT pauschal aktiviert; IPv6 betrifft nur externen
# Zugriff (Caddy) und braucht kein Forwarding.
cat >/etc/sysctl.d/99-homeedge.conf <<EOF
net.ipv4.ip_forward=1
EOF
sysctl --system >/dev/null || true

echo "[4/10] Docker installieren..."
install -m 0755 -d /etc/apt/keyrings
. /etc/os-release

case "${ID}" in
  ubuntu)
    DOCKER_REPO_OS="ubuntu"
    ;;
  debian)
    DOCKER_REPO_OS="debian"
    ;;
  *)
    echo "Nicht unterstuetztes OS fuer dieses Paket: ${ID:-unknown}. Unterstuetzt: Debian/Ubuntu."
    exit 1
    ;;
esac

if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
  curl -fsSL "https://download.docker.com/linux/${DOCKER_REPO_OS}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi

cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_REPO_OS} ${VERSION_CODENAME} stable
EOF
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

echo "[5/10] HomeEdge installieren..."
printf '%s' "$HOMEEDGE_B64" | base64 -d > /usr/local/bin/homeedge
chmod +x /usr/local/bin/homeedge
ln -sf /usr/local/bin/homeedge /usr/local/bin/edgectl

echo "[6/10] HomeEdge Grundkonfiguration schreiben..."
cat > "${ENV_FILE}" <<EOF
EXT_IF=$(printf '%q' "${EXT_IF}")
VPS_PUBLIC_HOST=$(printf '%q' "${VPS_PUBLIC_HOST}")
SSH_PORT=$(printf '%q' "${SSH_PORT}")
WG_IF=$(printf '%q' "${WG_IF}")
WG_PORT=$(printf '%q' "${WG_PORT}")
WG_MTU=$(printf '%q' "${WG_MTU:-1280}")
VPS_WG_ADDR=$(printf '%q' "${VPS_WG_ADDR}")
VPS_WG_IP=$(printf '%q' "${VPS_WG_IP}")
CLIENT_WG_ADDR=$(printf '%q' "${CLIENT_WG_ADDR}")
CLIENT_WG_IP=$(printf '%q' "${CLIENT_WG_IP}")
HOME_SUBNET=$(printf '%q' "${HOME_SUBNET}")
ACME_EMAIL=$(printf '%q' "${ACME_EMAIL}")
CLOUDFLARE_API_TOKEN=$(printf '%q' "${CLOUDFLARE_API_TOKEN}")
USE_PSK=$(printf '%q' "${USE_PSK}")
CADDY_FAIL2BAN=$(printf '%q' "${CADDY_FAIL2BAN}")
CLIENT_PUBLIC_KEY=$(printf '%q' "${CLIENT_PUBLIC_KEY}")
ENABLE_HTTP3=$(printf '%q' "${ENABLE_HTTP3:-0}")
ENABLE_IPV6=$(printf '%q' "${ENABLE_IPV6:-0}")
MIGRATION_MODE=$(printf '%q' "${MIGRATION_MODE:-0}")
HOMEEDGE_REPO=$(printf '%q' "${HOMEEDGE_REPO:-fdreckmann/homedge}")
HOMEEDGE_BRANCH=$(printf '%q' "${HOMEEDGE_BRANCH:-main}")
EOF
chmod 600 "${ENV_FILE}"
printf '%s' "${SERVICES_TSV}" > "${SERVICES_FILE}"

echo "[7/10] WireGuard, Caddy und Fail2ban anwenden..."
# Fehler hier nicht sofort abbrechen: die finale Verifikation (verify-setup)
# bewertet den Gesamtzustand und gibt eine klare Fehlerliste aus.
homeedge apply-all || echo "[WARN] apply-all meldete Probleme - finale Verifikation entscheidet."

echo "[8/10] Automatische Updates aktivieren..."
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades || true

echo "[9/10] UFW Firewall aktivieren..."
# Aktiven SSH-Port der laufenden Sitzung ermitteln, um Aussperren zu verhindern,
# falls SSH_PORT abweicht (HomeEdge aendert den sshd-Port nicht selbst).
CUR_SSH_PORT="$(awk '{print $4}' <<< "${SSH_CONNECTION:-}")"
# IPv6 in UFW verwalten (default deny fuer v6), Service-Freigabe v6 nur bei ENABLE_IPV6=1.
if [[ -f /etc/default/ufw ]]; then
  if grep -qE '^IPV6=' /etc/default/ufw; then sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw; else echo 'IPV6=yes' >> /etc/default/ufw; fi
fi
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw allow "${WG_PORT}/udp"
[[ -n "${CUR_SSH_PORT}" && "${CUR_SSH_PORT}" != "${SSH_PORT}" ]] && ufw allow "${CUR_SSH_PORT}/tcp"
# 443/tcp: IPv4 immer, IPv6 nur bei ENABLE_IPV6=1
ufw allow proto tcp to 0.0.0.0/0 port 443
if [[ "${ENABLE_IPV6}" == "1" ]]; then ufw allow proto tcp to ::/0 port 443; echo "IPv6 extern aktiv: 443/tcp (v6) freigegeben."; else echo "IPv6 extern aus: 443/tcp (v6) bleibt geschlossen."; fi
# 443/udp nur bei HTTP/3
if [[ "${ENABLE_HTTP3}" == "1" ]]; then
  ufw allow proto udp to 0.0.0.0/0 port 443
  [[ "${ENABLE_IPV6}" == "1" ]] && ufw allow proto udp to ::/0 port 443
  echo "HTTP/3 aktiv: 443/udp freigegeben."
else
  echo "HTTP/3 aus: 443/udp bleibt geschlossen."
fi
if [[ -n "${CUR_SSH_PORT}" && "${CUR_SSH_PORT}" != "${SSH_PORT}" ]]; then
  echo "Hinweis: Aktiver SSH-Port ${CUR_SSH_PORT}/tcp wurde zusaetzlich freigegeben (Schutz vor Aussperren)."
  echo "         HomeEdge aendert den sshd-Port nicht. SSH_PORT=${SSH_PORT} gilt nur fuer Firewall/Fail2ban."
fi
ufw --force enable

echo "[10/10] Optionales SSH-Hardening..."
if [[ "${CREATE_ADMIN}" == "1" && -n "${ADMIN_USER}" && -n "${ADMIN_PUBKEY}" ]]; then
  if ! id "${ADMIN_USER}" >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "${ADMIN_USER}"
  fi
  usermod -aG sudo "${ADMIN_USER}"
  mkdir -p "/home/${ADMIN_USER}/.ssh"
  printf '%s\n' "${ADMIN_PUBKEY}" > "/home/${ADMIN_USER}/.ssh/authorized_keys"
  chown -R "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"
  chmod 700 "/home/${ADMIN_USER}/.ssh"
  chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"

  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/99-homeedge-hardening.conf <<EOF
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
  systemctl reload ssh || systemctl reload sshd || true
  echo "SSH-Hardening aktiv. Teste eine neue SSH-Session mit User ${ADMIN_USER}, bevor du die alte schliesst."
else
  echo "SSH-Hardening nicht aktiviert. Root/Passwort-Login bitte spaeter manuell absichern."
fi

echo
echo "WireGuard/UniFi-Werte inkl. Keys wurden gespeichert in:"
echo "  /root/homeedge/unifi-wireguard-werte.txt  (chmod 600)"
echo "Anzeigen mit: sudo homeedge wg-values"
echo "(Bewusst nicht hier ausgegeben, damit keine Secrets im Install-Log landen.)"

echo
echo "[Verifikation] Setup wird abschliessend geprueft..."
# Wizard-Abschluss: Caddy holt Zertifikate per DNS-01, daher ist im Parallel-
# betrieb ein DNS-Eintrag, der noch auf den alten VPS zeigt, nur eine Warnung
# (--migration). Schlaegt eine harte Pruefung fehl, wird NICHT "FERTIG" gemeldet.
if homeedge verify-setup --migration; then
  echo
  echo "============================================================"
  echo "FERTIG"
  echo "============================================================"
  echo "Menue:                  sudo homeedge menu"
  echo "Aktuelle Werte:        sudo homeedge values"
  echo "WireGuard Werte:       sudo homeedge wg-values"
  echo "Status:                sudo homeedge status"
  echo "Jellyfin Known Proxy:  ${VPS_WG_IP}"
  echo "Install-Log:           /root/edge-install.log"
  echo "Cloudflare DNS:        A-Records auf ${VPS_PUBLIC_HOST}; Jellyfin DNS only/graue Wolke"
  echo "============================================================"
else
  echo
  echo "============================================================"
  echo "SETUP NICHT VOLLSTAENDIG"
  echo "============================================================"
  echo "Mindestens ein Schritt ist fehlgeschlagen (Liste oben)."
  echo "HomeEdge ist NICHT als fertig konfiguriert zu betrachten."
  echo
  echo "Reparieren und erneut pruefen:"
  echo "  sudo homeedge health"
  echo "  sudo homeedge diagnose"
  echo "  sudo homeedge verify-setup"
  echo "Install-Log: /root/edge-install.log"
  echo "============================================================"
  exit 1
fi
