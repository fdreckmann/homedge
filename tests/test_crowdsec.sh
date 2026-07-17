#!/usr/bin/env bash
# shellcheck disable=SC2034  # CS_*/IPT_BACKEND sind Mock-Steuervariablen, die nur
                            # indirekt in den Mock-Funktionen gelesen werden.
# Mock-Tests fuer das CrowdSec-Modul in homeedge.sh: Config, Whitelist,
# Repo-Setup (ohne curl|bash), Bouncer-Erkennung, Selbsttest und Rollback.
#
# Ansatz: eine pfad-umgeschriebene, VOR dem CLI-Dispatch abgeschnittene Kopie
# von homeedge.sh wird gesourct (alle absoluten Pfade zeigen in ein tmp-Dir),
# externe Kommandos (cscli/systemctl/apt-get/iptables/nft/ipset/curl/gpg/ufw/...)
# werden als Shell-Funktionen gemockt. So laufen die ECHTEN Modul-Funktionen.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SCRIPT_DIR}/homeedge.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root/etc" "$T/bin"
MOCKLOG="$T/mock.log"; : > "$MOCKLOG"

# Deterministisches os-release fuer das Repo-Setup.
cat > "$T/root/etc/os-release" <<EOF
ID=debian
VERSION_CODENAME=bookworm
EOF

# Truncated + pfad-umgeschriebene Lib bauen.
awk '/^case "\$\{1:-menu\}" in/{exit} {print}' "$SRC" \
  | sed -e "s#/etc/homeedge#$T/root/etc/homeedge#g" \
        -e "s#/opt/caddy-edge#$T/root/opt/caddy-edge#g" \
        -e "s#/etc/crowdsec#$T/root/etc/crowdsec#g" \
        -e "s#/etc/apt#$T/root/etc/apt#g" \
        -e "s#/usr/share/keyrings#$T/root/usr/share/keyrings#g" \
        -e "s#/etc/os-release#$T/root/etc/os-release#g" \
        -e "s#/root/homeedge#$T/root/homeedge2#g" \
        -e "s#/var/log/homeedge#$T/root/var/log/homeedge#g" \
        -e "s#/etc/wireguard#$T/root/etc/wireguard#g" \
  > "$T/lib.sh"
# shellcheck disable=SC1090
source "$T/lib.sh"

# --- Mocks (Shell-Funktionen ueberschreiben PATH-Binaries) ---
# Steuervariablen: CS_LAPI, CS_BOUNCER_REG, CS_METRICS, CS_ADD, CS_DATAPLANE,
# CS_SVC, CS_BOUNCER_SVC_ACTIVE, CS_CURL. CS_LOGPATH wird gesetzt.
cscli() {
  echo "cscli $*" >> "$MOCKLOG"
  case "$1 ${2:-}" in
    "lapi status")       [[ "${CS_LAPI:-1}" == 1 ]] ;;
    "bouncers list")     [[ "${CS_BOUNCER_REG:-1}" == 1 ]] && echo "cs-firewall-bouncer valid"; return 0 ;;
    "metrics"*)          [[ "${CS_METRICS:-1}" == 1 ]] && echo "Acquisition: ${CS_LOGPATH:-x} lines_read=42"; return 0 ;;
    "collections list")  printf '%s\n' crowdsecurity/linux crowdsecurity/sshd crowdsecurity/caddy; return 0 ;;
    "collections install") return 0 ;;
    "decisions add")     if [[ "${CS_ADD:-1}" == 1 ]]; then CS_DECISION_SET=1; return 0; else return 1; fi ;;
    "decisions list")    [[ "${CS_DECISION_SET:-0}" == 1 ]] && echo "203.0.113.10 ban homeedge-selftest"; return 0 ;;
    "decisions delete")  CS_DECISION_SET=0; return 0 ;;
    "console status")    echo "console: n/a"; return 0 ;;
    "hub update"|"hub upgrade") return 0 ;;
    *) return 0 ;;
  esac
}
systemctl() {
  echo "systemctl $*" >> "$MOCKLOG"
  if [[ "$1" == "is-active" ]]; then
    case "$*" in
      *firewall-bouncer*) [[ "${CS_BOUNCER_SVC_ACTIVE:-1}" == 1 ]] ;;
      *crowdsec*)         [[ "${CS_SVC:-1}" == 1 ]] ;;
      *) return 0 ;;
    esac
    return $?
  fi
  return 0
}
ufw() {
  if [[ "${1:-}" == "status" ]]; then
    printf '%s\n' "Status: active" "" "22/tcp   ALLOW   Anywhere" "443/tcp  ALLOW   Anywhere"
    return 0
  fi
  echo "ufw $*" >> "$MOCKLOG"; return 0
}
nft()   { echo "nft $*" >> "$MOCKLOG"; [[ "${1:-}" == "list" ]] && { [[ "${CS_DATAPLANE:-1}" == 1 ]] && echo "  ip 203.0.113.10 drop"; return 0; }; return 0; }
ipset() { [[ "${1:-}" == "list" ]] && { [[ "${CS_DATAPLANE:-1}" == 1 ]] && echo "203.0.113.10"; return 0; }; return 0; }
apt-get() { echo "apt-get $*" >> "$MOCKLOG"; if [[ "${CS_APT_FAIL:-0}" == 1 && "${1:-}" == "update" ]]; then echo "E: Failed to fetch ... 404  Not Found"; return 1; fi; return 0; }
iptables() { [[ "${1:-}" == "-V" ]] && echo "iptables v1.8.7 (${IPT_BACKEND:-nf_tables})"; return 0; }
dpkg() { [[ "${1:-}" == "--print-architecture" ]] && echo "amd64"; return 0; }
lsb_release() { [[ "${1:-}" == "-cs" ]] && echo "bookworm"; return 0; }
sleep() { :; }
curl() {
  echo "curl $*" >> "$MOCKLOG"
  [[ "${CS_CURL:-1}" == 1 ]] || return 1
  local a prev="" out=""
  for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
  [[ -n "$out" ]] && echo "DUMMYKEY" > "$out"
  return 0
}
gpg() { echo "gpg $*" >> "$MOCKLOG"; cat; }

