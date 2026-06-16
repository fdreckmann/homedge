#!/usr/bin/env bash
set -Eeuo pipefail

# Update-HomeEdgeOnly.sh
# Aktualisiert nur /usr/local/bin/homeedge auf einem bereits installierten VPS.
# Starten mit:
#   chmod +x Update-HomeEdgeOnly.sh
#   ./Update-HomeEdgeOnly.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_PATH="${SCRIPT_DIR}/Install-EdgeVps.config.env"
EDGECTL_PATH="${SCRIPT_DIR}/homeedge.sh"

if [[ ! -f "$EDGECTL_PATH" ]]; then
  echo "FEHLER: homeedge.sh nicht gefunden im Ordner: $SCRIPT_DIR"
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

b64_file() { base64 < "$1" | tr -d '\n'; }

if [[ -f "$CONFIG_PATH" ]]; then
  echo "Vorhandene Config gefunden: $CONFIG_PATH"
  if yesno "Diese SSH-Werte verwenden?" "y"; then
    # shellcheck disable=SC1090
    source "$CONFIG_PATH"
  fi
fi

SshHost="$(ask "VPS IP oder Hostname fuer SSH" "${SshHost:-}")"
SshUser="$(ask "SSH Benutzer" "${SshUser:-root}")"
SshPortConnect="$(ask "SSH Port" "${SshPortFinal:-${SshPortConnect:-22}}")"
SshKeyPath="$(ask "SSH Key Pfad optional" "${SshKeyPath:-}")"

SSH_ARGS=()
[[ -n "$SshKeyPath" ]] && SSH_ARGS+=("-i" "$SshKeyPath")
SSH_ARGS+=("-p" "$SshPortConnect" "${SshUser}@${SshHost}")

EDGECTL_B64="$(b64_file "$EDGECTL_PATH")"

# Remote-Script: ersetzt das Binary und fuehrt danach Migration, Validierung
# und Healthcheck aus. Bei Fehlern wird ein Rollback-Hinweis ausgegeben.
RS="$(cat <<'EOS'
#!/usr/bin/env bash
set -u
TS="$(date +%Y%m%d-%H%M%S)"
FAIL=0
if [ -f /usr/local/bin/homeedge ]; then cp -a /usr/local/bin/homeedge "/usr/local/bin/homeedge.preupdate.${TS}" 2>/dev/null || true; fi
printf '%s' "__HOMEEDGE_B64__" | base64 -d > /usr/local/bin/homeedge || { echo "[ERR] Schreiben des Binaries fehlgeschlagen."; exit 1; }
chmod +x /usr/local/bin/homeedge
ln -sf /usr/local/bin/homeedge /usr/local/bin/edgectl
echo "[OK] homeedge ersetzt: $(/usr/local/bin/homeedge --version 2>/dev/null)"
# 1) Pre-Update-Backup (best effort)
if /usr/local/bin/homeedge backup-create </dev/null >/dev/null 2>&1; then echo "[OK] Pre-Update-Backup erstellt"; else echo "[WARN] Pre-Update-Backup uebersprungen"; fi
# 3) Migration (Token bereinigen, Defaults, services-Repair, Caddyfile, Fail2ban)
if /usr/local/bin/homeedge migrate --no-backup; then echo "[OK] Migration ok"; else echo "[ERR] Migration fehlgeschlagen"; FAIL=1; fi
# 4) services.tsv hart validieren
if /usr/local/bin/homeedge validate-services; then echo "[OK] services.tsv valide"; else echo "[ERR] services.tsv ungueltig"; FAIL=1; fi
# 5) Healthcheck
/usr/local/bin/homeedge health || true
if [ "$FAIL" -ne 0 ]; then
  echo "[ERR] Update mit Fehlern abgeschlossen."
  echo "      Rollback Binary: cp /usr/local/bin/homeedge.preupdate.${TS} /usr/local/bin/homeedge"
  echo "      Config wiederherstellen: sudo homeedge restore-config"
  exit 1
fi
echo "[OK] Update abgeschlossen."
EOS
)"
RS="${RS//__HOMEEDGE_B64__/$EDGECTL_B64}"

REMOTE_CMD='tmp=/tmp/he-update.sh; cat > "$tmp"; chmod 700 "$tmp"; if [ "$(id -u)" -eq 0 ]; then bash "$tmp"; else sudo bash "$tmp"; fi; rc=$?; rm -f "$tmp"; exit $rc'

printf '%s' "$RS" | ssh "${SSH_ARGS[@]}" "$REMOTE_CMD"

echo
if yesno "Direkt homeedge-Menue oeffnen?" "y"; then
  ssh -t "${SSH_ARGS[@]}" "sudo homeedge menu"
fi
