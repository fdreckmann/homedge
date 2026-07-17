#!/usr/bin/env bash
# Regressionstest fuer caddy_listens_ipv6_443() aus homeedge.sh.
#
# Hintergrund: Die alte Pruefung nutzte 'ss -H -ltn' (nur TCP) mit der Regex
# '\[?::' und erkannte den Wildcard-Listener '*:443' NICHT - dadurch wurde
# faelschlich "Caddy lauscht (noch) nicht sichtbar auf IPv6 :443" gemeldet,
# obwohl 'ss -6 -ltnp' bzw. 'ss -6 -lunp' einen caddy-Listener auf '*:443'
# zeigten. Dieser Test fixiert das korrekte Verhalten fuer TCP und UDP sowie
# die Adressformen *:443, [::]:443, [<v6>]:443 und :::443.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SCRIPT_DIR}/homeedge.sh"

# Die ECHTE Funktion aus homeedge.sh extrahieren und laden (ohne das komplette
# Skript zu sourcen) - so testet der Test die reale Implementierung.
eval "$(awk '/^caddy_listens_ipv6_443\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$SRC")"

# Mock: 'ss' liefert je nach Protokoll die per SS_TCP/SS_UDP gesetzte Zeile.
# Die reale Funktion ruft 'ss ... -ltnp ...' (TCP) und 'ss ... -lunp ...' (UDP).
ss() {
  case "$*" in
    *ltn*) printf '%s\n' "${SS_TCP:-}" ;;
    *lun*) printf '%s\n' "${SS_UDP:-}" ;;
  esac
}

pass=0; fail=0
# run <erwartet: ok|no> <name> ; nutzt SS_TCP/SS_UDP aus der Umgebung
run() {
  local expect="$1" name="$2" rc=0
  caddy_listens_ipv6_443 || rc=$?
  local got="no"; [[ "$rc" -eq 0 ]] && got="ok"
  if [[ "$got" == "$expect" ]]; then
    printf 'OK   %s\n' "$name"; pass=$((pass+1))
  else
    printf 'FAIL %s (erwartet=%s, bekommen=%s)\n' "$name" "$expect" "$got"; fail=$((fail+1))
  fi
}

C='users:(("caddy",pid=1234,fd=7))'
N='users:(("nginx",pid=99,fd=3))'

# --- TCP-Adressformen mit caddy -> OK ---
SS_TCP="LISTEN 0 4096 *:443 *:* ${C}"        SS_UDP="" run ok  "TCP Wildcard *:443 (Regressionsfall)"
SS_TCP="LISTEN 0 4096 [::]:443 [::]:* ${C}"  SS_UDP="" run ok  "TCP [::]:443"
SS_TCP="LISTEN 0 4096 :::443 :::* ${C}"       SS_UDP="" run ok  "TCP :::443"
SS_TCP="LISTEN 0 4096 [2001:db8::1]:443 [::]:* ${C}" SS_UDP="" run ok "TCP konkrete v6-Adresse [..]:443"

# --- UDP/HTTP3 mit caddy, TCP leer -> OK (UDP getrennt geprueft) ---
SS_TCP="" SS_UDP="UNCONN 0 0 *:443 *:* ${C}"  run ok  "UDP Wildcard *:443 (HTTP/3)"
SS_TCP="" SS_UDP="UNCONN 0 0 [::]:443 *:* ${C}" run ok "UDP [::]:443 (HTTP/3)"

# --- Negativfaelle -> kein OK ---
SS_TCP="" SS_UDP="" run no "kein Listener"
SS_TCP="LISTEN 0 4096 [::]:443 [::]:* ${N}" SS_UDP="" run no "v6 :443, aber Prozess ist NICHT caddy"
SS_TCP="LISTEN 0 4096 [::]:2019 [::]:* ${C}" SS_UDP="" run no "caddy, aber auf :2019 (nicht :443)"

echo "------------------------------------------------------------"
echo "SUMMARY pass=${pass} fail=${fail}"
[[ "$fail" -eq 0 ]]