pass=0; fail=0
ck() { if [[ "$2" == "$3" ]]; then echo "OK   $1"; pass=$((pass+1)); else echo "FAIL $1: got='$2' exp='$3'"; fail=$((fail+1)); fi; }

echo "== 1) Config round-trip (CROWDSEC_WHITELIST_IPS) =="
load_env; save_env
ck "WHITELIST_IPS persistiert" "$(grep -c '^CROWDSEC_WHITELIST_IPS=' "$ENV_FILE")" "1"
ck "Default leer"              "$CROWDSEC_WHITELIST_IPS" ""

echo "== 2) _crowdsec_valid_wl_entry =="
ck "akzeptiert IPv4"       "$(_crowdsec_valid_wl_entry '10.0.0.1'      && echo y || echo n)" "y"
ck "akzeptiert IPv4/CIDR"  "$(_crowdsec_valid_wl_entry '192.168.0.0/24' && echo y || echo n)" "y"
ck "akzeptiert IPv6"       "$(_crowdsec_valid_wl_entry '::1'           && echo y || echo n)" "y"
ck "lehnt 0.0.0.0/0 ab"    "$(_crowdsec_valid_wl_entry '0.0.0.0/0'     && echo y || echo n)" "n"
ck "lehnt ::/0 ab"         "$(_crowdsec_valid_wl_entry '::/0'          && echo y || echo n)" "n"
ck "lehnt leer ab"         "$(_crowdsec_valid_wl_entry ''              && echo y || echo n)" "n"
ck "lehnt Muell ab"        "$(_crowdsec_valid_wl_entry 'bogus'         && echo y || echo n)" "n"

echo "== 3) crowdsec_write_whitelist =="
load_env
# WICHTIG: crowdsec_write_whitelist ruft selbst load_env -> Werte persistieren.
VPS_WG_IP="10.0.1.1"; CLIENT_WG_IP="10.0.1.2"; HOME_SUBNET="192.168.10.0/24"
CROWDSEC_WHITELIST_IPS="10.0.5.5,192.168.99.0/24,0.0.0.0/0,::/0,bogus"; save_env
crowdsec_write_whitelist >/dev/null 2>&1
WL="$CROWDSEC_WHITELIST_FILE"
ck "Whitelist-Datei existiert" "$([[ -f "$WL" ]] && echo y)" "y"
ck "enthaelt Loopback 127.0.0.0/8" "$(grep -c '127.0.0.0/8' "$WL")" "1"
ck "enthaelt ::1"                  "$(grep -c '"::1"' "$WL")" "1"
ck "enthaelt VPS_WG_IP"            "$(grep -c '10.0.1.1' "$WL")" "1"
ck "enthaelt CLIENT_WG_IP"         "$(grep -c '10.0.1.2' "$WL")" "1"
ck "enthaelt HOME_SUBNET"          "$(grep -c '192.168.10.0/24' "$WL")" "1"
ck "enthaelt explizite IP"         "$(grep -c '10.0.5.5' "$WL")" "1"
ck "enthaelt explizites CIDR"      "$(grep -c '192.168.99.0/24' "$WL")" "1"
ck "KEIN 0.0.0.0/0"                "$(grep -c '0.0.0.0/0' "$WL")" "0"
ck "KEIN ::/0"                     "$(grep -c '::/0' "$WL")" "0"
ck "KEIN Muell"                    "$(grep -c 'bogus' "$WL")" "0"

