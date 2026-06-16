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
REMOTE_CMD='tmp=/tmp/homeedge.b64; cat > "$tmp"; chmod 600 "$tmp"; if [ "$(id -u)" -eq 0 ]; then base64 -d "$tmp" > /usr/local/bin/homeedge && chmod +x /usr/local/bin/homeedge && ln -sf /usr/local/bin/homeedge /usr/local/bin/edgectl; else sudo bash -c "base64 -d /tmp/homeedge.b64 > /usr/local/bin/homeedge && chmod +x /usr/local/bin/homeedge && ln -sf /usr/local/bin/homeedge /usr/local/bin/edgectl"; fi; rm -f "$tmp"; echo "homeedge aktualisiert."; /usr/local/bin/homeedge --version 2>/dev/null || true'

printf '%s' "$EDGECTL_B64" | ssh "${SSH_ARGS[@]}" "$REMOTE_CMD"

echo
if yesno "Direkt homeedge-Menue oeffnen?" "y"; then
  ssh -t "${SSH_ARGS[@]}" "sudo homeedge menu"
fi
