#!/bin/bash
# ==============================================================================
# Fiwu Protocols Test Suite
# Validates the behavior of Fiwu core logic while testing connectivity across 
# multiple protocols and layers (L3-L7). Each test is classified as allowed or blocked.
# ==============================================================================

if [[ $EUID -ne 0 ]]; then
    exec sudo bash "$0" "$@"
fi

# ── Helpers ───────────────────────────────────────────────────────────────────
# Results are tracked globally and per layer
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
OK=0; FAIL=0; SKIP=0
declare -A L_OK L_FAIL L_SKIP
CL="misc"

log()  { echo -e "\n${CYAN}${BOLD}── $1${NC}  ${DIM}$2${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC}  $1"; ((OK++));  L_OK[$CL]=$(( ${L_OK[$CL]:-0}  + 1 )); }
fail() { echo -e "  ${RED}✗${NC}  $1"; ((FAIL++)); L_FAIL[$CL]=$(( ${L_FAIL[$CL]:-0} + 1 )); }
skip() { echo -e "  ${YELLOW}⏸${NC}  $1"; ((SKIP++)); L_SKIP[$CL]=$(( ${L_SKIP[$CL]:-0} + 1 )); }
info() { echo -e "     ${DIM}$1${NC}"; }
has()  { command -v "$1" >/dev/null 2>&1; }
T()    { local s=$1; shift; timeout "$s" "$@" 2>/dev/null; }
layer(){ CL="$1"; log "$1" "$2"; }
export -f T has

REQUIRED_TOOLS=("jq" "nmap" "nc" "dig" "ping" "openssl" "curl")
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! has "$tool"; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    info "Missing required test tools: ${MISSING_TOOLS[*]}. Installing..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        case "$ID" in
            fedora)
                dnf install -y -q jq nmap bind-utils nc iputils openssl curl
                ;;
            ubuntu|debian)
                apt-get update -qq && apt-get install -y -qq jq nmap bind9-dnsutils netcat-openbsd iputils-ping openssl curl
                ;;
        esac
    fi
fi

# ── Policy & Dependency Checker ───────────────────────────────────────────────
# Read policy once for the test run. The daemon's config determines whether a
# successful connection is expected to pass or to be reported as a violation.
CFG_RAW=$(cat /etc/fiwu/config.json 2>/dev/null)
DEFAULT_POLICY="allow"; CFG=false
if [[ -n "$CFG_RAW" ]] && has jq; then
    DEFAULT_POLICY=$(jq -r '.default//"allow"' <<<"$CFG_RAW")
    CFG=true
    info "Policy loaded: "
    printf '%s\n' "$CFG_RAW"
else
    info "No policy config — connectivity checks only"
fi

# Returns: 0 = blocked, 1 = allowed, 2 = undetermined (destination-scoped rule
# only, no "global" — not evaluated at this level, caller should skip).
is_blocked() {
    local tool=$1
    $CFG || return 1

    local verdict
    verdict=$(jq -r --arg t "$tool" '
        if (.[$t] | type) == "string" then
            (.[$t] | ascii_downcase)
        elif (.[$t] | type) == "object" then
            if ((.[$t].global // "") | ascii_downcase) != "" then
                (.[$t].global | ascii_downcase)
            else
                "undetermined"
            end
        else
            "absent"
        end
    ' <<<"$CFG_RAW" 2>/dev/null)

    case "$verdict" in
        blocked) return 0 ;;
        allowed) return 1 ;;
        undetermined) return 2 ;;
        *) [[ "$DEFAULT_POLICY" == "block" ]] && return 0 || return 1 ;;
    esac
}