echo "== 4) _crowdsec_setup_repo (any/any, kein curl|bash) =="
LIST="$T/root/etc/apt/sources.list.d/crowdsec_crowdsec.list"
KEYRING="$T/root/etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg"
mkdir -p "$(dirname "$LIST")"
set_osrel() { printf 'ID=%s\nVERSION_CODENAME=%s\n' "$1" "$2" > "$T/root/etc/os-release"; }

# 4a: bereits korrekt (any/any) -> skip, kein curl, Liste unveraendert
printf 'deb [signed-by=%s] https://packagecloud.io/crowdsec/crowdsec/any/ any main\n' "$KEYRING" > "$LIST"
before="$(cat "$LIST")"; : > "$MOCKLOG"
rc=0; _crowdsec_setup_repo >/dev/null 2>&1 || rc=$?
ck "korrekt vorhanden rc=0"       "$rc" "0"
ck "korrekt: KEIN curl"           "$(grep -c '^curl ' "$MOCKLOG")" "0"
ck "korrekt: Liste unveraendert"  "$(cat "$LIST")" "$before"

# 4b: falscher Distro-/Codename-Eintrag -> wird auf any/any korrigiert
printf 'deb [signed-by=%s arch=amd64] https://packagecloud.io/crowdsec/crowdsec/debian/ trixie main\n' "$KEYRING" > "$LIST"
: > "$MOCKLOG"
rc=0; _crowdsec_setup_repo >/dev/null 2>&1 || rc=$?
ck "korrektur rc=0"                    "$rc" "0"
ck "korrektur: any/any gesetzt"        "$(grep -c 'crowdsec/any/ any main' "$LIST")" "2"
ck "korrektur: KEIN debian/trixie mehr" "$(grep -c 'crowdsec/debian/' "$LIST")" "0"
ck "korrektur: curl holt gpgkey"       "$(grep -c 'gpgkey' "$MOCKLOG")" "1"
ck "korrektur: apt-get update"         "$(grep -c 'apt-get update' "$MOCKLOG")" "1"

# 4c: frisch (keine Liste) -> any/any, Keyring unter /etc/apt/keyrings
rm -f "$LIST" "$KEYRING"; set_osrel debian trixie; : > "$MOCKLOG"
rc=0; _crowdsec_setup_repo >/dev/null 2>&1 || rc=$?
ck "frisch rc=0"                        "$rc" "0"
ck "Keyring unter /etc/apt/keyrings"    "$([[ -s "$KEYRING" ]] && echo y)" "y"
ck "Liste hat signed-by (deb+deb-src)"  "$(grep -c 'signed-by=' "$LIST")" "2"
ck "KEIN Distro-/Codename-Pfad"         "$(grep -cE 'crowdsec/(debian|ubuntu)/' "$LIST")" "0"
ck "KEIN install.crowdsec.net"          "$(grep -c 'install.crowdsec.net' "$LIST")" "0"
ck "KEIN pipe-to-bash"                  "$(grep -cE 'curl.*\| *bash' "$MOCKLOG")" "0"

# 4d: Trixie/Bookworm/Ubuntu erzeugen ALLE denselben any/any-Eintrag
expected="$(printf 'deb [signed-by=%s] https://packagecloud.io/crowdsec/crowdsec/any/ any main' "$KEYRING")"
for combo in "debian trixie" "debian bookworm" "ubuntu jammy"; do
  read -r d c <<<"$combo"
  rm -f "$LIST"; set_osrel "$d" "$c"; : > "$MOCKLOG"
  _crowdsec_setup_repo >/dev/null 2>&1 || true
  ck "any/any-Eintrag fuer ${d}/${c}" "$(grep -m1 '^deb ' "$LIST")" "$expected"
done

# 4e: apt-get update schlaegt fehl -> rc=1 und ECHTE Fehlerausgabe sichtbar
rm -f "$LIST"; set_osrel debian trixie; CS_APT_FAIL=1
rc=0; out="$(_crowdsec_setup_repo 2>&1)" || rc=$?
ck "apt-Fehler -> rc=1"            "$rc" "1"
ck "echte apt-Fehlerausgabe"       "$(grep -c '404  Not Found' <<<"$out")" "1"
CS_APT_FAIL=0

