#!/usr/bin/env bash
# Test fuer die Redaction sensibler Jellyfin-Tokens im Caddy-Access-Log.
#
# Die eigentliche Schwaerzung macht Caddys "format filter" (wrap json) zur
# Laufzeit; Caddy ist in dieser Umgebung nicht ausfuehrbar. Daher zwei Ebenen:
#   A) STRUKTUR: das REAL erzeugte Caddyfile (generate_caddyfile_to) enthaelt den
#      korrekten filter-Block (wrap json + query/header-replaces, kein format json).
#   B) VERHALTEN (Simulation): die aus dem erzeugten Caddyfile abgeleiteten
#      Query-Parameter werden auf eine Beispiel-JSON-Logzeile angewandt - ApiKey
#      & token werden REDACTED, waehrend Pfad, Status, Client-IP und User-Agent
#      erhalten bleiben und keine Secrets uebrig bleiben.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SCRIPT_DIR}/homeedge.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root"

# Truncated + pfad-umgeschriebene Lib bauen und sourcen (echte Funktionen).
awk '/^case "\$\{1:-menu\}" in/{exit} {print}' "$SRC" \
  | sed -e "s#/etc/homeedge#$T/root/etc/homeedge#g" \
        -e "s#/opt/caddy-edge#$T/root/opt/caddy-edge#g" \
        -e "s#/root/homeedge#$T/root/homeedge2#g" \
        -e "s#/var/log/homeedge#$T/root/var/log/homeedge#g" \
        -e "s#/etc/wireguard#$T/root/etc/wireguard#g" \
        -e "s#/etc/crowdsec#$T/root/etc/crowdsec#g" \
  > "$T/lib.sh"
# shellcheck disable=SC1090
source "$T/lib.sh"

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "OK   $1"; pass=$((pass+1)); else echo "FAIL $1: got='$2' exp='$3'"; fail=$((fail+1)); fi; }

# --- Caddyfile mit einem Jellyfin-Dienst erzeugen ---
SERVICES_FILE="$T/services.tsv"
printf 'jf.example.com\thttp\t10.0.1.2\t8096\tjellyfin\n' > "$SERVICES_FILE"
OUT="$T/Caddyfile"
generate_caddyfile_to "$OUT" >/dev/null 2>&1

echo "== A) Struktur des erzeugten Caddyfile =="
ck "format filter vorhanden"     "$(grep -c 'format filter' "$OUT")" "1"
ck "wrap json Direktive"         "$(grep -cE '^[[:space:]]*wrap json[[:space:]]*$' "$OUT")" "1"
ck "kein nacktes 'format json'"  "$(grep -c 'format json' "$OUT")" "0"
ck "request>uri query Block"     "$(grep -c 'request>uri query {' "$OUT")" "1"
for p in ApiKey apiKey api_key access_token token; do
  ck "query replace ${p}"        "$(grep -c "replace ${p} REDACTED" "$OUT")" "1"
done
ck "Header X-Emby-Token"          "$(grep -c 'request>headers>X-Emby-Token replace REDACTED' "$OUT")" "1"
ck "Header X-Mediabrowser-Token"  "$(grep -c 'request>headers>X-Mediabrowser-Token replace REDACTED' "$OUT")" "1"
ck "Header X-MediaBrowser-Token"  "$(grep -c 'request>headers>X-MediaBrowser-Token replace REDACTED' "$OUT")" "1"
# Der echte Request darf NICHT angefasst werden: reverse_proxy setzt keine
# header_up-/query-Manipulation fuer Tokens (nur X-Real-IP).
ck "kein header_up fuer Tokens"   "$(grep -c 'header_up .*Token' "$OUT")" "0"

echo "== B) Verhalten (Simulation der Caddy-query/header-Filter) =="
# Query-Parameter, die laut erzeugtem Caddyfile geschwaerzt werden, ableiten:
mapfile -t QPARAMS < <(grep -oE 'replace [A-Za-z_]+ REDACTED' "$OUT" | awk '{print $2}')
ck "abgeleitete Query-Parameter (5)" "${#QPARAMS[@]}" "5"

# Beispiel-Logzeile wie Caddy sie OHNE Filter schriebe (mit Secrets).
# WICHTIG: URI per Konkatenation einsetzen (kein ${x/pat/repl} - '&' waere dort
# in der Ersetzung speziell und wuerde die Query zerstoeren).
URI='/Videos/123/stream?ApiKey=SECRET123&token=TOK9&static=true&MediaSourceId=abc'
line='{"level":"info","logger":"http.log.access.log0","msg":"handled request","request":{"remote_ip":"203.0.113.5","method":"GET","uri":"'"$URI"'","headers":{"User-Agent":["JellyfinAndroid/2.6.1"],"X-Emby-Token":["EMBYSECRET"],"X-Mediabrowser-Token":["MBSECRET"]}},"status":200}'

# Query-Filter nachbilden: fuer jeden abgeleiteten Param value -> REDACTED.
red="$line"
for p in "${QPARAMS[@]}"; do
  red="$(sed -E "s/([?&]${p}=)[^&\"]*/\1REDACTED/g" <<<"$red")"
done
# Header-Filter nachbilden (X-Emby-Token / X-Mediabrowser-Token).
red="$(sed -E 's/("X-Emby-Token":\[")[^"]*/\1REDACTED/; s/("X-Mediabrowser-Token":\[")[^"]*/\1REDACTED/' <<<"$red")"

# ApiKey & token geschwaerzt?
ck "ApiKey -> REDACTED"      "$(grep -c 'ApiKey=REDACTED' <<<"$red")" "1"
ck "token -> REDACTED"       "$(grep -c 'token=REDACTED' <<<"$red")" "1"
# Header geschwaerzt?
ck "X-Emby-Token -> REDACTED"        "$(grep -c '"X-Emby-Token":\["REDACTED"\]' <<<"$red")" "1"
ck "X-Mediabrowser-Token -> REDACTED" "$(grep -c '"X-Mediabrowser-Token":\["REDACTED"\]' <<<"$red")" "1"
# Erhalten geblieben: Pfad, harmloser Query, Status, Client-IP, User-Agent
ck "Pfad erhalten"          "$(grep -c '/Videos/123/stream' <<<"$red")" "1"
ck "harmloser Query erhalten" "$(grep -c 'static=true' <<<"$red")" "1"
ck "Status erhalten"        "$(grep -c '"status":200' <<<"$red")" "1"
ck "Client-IP erhalten"     "$(grep -c '"remote_ip":"203.0.113.5"' <<<"$red")" "1"
ck "User-Agent erhalten"    "$(grep -c 'JellyfinAndroid/2.6.1' <<<"$red")" "1"
# Keine Secrets uebrig
for s in SECRET123 TOK9 EMBYSECRET MBSECRET; do
  ck "Secret ${s} entfernt"  "$(grep -c "$s" <<<"$red")" "0"
done

echo "------------------------------------------------------------"
echo "SUMMARY pass=${pass} fail=${fail}"
[[ "$fail" -eq 0 ]]