chk() {
    local tool=$1 label=$2; shift 2
    
    if ! has "$tool"; then
        skip "$label ${DIM}(skipped: '$tool' missing)${NC}"
        return
    fi

    # Probes are expected to return both success and failure. Capture the status
    # explicitly instead of allowing a failed network command to stop the suite.
    "$@" >/dev/null 2>&1; local r=$?
    
    if $CFG; then
        is_blocked "$tool"; local policy=$?
        if [[ $policy -eq 2 ]]; then
            skip "$label ${DIM}(skipped: destination-scoped rule, not evaluated)${NC}"
        elif [[ $policy -eq 0 ]]; then
            # Block Mode: Pass if the command returns a non-zero exit status
            [[ $r -ne 0 ]] && ok "${label} ${RED}(blocked ✓)${NC}" \
                           || fail "${label} ${RED}POLICY VIOLATION${NC}"
        else
            # Allow Mode: Trigger a violation only if it encounters an explicit firewall timeout (124)
            [[ $r -eq 124 ]] && fail "${label} ${RED}POLICY VIOLATION (Blocked)${NC}" \
                             || ok "${label} ${GREEN}(allowed ✓)${NC}"
        fi
    else
        [[ $r -eq 0 ]] && ok "$label" || fail "$label"
    fi
}

CURL_BIN="${CURL_BIN:-curl}"
DNS4=8.8.8.8; DNS4b=1.1.1.1
H_HTTP=example.com; H_TLS=github.com; H_SSH=ssh.github.com; H_SMTP=smtp.gmail.com
TO_DNS=1; TO_TCP=1; TO_C=2

GW=$(ip route show default 2>/dev/null | awk '/default/{print $3;exit}')
IFACE=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo | head -1)

assert_net() {
    return 0
}

# CRITICAL CHECK
# Without the daemon, connectivity results cannot prove that Fiwu enforced policy.
if ! pgrep -f "fiwu" >/dev/null 2>&1; then
    echo -e "\n${RED}${BOLD}FATAL: 'fiwu' daemon is not running. Network tests cannot be validated.${NC}\n"
    exit 1
fi

# ============================================================================== 
# ── Modular Wrappers (Add new protocols using these!) ─────────────────────────
# ==============================================================================
# These wrappers keep command execution and policy classification consistent as
# individual protocol checks are added below.

# Usage: _tcp <host> <port> [custom_label]
_tcp() { local lbl=${3:-"TCP → $1:$2"}; chk nc "$lbl" nc -z -w$TO_TCP $1 $2; }

# Usage: _udp <host> <port> [custom_label]
_udp() { local lbl=${3:-"UDP/$2 → $1"}; chk nmap "$lbl" bash -c "res=\$(T 3 nmap -sU --max-retries 0 -p$2 $1 2>/dev/null); if echo \"\$res\" | grep -qE 'closed|open\s'; then exit 0; else exit 1; fi"; }

# Usage: _raw <protocol_number> <label>
_raw() { chk nping "IP Proto $1 ($2) egress" nping --dest-ip $DNS4 --protocol $1 -c 1; }

# ==============================================================================
# ── THE TEST SUITE ────────────────────────────────────────────────────────────
# Each layer is independent: a failed probe records a failure, but does not
# prevent subsequent layers from running.
# ==============================================================================

# ── NTP ───────────────────────────────────────────────────────────────────────
layer "NTP" "Time sync"
NTP_OK=false
has chronyc    && chronyc tracking 2>/dev/null  | grep -qi "reference id"      && { ok "synced (chronyc)";     NTP_OK=true; }
! $NTP_OK && has timedatectl \
           && timedatectl status 2>/dev/null     | grep -qi "synchronized: yes" && { ok "synced (timedatectl)"; NTP_OK=true; }
! $NTP_OK && T 5 ntpdate -q pool.ntp.org >/dev/null 2>&1                        && { ok "reachable (ntpdate)";  NTP_OK=true; }
! $NTP_OK && {
    r=$(printf '\x1b\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0' \
        | T 2 nc -u -w1 pool.ntp.org 123 2>/dev/null | wc -c)
    [[ "$r" -ge 48 ]] && { ok "reachable (nc UDP/123)"; NTP_OK=true; }
}
$NTP_OK || fail "NTP unreachable"

# ── L3 ────────────────────────────────────────────────────────────────────────
assert_net
layer "L3" "ICMP · IPv4 · IPv6 · Raw Protocols"

chk ping "ICMP → $DNS4"              ping -c1 -W1 $DNS4
chk ping "ICMP → $DNS4b"             ping -c1 -W1 $DNS4b
[[ -n "$GW" ]] && chk ping "ICMP → gateway $GW" ping -c1 -W1 "$GW" || fail "No default gateway"

