#!/usr/bin/env bash
# shellcheck disable=SC2034  # ENABLE_IPV6/ENABLE_HTTP3/SSH_PORT/WG_PORT/SSH_CONNECTION
                            # werden von den per eval geladenen Funktionen als Globals
                            # gelesen; shellcheck sieht die eval-Rumpfe nicht.
# Regressionstest fuer den IPv6-UFW-Toggle in homeedge.sh:
#   _ufw_rules_apply, _ufw_verify_443, _ufw_status_report
#
# Hintergrund (bestaetigter Bug, 0.9.23):
#  - _ufw_rules_apply verschluckte alle UFW-Fehler (>/dev/null 2>&1 || true) und
#    meldete Erfolg, obwohl 443/tcp (v6) nicht angelegt wurde.
#  - _ufw_status_report matchte '443.*\(v6\)' und zaehlte '443/udp (v6)'
#    faelschlich als 443/tcp (v6).
# Der Test treibt die realen Funktionen aus homeedge.sh mit gemocktem 'ufw'.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SCRIPT_DIR}/homeedge.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
UFWLOG="${TMP}/ufw.log"; OUTLOG="${TMP}/out.log"

# Echte Funktionen laden (ohne das ganze Skript zu sourcen).
extract() { awk "/^$1\\(\\) \\{/{p=1} p{print} p&&/^}/{exit}" "$SRC"; }
eval "$(extract _ufw_rules_apply)"
eval "$(extract _ufw_verify_443)"
eval "$(extract _ufw_status_report)"

# Stubs fuer Ausgabe-Helfer.
ok()   { echo "OK:$*"   >> "$OUTLOG"; }
warn() { echo "WARN:$*" >> "$OUTLOG"; }
info() { :; }
err()  { echo "ERR:$*"  >> "$OUTLOG"; }

# Mock 'ufw': 'ufw status' liefert $MOCK_STATUS; sonst wird das Kommando geloggt.
# UFW_FAIL_MATCH erzwingt rc=1 fuer Kommandos, die den Teilstring enthalten.
ufw() {
  if [[ "${1:-}" == "status" ]]; then printf '%s\n' "${MOCK_STATUS:-}"; return 0; fi
  echo "$*" >> "$UFWLOG"
  if [[ -n "${UFW_FAIL_MATCH:-}" && "$*" == *"$UFW_FAIL_MATCH"* ]]; then return 1; fi
  return 0
}

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "OK   $1"; pass=$((pass+1)); else echo "FAIL $1: got='$2' exp='$3'"; fail=$((fail+1)); fi; }
has()  { grep -qxF "$1" "$UFWLOG"; }   # exakte Zeile im ufw-Log?

SSH_PORT=22; WG_PORT=51821; SSH_CONNECTION=""

echo "== _ufw_rules_apply: Kommando-Erzeugung je Kombination =="

# v6=1, http3=0 -> einfache Form 443/tcp (v4+v6), KEIN udp, KEINE 0.0.0.0/0-tcp-Form
: > "$UFWLOG"; ENABLE_IPV6=1 ENABLE_HTTP3=0; UFW_FAIL_MATCH="" ; rc=0; _ufw_rules_apply || rc=$?
ck "v6on/h3off rc=0" "$rc" "0"
ck "v6on/h3off: allow 443/tcp (dual-stack)" "$(has 'allow 443/tcp' && echo y || echo n)" "y"
ck "v6on/h3off: KEIN 0.0.0.0/0 tcp"        "$(has 'allow proto tcp to 0.0.0.0/0 port 443' && echo y || echo n)" "n"
ck "v6on/h3off: KEIN udp-add"              "$(has 'allow 443/udp' && echo y || echo n)" "n"

# v6=1, http3=1 -> zusaetzlich allow 443/udp (v4+v6)
: > "$UFWLOG"; ENABLE_IPV6=1 ENABLE_HTTP3=1; rc=0; _ufw_rules_apply || rc=$?
ck "v6on/h3on rc=0" "$rc" "0"
ck "v6on/h3on: allow 443/udp (dual-stack)" "$(has 'allow 443/udp' && echo y || echo n)" "y"

# v6=0, http3=0 -> nur IPv4-spezifisch (0.0.0.0/0 tcp), KEINE einfache/v6-Form
: > "$UFWLOG"; ENABLE_IPV6=0 ENABLE_HTTP3=0; rc=0; _ufw_rules_apply || rc=$?
ck "v6off/h3off rc=0" "$rc" "0"
ck "v6off/h3off: 0.0.0.0/0 tcp"        "$(has 'allow proto tcp to 0.0.0.0/0 port 443' && echo y || echo n)" "y"
ck "v6off/h3off: KEIN allow 443/tcp"   "$(has 'allow 443/tcp' && echo y || echo n)" "n"
ck "v6off/h3off: KEIN udp"             "$(has 'allow proto udp to 0.0.0.0/0 port 443' && echo y || echo n)" "n"