echo "== 5) crowdsec_detect_bouncer =="
load_env
CROWDSEC_BOUNCER=auto IPT_BACKEND=nf_tables; ck "auto nf_tables -> nftables" "$(crowdsec_detect_bouncer)" "nftables"
save_env  # persist auto
IPT_BACKEND=legacy; load_env; CROWDSEC_BOUNCER=auto; save_env; ck "auto legacy -> iptables" "$(crowdsec_detect_bouncer)" "iptables"
CROWDSEC_BOUNCER=nftables; save_env; ck "forced nftables" "$(crowdsec_detect_bouncer)" "nftables"
CROWDSEC_BOUNCER=iptables; save_env; ck "forced iptables" "$(crowdsec_detect_bouncer)" "iptables"
CROWDSEC_BOUNCER=auto; save_env

echo "== 6) crowdsec_selftest =="
crowdsec_write_acquis >/dev/null 2>&1   # Acquisition-Datei + Log anlegen (Selftest prueft sie)
export CS_LOGPATH="$CROWDSEC_CADDY_LOG"
# 6a: alles gesund + Decision landet in Dataplane -> rc 0, Cleanup-Delete aufgerufen
: > "$MOCKLOG"; CS_LAPI=1 CS_BOUNCER_REG=1 CS_METRICS=1 CS_ADD=1 CS_DATAPLANE=1 CS_SVC=1 CS_BOUNCER_SVC_ACTIVE=1 CS_DECISION_SET=0
rc=0; crowdsec_selftest >/dev/null 2>&1 || rc=$?
ck "healthy -> rc=0" "$rc" "0"
ck "Test-Decision mit 203.0.113.10 hinzugefuegt" "$(grep -c 'decisions add --ip 203.0.113.10' "$MOCKLOG")" "1"
ck "Cleanup: Decision wieder geloescht"          "$(grep -c 'decisions delete --ip 203.0.113.10' "$MOCKLOG")" "1"
# 6b: LAPI down -> rc 2, aber Cleanup trotzdem
: > "$MOCKLOG"; CS_LAPI=0 CS_DECISION_SET=0
rc=0; crowdsec_selftest >/dev/null 2>&1 || rc=$?
ck "LAPI down -> rc=2" "$rc" "2"
ck "Cleanup auch bei Fehler" "$(grep -c 'decisions delete --ip 203.0.113.10' "$MOCKLOG")" "1"
CS_LAPI=1
# 6c: Dataplane-Uebernahme fehlt -> Poll bis Timeout -> WARN -> rc 1, Delete trotzdem
: > "$MOCKLOG"; CS_DATAPLANE=0 CS_DECISION_SET=0
rc=0; crowdsec_selftest >/dev/null 2>&1 || rc=$?
ck "Dataplane fehlt -> rc=1" "$rc" "1"
ck "Delete GENAU einmal (Trap-Cleanup)" "$(grep -c 'decisions delete --ip 203.0.113.10' "$MOCKLOG")" "1"
# Poll muss mehrfach nftables geprueft haben (nicht nur einmal wie frueher).
ck "Poll prueft Dataplane mehrfach" "$([[ $(grep -c '^nft list' "$MOCKLOG") -ge 2 ]] && echo y || echo n)" "y"
CS_DATAPLANE=1
# 6c2: Dataplane sofort vorhanden -> KEIN langes Pollen (Fund beim 1. Check)
: > "$MOCKLOG"; CS_DATAPLANE=1 CS_DECISION_SET=0
rc=0; crowdsec_selftest >/dev/null 2>&1 || rc=$?
ck "Dataplane sofort -> rc=0" "$rc" "0"
ck "Fund sofort: nur 1 nft-Check" "$(grep -c '^nft list' "$MOCKLOG")" "1"
# 6d: nicht installiert -> rc 2
( unset -f cscli; rc=0; crowdsec_selftest >/dev/null 2>&1 || rc=$?; [[ "$rc" == 2 ]] ) && echo "OK   nicht installiert -> rc=2" && pass=$((pass+1)) || { echo "FAIL nicht installiert -> rc=2"; fail=$((fail+1)); }

echo "== 7) crowdsec_disable ruehrt nur crowdsec/bouncer an =="
: > "$MOCKLOG"; load_env; ENABLE_CROWDSEC=1; save_env
crowdsec_disable >/dev/null 2>&1
load_env
ck "ENABLE_CROWDSEC=0 gespeichert" "$ENABLE_CROWDSEC" "0"
bad="$(grep '^systemctl' "$MOCKLOG" | grep -viE 'crowdsec|firewall-bouncer' | grep -ciE 'fail2ban|caddy|ufw|wireguard|wg-quick|docker' || true)"
ck "kein Eingriff in f2b/caddy/ufw/wg/docker" "$bad" "0"
ck "kein apt purge" "$(grep -c 'purge' "$MOCKLOG")" "0"

echo "------------------------------------------------------------"
echo "SUMMARY pass=${pass} fail=${fail}"
[[ "$fail" -eq 0 ]]