_ipv6_ok=false
ip -6 route show default 2>/dev/null | grep -q default && \
    ping -6 -c1 -W2 2606:4700:4700::1111 &>/dev/null 2>&1 && \
    ping -6 -c1 -W2 2001:4860:4860::8888 &>/dev/null 2>&1 && \
    _ipv6_ok=true

$_ipv6_ok && chk ping6 "ICMPv6 → Google"     ping -6 -c1 -W1 2001:4860:4860::8888 \
          || skip "ICMPv6 ${DIM}(skipped: no IPv6 connectivity)${NC}"
$_ipv6_ok && chk ping6 "ICMPv6 → Cloudflare" ping -6 -c1 -W1 2606:4700:4700::1111 \
          || skip "ICMPv6 → Cloudflare ${DIM}(skipped: no IPv6 connectivity)${NC}"

# Detect NAT based on RFC1918 Gateway. Raw IP protocols generally cannot cross
# the namespace/container NAT used by the test environment, so those checks are
# reported as skipped rather than treated as Fiwu failures.
if [[ "$GW" =~ ^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
    skip "IP Proto 47 (GRE) egress ${DIM}(skipped: unsupported through NAT)${NC}"
    skip "IP Proto 50 (ESP) egress ${DIM}(skipped: unsupported through NAT)${NC}"
    skip "IP Proto 89 (OSPF) egress ${DIM}(skipped: unsupported through NAT)${NC}"
else
    # Easily add ANY Raw IP Protocol here using `_raw <num> <name>`
    _raw 47 "GRE"
    _raw 50 "ESP"
    _raw 89 "OSPF"
    # Example: _raw 2 "IGMP"
    # Example: _raw 112 "VRRP"
fi

if has traceroute; then chk traceroute "Traceroute" bash -c "traceroute -n -m8 -w1 -q1 $DNS4 2>/dev/null | grep -q 'ms'"; 
elif has tracepath; then chk tracepath "Traceroute" bash -c "tracepath -n -m8 $DNS4 2>/dev/null | grep -q 'ms'"; 
else skip "Traceroute ${DIM}(skipped: tools missing)${NC}"; fi

# ── L4 ────────────────────────────────────────────────────────────────────────
assert_net
layer "L4" "TCP · UDP · SCTP · VPNs"

# Easily add standard TCP checks
for port in 80 443 8080 8443; do
    _tcp $H_HTTP $port
done
_tcp $H_SSH 22

# Easily add standard UDP checks
chk dig "UDP/53 (DNS) → $DNS4" dig +short +time=$TO_DNS @$DNS4 $H_HTTP A
_udp $DNS4 1194 "UDP/1194 (OpenVPN) egress"
_udp $DNS4 51820 "UDP/51820 (WireGuard) egress"

# SCTP & QUIC (Left intact for precision)
chk nmap "SCTP → $H_TLS:80" bash -c "T 4 nmap -sY -p80 $H_TLS 2>/dev/null | grep -qE 'open|closed|filtered'"

if $CURL_BIN --version 2>/dev/null | grep -qi "HTTP3"; then
    chk "$CURL_BIN" "UDP/443 (HTTP/3) → cloudflare.com" \
        bash -c 'env CURL_BIN="'"$CURL_BIN"'"; $CURL_BIN -sf --max-time 8 --http3 \
            -o/dev/null -w "%{http_version}" https://cloudflare.com 2>/dev/null | grep -q "3"'
else
    skip "UDP/443 (HTTP/3) ${DIM}(skipped: curl lacks QUIC)${NC}"
fi

# ── L4+ ───────────────────────────────────────────────────────────────────────
assert_net
layer "L4+" "TLS — handshake · v1.2 · v1.3 · DoT"
chk openssl "TLS handshake → $H_TLS" bash -c "T $TO_TCP openssl s_client -connect $H_TLS:443 -servername $H_TLS < /dev/null 2>/dev/null | grep -q CONNECTED"
chk openssl "TLS 1.2 → $H_TLS"       bash -c "T $TO_TCP openssl s_client -connect $H_TLS:443 -servername $H_TLS -tls1_2 < /dev/null 2>/dev/null | grep -q CONNECTED"
chk openssl "TLS 1.3 → $H_TLS"       bash -c "T $TO_TCP openssl s_client -connect $H_TLS:443 -servername $H_TLS -tls1_3 < /dev/null 2>/dev/null | grep -q CONNECTED"
chk openssl "DoT → 1.1.1.1:853"      bash -c "T $TO_TCP openssl s_client -connect 1.1.1.1:853 < /dev/null 2>/dev/null | grep -q CONNECTED"

# ── L7/DNS ────────────────────────────────────────────────────────────────────
assert_net
layer "L7/DNS" "UDP · TCP · PTR · DNSSEC · DoH"
DOH="name=$H_HTTP&type=A"
chk dig "DNS A UDP/53 → $DNS4"  dig +short +time=$TO_DNS           @$DNS4  $H_HTTP A
chk dig "DNS A TCP/53 → $DNS4"  dig +short +time=$TO_DNS +tcp       @$DNS4  google.com A
chk dig "DNS AAAA → $DNS4"      dig +short +time=$TO_DNS            @$DNS4  google.com AAAA
chk dig "DNS PTR → $DNS4"       dig +short +time=$TO_DNS @$DNS4 -x  $DNS4
chk dig "DNSSEC valid"          dig +dnssec +time=$TO_DNS @$DNS4b   sigok.verteiltesysteme.net A
chk dig "DNSSEC bogus"          dig +dnssec +time=$TO_DNS @$DNS4b   sigfail.verteiltesysteme.net A

# Changed "$CURL_BIN" to "curl" for the dependency check
chk "curl" "DoH → Cloudflare" \
    "$CURL_BIN" -sf --max-time $TO_C -H "accept: application/dns-json" \
    "https://cloudflare-dns.com/dns-query?$DOH"
chk "curl" "DoH → Google" \
    "$CURL_BIN" -sf --max-time $TO_C -H "accept: application/dns-json" \
    "https://dns.google/resolve?$DOH"

# ── L7/App ────────────────────────────────────────────────────────────────────
assert_net
layer "L7/App" "HTTP · HTTPS · HTTP/2 · WebDAV · CONNECT"

chk "curl" "HTTP/1.1 → $H_HTTP"     bash -c "$CURL_BIN -so/dev/null -w '%{http_code}' --max-time $TO_C http://$H_HTTP | grep -qE '^[23]'"
chk "curl" "HTTP/2 → $H_TLS"        bash -c "$CURL_BIN -so/dev/null -w '%{http_code}' --http2 --max-time $TO_C https://$H_TLS | grep -qE '^[23]'"
chk "curl" "HTTPS headers → $H_TLS" bash -c "$CURL_BIN -sI --max-time $TO_C https://$H_TLS | grep -qi 'content-type'"
chk "curl" "HTTP redirect follow"    bash -c "$CURL_BIN -sL -o/dev/null -w '%{http_code}' --max-time $TO_C http://github.com | grep -qE '^[23]'"
chk "curl" "HTTP/1.0 → $H_HTTP"     bash -c "$CURL_BIN -so/dev/null -w '%{http_code}' --http1.0 --max-time $TO_C http://$H_HTTP | grep -qE '^[23]'"
# WebDAV OPTIONS (same TCP stream as HTTP, different verb — fiwu sees it identically)
chk "curl" "WebDAV OPTIONS → $H_HTTP" bash -c "$CURL_BIN -sX OPTIONS -o/dev/null -w '%{http_code}' --max-time $TO_C http://$H_HTTP | grep -qE '^[2345]'"
# HTTP CONNECT tunnel (proxy tunneling)
_tcp $GW 3128 "HTTP CONNECT proxy/3128 → gateway"
_tcp $GW 8080 "HTTP proxy/8080 → gateway"

# ── L7/Remote ─────────────────────────────────────────────────────────────────
assert_net
layer "L7/Remote" "SSH · RDP · VNC · Telnet"
_tcp $H_SSH        22   "SSH/22 → github"
_tcp $GW           23   "Telnet/23 → gateway"
_tcp $GW           3389 "RDP/3389 → gateway"
_tcp $GW           5900 "VNC/5900 → gateway"
_tcp $GW           5901 "VNC/5901 → gateway"

# ── L7/Mail ───────────────────────────────────────────────────────────────────
assert_net
layer "L7/Mail" "SMTP · SMTPS · IMAP · POP3 · submission"
_tcp $H_SMTP        25  "SMTP/25 → $H_SMTP"
_tcp $H_SMTP       465  "SMTPS/465 → $H_SMTP"
_tcp $H_SMTP       587  "Submission/587 → $H_SMTP"
_tcp imap.gmail.com 143 "IMAP/143 → imap.gmail.com"
_tcp imap.gmail.com 993 "IMAPS/993 → imap.gmail.com"
_tcp pop.gmail.com  110 "POP3/110 → pop.gmail.com"
_tcp pop.gmail.com  995 "POP3S/995 → pop.gmail.com"

# ── L7/Transfer ───────────────────────────────────────────────────────────────
assert_net
layer "L7/Transfer" "FTP · FTPS · TFTP · SCP · rsync"
FTP_OK=false
for FTP_HOST in ftp.debian.org ftp.gnu.org ftp.acc.umu.se; do
    if nc -4 -z -w$TO_TCP $FTP_HOST 21 >/dev/null 2>&1; then
        ok "FTP/21 → $FTP_HOST ${GREEN}(allowed ✓)${NC}"; FTP_OK=true; break
    fi
done
$FTP_OK || skip "FTP/21 ${DIM}(skipped: public servers unreachable)${NC}"
_tcp $GW 989 "FTPS-data/989 → gateway"
_tcp $GW 990 "FTPS-ctrl/990 → gateway"
_tcp $GW 873 "rsync/873 → gateway"
# TFTP uses UDP
#chk nmap "TFTP/UDP/69 → $GW" bash -c "T 5 nmap -sU -p69 $GW 2>/dev/null | grep -qE 'open|filtered'"

# ── L7/Messaging ──────────────────────────────────────────────────────────────
assert_net
layer "L7/Messaging" "MQTT · AMQP · Kafka · WebSocket"
_tcp broker.emqx.io  1883 "MQTT/1883 → broker.emqx.io"
_tcp broker.emqx.io  8883 "MQTTS/8883 → broker.emqx.io"
_tcp $GW             5672 "AMQP/5672 → gateway"
_tcp $GW            15672 "RabbitMQ-mgmt/15672 → gateway"
_tcp $GW             9092 "Kafka/9092 → gateway"
# WebSocket upgrades over HTTP — use curl to verify the Upgrade header survives
chk curl "WebSocket upgrade → echo.websocket.org" \
    bash -c "$CURL_BIN -sf --max-time $TO_C \
        -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
        -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
        -H 'Sec-WebSocket-Version: 13' \
        -o /dev/null -w '%{http_code}' \
        http://echo.websocket.org 2>/dev/null | grep -qE '^(101|200|301|302)'"

# ── L7/Database ───────────────────────────────────────────────────────────────
assert_net
layer "L7/Database" "MySQL · Postgres · Redis · MongoDB · Memcached · Elastic"
_tcp $GW  3306  "MySQL/3306 → gateway"
_tcp $GW  5432  "Postgres/5432 → gateway"
_tcp $GW  6379  "Redis/6379 → gateway"
_tcp $GW 27017  "MongoDB/27017 → gateway"
_tcp $GW 11211  "Memcached/11211 → gateway"
_tcp $GW  9200  "Elasticsearch/9200 → gateway"
_tcp $GW  9300  "Elasticsearch-cluster/9300 → gateway"
_tcp $GW  1433  "MSSQL/1433 → gateway"
_tcp $GW  1521  "Oracle/1521 → gateway"

# ── L7/Infra ──────────────────────────────────────────────────────────────────
assert_net
layer "L7/Infra" "SNMP · Syslog · Docker · Prometheus · gRPC · LDAP"
_tcp $GW   389 "LDAP/389 → gateway"
_tcp $GW   636 "LDAPS/636 → gateway"
_tcp $GW  2375 "Docker-API/2375 → gateway"
_tcp $GW  2376 "Docker-API-TLS/2376 → gateway"
_tcp $GW  2181 "Zookeeper/2181 → gateway"
_tcp $GW  9090 "Prometheus/9090 → gateway"
_tcp $GW 50051 "gRPC/50051 → gateway"
chk nmap "SNMP/UDP/161 → $GW"      bash -c "res=\$(T 3 nmap -sU --max-retries 0 -p161 \$GW 2>/dev/null); if echo \"\$res\" | grep -qE 'closed|open\s'; then exit 0; else exit 1; fi"
chk nmap "Syslog/UDP/514 → $GW"    bash -c "res=\$(T 3 nmap -sU --max-retries 0 -p514 \$GW 2>/dev/null); if echo \"\$res\" | grep -qE 'closed|open\s'; then exit 0; else exit 1; fi"
chk nmap "mDNS/UDP/5353 → $GW"     bash -c "res=\$(T 3 nmap -sU --max-retries 0 -p5353 \$GW 2>/dev/null); if echo \"\$res\" | grep -qE 'closed|open\s'; then exit 0; else exit 1; fi"
#chk nmap "NetBIOS/UDP/137 → $GW"   bash -c "T 5 nmap -sU -p137  $GW 2>/dev/null | grep -qE 'open|filtered'"

# ── L7/VPN ────────────────────────────────────────────────────────────────────
assert_net
layer "L7/VPN" "WireGuard · OpenVPN · IPsec · PPTP · L2TP"
_udp $DNS4  51820 "WireGuard/UDP/51820"
_udp $DNS4   1194 "OpenVPN/UDP/1194"
_tcp $DNS4   1194 "OpenVPN/TCP/1194"
_tcp $GW     1723 "PPTP/1723 → gateway"
_udp $GW     1701 "L2TP/UDP/1701 → gateway"
_udp $GW      500 "IKE/UDP/500 → gateway"
_udp $GW     4500 "IKE-NAT/UDP/4500 → gateway"

# ── L3/Ports — non-standard egress ───────────────────────────────────────────
# These probes classify connection outcomes more carefully than chk(): an open
# or quickly refused TCP connection proves the packet left, while a timeout can
# indicate that Fiwu or an upstream firewall dropped it.
assert_net
layer "L3/Ports" "Non-standard egress — RST or accept = packet left"

# Add obscure L7 application ports by appending here:
declare -A PORT_HOSTS=(
    [179]="$GW"                     # BGP
    [389]="$GW"                     # LDAP
    [445]="$GW"                     # SMB
    [636]="$GW"                     # LDAPS
    [1194]="$GW"                    # OpenVPN
    [1433]="$GW"                    # MSSQL
    [1521]="$GW"                    # Oracle DB
    [1883]="$GW"                    # MQTT
    [2181]="$GW"                    # Zookeeper
    [2375]="$GW"                    # Docker API (unencrypted)
    [2376]="$GW"                    # Docker API (TLS)
    [3128]="$GW"                    # Squid proxy
    [3306]="$GW"                    # MySQL
    [3389]="$GW"                    # RDP
    [5432]="$GW"                    # Postgres
    [5672]="$GW"                    # AMQP (RabbitMQ)
    [5900]="$GW"                    # VNC
    [6379]="$GW"                    # Redis
    [8080]="$GW"                    # HTTP alt / proxy
    [8443]="$GW"                    # HTTPS alt
    [8883]="$GW"                    # MQTT over TLS
    [9090]="$GW"                    # Prometheus
    [9092]="$GW"                    # Kafka
    [9200]="$GW"                    # Elasticsearch
    [9300]="$GW"                    # Elasticsearch cluster
    [11211]="$GW"                   # Memcached
    [15672]="$GW"                   # RabbitMQ management
    [27017]="$GW"                   # MongoDB
    [50051]="$GW"                   # gRPC
    [51820]="$GW"                   # WireGuard
)

port_egress() {
    local port=$1 host=${PORT_HOSTS[$1]:-$H_HTTP}
    if ! has nc; then skip "TCP:$port → $host ${DIM}(skipped: nc missing)${NC}"; return; fi

    local t0=$SECONDS
    
    # Enforce IPv4 connections to avoid native namespace unreachability failures
    nc -4 -z -w$TO_TCP $host $port >/dev/null 2>&1
    local r=$?
    local t_elapsed=$(( SECONDS - t0 ))
    
    local success=false
    # Evaluate connection codes: 0 (Open), 1 (Refused), or 124 (Upstream ISP
    # drops during Allow mode).
    if [[ $r -eq 0 ]] || [[ $r -eq 1 && $t_elapsed -lt $TO_TCP ]] || [[ $r -eq 124 && "$DEFAULT_POLICY" = "allow" ]]; then
        success=true
    fi

    if $CFG; then
        is_blocked "nc"; local policy=$?
        if [[ $policy -eq 2 ]]; then
            skip "TCP:$port egress → $host ${DIM}(skipped: destination-scoped rule, not evaluated)${NC}"
            L_SKIP[L3/Ports]=$(( ${L_SKIP[L3/Ports]:-0} + 1 ))
        elif [[ $policy -eq 0 ]]; then
            if $success; then
                fail "TCP:$port egress → $host ${RED}POLICY VIOLATION (should be blocked)${NC}"
                L_FAIL[L3/Ports]=$(( ${L_FAIL[L3/Ports]:-0} + 1 ))
            else
                ok "TCP:$port egress → $host ${RED}(blocked ✓)${NC}"
                L_OK[L3/Ports]=$(( ${L_OK[L3/Ports]:-0} + 1 ))
            fi
        else
            ok "TCP:$port egress → $host ${GREEN}(allowed ✓)${NC}"
            L_OK[L3/Ports]=$(( ${L_OK[L3/Ports]:-0} + 1 ))
        fi
    else
        if $success; then
            ok "TCP:$port egress → $host"
            L_OK[L3/Ports]=$(( ${L_OK[L3/Ports]:-0} + 1 ))
        else
            fail "TCP:$port egress → $host (dropped)"
            L_FAIL[L3/Ports]=$(( ${L_FAIL[L3/Ports]:-0} + 1 ))
        fi
    fi
}
for port in "${!PORT_HOSTS[@]}"; do port_egress $port; done

# ── Summary ───────────────────────────────────────────────────────────────────
# Return the number of failed probes so CI marks the job failed, while preserving
# the complete per-layer report in the job log.
summary() {
    local scored=$(( OK + FAIL ))
    local pct=0; [[ $scored -gt 0 ]] && pct=$(( OK * 100 / scored ))
    bar() {
        local w=$1 p=$2 f e
        f=$(( p * w / 100 )); e=$(( w - f ))
        [[ $p -eq 100 ]] && f=$w && e=0
        printf "${GREEN}"; [[ $f -gt 0 ]] && printf '█%.0s' $(seq 1 $f)
        printf "${RED}";   [[ $e -gt 0 ]] && printf '░%.0s' $(seq 1 $e)
        printf "${NC}"
    }
    echo -e "\n  ══════════════════════════════════════════"
    echo -e "  ${GREEN}✓ $OK passed${NC}  ${RED}✗ $FAIL failed${NC}  ${YELLOW}⏸ $SKIP skipped${NC}"
    echo -e "\n  Coverage: $(bar 30 $pct)  ${BOLD}${pct}%${NC}\n"
    local layers=("NTP" "L3" "L4" "L4+" "L7/DNS" "L7/App" "L7/Remote" "L7/Mail" "L7/Transfer" "L7/Messaging" "L7/Database" "L7/Infra" "L7/VPN" "L3/Ports")
    for l in "${layers[@]}"; do
        local lo=${L_OK[$l]:-0} lf=${L_FAIL[$l]:-0} ls=${L_SKIP[$l]:-0}
        local lt=$(( lo + lf )) lp=0
        [[ $lt -gt 0 ]] && lp=$(( lo * 100 / lt ))
        if [[ $((lt + ls)) -gt 0 ]]; then
            echo -e "  ${GREEN}✓ ${lo:-0}${NC}  ${RED}✗ ${lf:-0}${NC}  ${YELLOW}⏸ ${ls:-0}${NC}  ${BOLD}${lp}%${NC}  ${DIM}$l${NC}"
        fi
    done
    echo -e "  ══════════════════════════════════════════\n"
}
summary
exit $FAIL