# v6=0, http3=1 -> IPv4 tcp + IPv4 udp, KEINE v6-Formen
: > "$UFWLOG"; ENABLE_IPV6=0 ENABLE_HTTP3=1; rc=0; _ufw_rules_apply || rc=$?
ck "v6off/h3on: 0.0.0.0/0 udp"         "$(has 'allow proto udp to 0.0.0.0/0 port 443' && echo y || echo n)" "y"
ck "v6off/h3on: KEIN ::/0 udp"         "$(has 'allow proto udp to ::/0 port 443' && echo y || echo n)" "n"

# Cleanup-Deletes immer vorhanden
ck "cleanup: delete allow 443/tcp"     "$(has 'delete allow 443/tcp' && echo y || echo n)" "y"
ck "cleanup: delete ::/0 tcp"          "$(has 'delete allow proto tcp to ::/0 port 443' && echo y || echo n)" "y"

echo "== _ufw_rules_apply: Fehler wird NICHT mehr verschluckt =="
: > "$UFWLOG"; ENABLE_IPV6=1 ENABLE_HTTP3=0; UFW_FAIL_MATCH="allow 443/tcp"; rc=0; _ufw_rules_apply || rc=$?
ck "add-Fehler -> rc=1" "$rc" "1"
UFW_FAIL_MATCH=""

# --- ufw status Fixtures ---
hdr=$'Status: active\n\nTo                         Action      From\n--                         ------      ----\n22/tcp                     ALLOW       Anywhere'
ST_V6ON_H3OFF="${hdr}"$'\n443/tcp                    ALLOW       Anywhere\n443/tcp (v6)               ALLOW       Anywhere (v6)'
ST_V4ONLY="${hdr}"$'\n443/tcp                    ALLOW       Anywhere'
ST_V6ON_H3ON="${hdr}"$'\n443/tcp                    ALLOW       Anywhere\n443/tcp (v6)               ALLOW       Anywhere (v6)\n443/udp                    ALLOW       Anywhere\n443/udp (v6)               ALLOW       Anywhere (v6)'
# Nur udp (v6), KEIN tcp (v6) -> Regressionsfixture fuer Spec-Punkt 7
ST_UDPV6_ONLY="${hdr}"$'\n443/tcp                    ALLOW       Anywhere\n443/udp                    ALLOW       Anywhere\n443/udp (v6)               ALLOW       Anywhere (v6)'

echo "== _ufw_verify_443: Soll/Ist =="
run_verify() { local r=0; _ufw_verify_443 "$1" >/dev/null 2>&1 || r=$?; echo "$r"; }
ENABLE_IPV6=1 ENABLE_HTTP3=0; ck "v6on/h3off passt zu Fixture" "$(run_verify "$ST_V6ON_H3OFF")" "0"
ENABLE_IPV6=0 ENABLE_HTTP3=0; ck "v6off erwartet, aber v6 in Fixture -> Fehler" "$(run_verify "$ST_V6ON_H3OFF")" "1"
ENABLE_IPV6=1 ENABLE_HTTP3=0; ck "443/tcp v4 fehlt -> Fehler" "$(run_verify "$ST_V4ONLY")" "1"
ENABLE_IPV6=0 ENABLE_HTTP3=0; ck "v4only passt zu v6off/h3off" "$(run_verify "$ST_V4ONLY")" "0"
ENABLE_IPV6=1 ENABLE_HTTP3=1; ck "v6on/h3on passt zu Fixture" "$(run_verify "$ST_V6ON_H3ON")" "0"

echo "== _ufw_verify_443: 443/udp (v6) wird NICHT als 443/tcp (v6) gewertet =="
# ENABLE_IPV6=0, HTTP3=1: tcp_v6 muss 0 sein (kein 443/tcp v6 in Fixture),
# nur udp_v6=1 vorhanden -> Abweichung liegt an udp(v6), nicht an tcp(v6).
# err() schreibt in $OUTLOG -> dort pruefen.
: > "$OUTLOG"; ENABLE_IPV6=0 ENABLE_HTTP3=1; _ufw_verify_443 "$ST_UDPV6_ONLY" || true
ck "kein falscher 443/tcp (v6)-Fehler" "$(grep -c '443/tcp (v6)' "$OUTLOG")" "0"
ck "aber udp (v6)-Abweichung erkannt"  "$(grep -c '443/udp (v6)' "$OUTLOG")" "1"

echo "== _ufw_status_report: Spec-Punkt 7 (kein falsches tcp-v6 aus udp-v6) =="
: > "$OUTLOG"; ENABLE_IPV6=0 ENABLE_HTTP3=1; MOCK_STATUS="$ST_UDPV6_ONLY"; _ufw_status_report || true
ck "meldet 443/tcp v6 geschlossen"       "$(grep -c 'geschlossen, ENABLE_IPV6=0' "$OUTLOG")" "1"
ck "KEINE falsche '443 (v6) noch offen'"  "$(grep -c '443 (v6) ist laut' "$OUTLOG")" "0"

echo "------------------------------------------------------------"
echo "SUMMARY pass=${pass} fail=${fail}"
[[ "$fail" -eq 0 ]]
