#!/bin/bash
# Fiwu differential benchmark: nginx + iperf3 on the host, load from a client netns,
# baseline (Fiwu stopped) vs active (Fiwu running).
# Env: BENCH_CONCURRENCY (default 50), BENCH_SKIP_QUEUE_CHECK=1, OS_TAG
set -e

[[ $EUID -eq 0 ]] || { echo "Error: must be run as root (sudo)." >&2; exit 1; }
for tool in iperf3 awk jq wrk nginx; do
    command -v "$tool" >/dev/null || { echo "Error: '$tool' is not installed." >&2; exit 1; }
done

BENCHMARK_RATE=${BENCHMARK_RATE:-10000}; WRK_CONNECTIONS=50; WRK_TIME=5; IPERF_TIME=5; IPERF_RUNS=3
SERVER_IP=10.200.0.1; CLIENT_IP=10.200.0.2
NS_NAME=bench_client; VETH_MAIN=veth_main; VETH_CLIENT=veth_client
HTTP_PORT=8080; IPERF_PORT=5201
QUEUE_FILE=/proc/net/netfilter/nfnetlink_queue
CONFIG_PATH=/etc/fiwu/config.json
NGINX_CONF=/etc/nginx/fiwu_bench.conf; DOCROOT=/var/www/fiwu_bench
NETD_UNMANAGED=/run/systemd/network/00-fiwu-bench.network
BACKUP=$(mktemp); HAD_CONFIG=0; HTTP_PID=""; IPERF_PID=""

sysctl -w net.ipv4.tcp_tw_reuse=1 net.ipv4.ip_local_port_range="1024 65535" >/dev/null 2>&1 || true
ulimit -n 65535 2>/dev/null || true

ns() { ip netns exec "$NS_NAME" "$@"; }

stop_fiwu() {
    if [ -d /run/systemd/system ] && systemctl is-active --quiet fiwu.service 2>/dev/null; then
        systemctl stop fiwu.service
    fi
    pkill -x fiwu 2>/dev/null || true
    iptables -F 2>/dev/null || true
    iptables -t mangle -F 2>/dev/null || true
}

cleanup() {
    echo "Cleaning up..."
    kill $HTTP_PID $IPERF_PID 2>/dev/null || true
    stop_fiwu
    ip netns delete "$NS_NAME" 2>/dev/null || true
    ip link delete "$VETH_MAIN" 2>/dev/null || true
    [ -f "$NETD_UNMANAGED" ] && rm -f "$NETD_UNMANAGED" && { networkctl reload 2>/dev/null || true; }
    if [ "$HAD_CONFIG" = 1 ]; then mv "$BACKUP" "$CONFIG_PATH"; else rm -f "$CONFIG_PATH" "$BACKUP"; fi
}
trap cleanup EXIT

# Shown only when the namespace can't reach the server, to identify the broken layer.
probe() {
    set +e
    { echo "--- NETWORK PROBE ---"
      ip -4 addr show dev "$VETH_MAIN" | grep -q "$SERVER_IP" || echo "host address $SERVER_IP MISSING on $VETH_MAIN"
      ip -br addr show dev "$VETH_MAIN"; ns ip -br addr; ss -ltn "sport = :$HTTP_PORT"
      iptables -S INPUT | head -5; nft list ruleset | head -30
    } >&2 2>&1
}

[ -f "$CONFIG_PATH" ] && { cp "$CONFIG_PATH" "$BACKUP"; HAD_CONFIG=1; }

# NetworkManager / systemd-networkd can reset or strip addresses on new veths on
# Debian, so mark ours unmanaged BEFORE creating them (only if those services run).
if systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    mkdir -p /run/systemd/network
    printf '[Match]\nName=%s %s\n\n[Link]\nUnmanaged=yes\n' "$VETH_MAIN" "$VETH_CLIENT" > "$NETD_UNMANAGED"
    networkctl reload 2>/dev/null || true
fi

echo "Configuring network namespaces..."
ip netns add "$NS_NAME"
ip link add "$VETH_MAIN" type veth peer name "$VETH_CLIENT"
if command -v nmcli >/dev/null && systemctl is-active --quiet NetworkManager 2>/dev/null; then
    nmcli device set "$VETH_MAIN" managed no 2>/dev/null || true
fi
ip link set "$VETH_CLIENT" netns "$NS_NAME"
ip addr add "$SERVER_IP/24" dev "$VETH_MAIN"
ip link set "$VETH_MAIN" up
ns ip addr add "$CLIENT_IP/24" dev "$VETH_CLIENT"
ns ip link set "$VETH_CLIENT" up
ns ip link set lo up

mkdir -p /etc/fiwu
cat > "$CONFIG_PATH" <<EOF
{ "default": "allow", "iperf3": { "global": "allowed" }, "nginx": { "global": "allowed" } }
EOF

systemctl stop nginx iperf3 2>/dev/null || true
pkill -x nginx 2>/dev/null || true
pkill -x iperf3 2>/dev/null || true

echo "Configuring Nginx backend on $SERVER_IP..."
mkdir -p "$DOCROOT" /var/log/nginx
echo "OK" > "$DOCROOT/index.html"
chmod -R 755 "$DOCROOT"
cat > "$NGINX_CONF" <<EOF
error_log /var/log/nginx/fiwu_bench_error.log;
pid /run/fiwu_bench.pid;
worker_processes auto;
events { worker_connections 10240; multi_accept on; }
http {
    access_log off;
    keepalive_timeout 0;
    server { listen 0.0.0.0:$HTTP_PORT; root $DOCROOT; location / { try_files /index.html =404; } }
}
EOF
nginx -t -c "$NGINX_CONF" || { echo "Nginx config test failed!" >&2; exit 1; }

nginx -c "$NGINX_CONF" -g "daemon off;" >/dev/null 2>&1 &
HTTP_PID=$!
iperf3 -s -B 0.0.0.0 -p "$IPERF_PORT" >/tmp/iperf_bench.log 2>&1 &
IPERF_PID=$!
sleep 2

for spec in "nginx $HTTP_PID /var/log/nginx/fiwu_bench_error.log" "iperf3 $IPERF_PID /tmp/iperf_bench.log"; do
    read -r name pid log <<< "$spec"
    kill -0 "$pid" 2>/dev/null || { echo "Error: $name crashed on startup:" >&2; cat "$log" >&2; exit 1; }
done

echo "Verifying namespace can reach nginx..."
for _ in $(seq 1 10); do
    ns bash -c "exec 3<>/dev/tcp/$SERVER_IP/$HTTP_PORT" 2>/dev/null && reachable=1 && break
    sleep 0.5
done
[ "$reachable" = 1 ] || { echo "Error: namespace cannot reach $SERVER_IP:$HTTP_PORT" >&2; probe; exit 1; }

# Prints "<req/sec> <avg latency ms>"
measure_churn() {
    cat << EOF > /tmp/rate_limit.lua
function delay()
    return ($WRK_CONNECTIONS * 1000) / $BENCHMARK_RATE
end
EOF

    ns wrk -t"$(nproc)" -c"$WRK_CONNECTIONS" -d"${WRK_TIME}"s -s /tmp/rate_limit.lua -H "Connection: close" \
        "http://$SERVER_IP:$HTTP_PORT/index.html" > /tmp/wrk.log 2>&1 || true
    awk '/Requests\/sec:/ {r=$2}
         /Latency/ && !seen {v=$2; n=v; gsub(/[a-zA-Z]+/, "", n)
                             if (v ~ /us$/) n/=1000; else if (v !~ /ms$/ && v ~ /s$/) n*=1000
                             l=n+0; seen=1}
         END {if (!r) exit 1; printf "%s %.3f", r, l}' /tmp/wrk.log \
        || { echo "Error: wrk produced no results:" >&2; cat /tmp/wrk.log >&2; return 1; }
}

# Prints median received Mbps over IPERF_RUNS runs
measure_throughput() {
    local vals=() out val
    for _ in $(seq "$IPERF_RUNS"); do
        out=$(ns iperf3 -c "$SERVER_IP" -p "$IPERF_PORT" -t "$IPERF_TIME" -O 1 -J 2>&1) || true
        val=$(jq -e '.end.sum_received.bits_per_second / 1000000' <<<"$out" 2>/dev/null) \
            || { echo "Error: iperf3 failed: $(jq -r '.error // empty' <<<"$out" 2>/dev/null)" >&2; return 1; }
        vals+=("$val"); sleep 1
    done
    printf '%s\n' "${vals[@]}" | LC_ALL=C sort -n | awk '{a[NR]=$1} END {printf "%.3f", a[int((NR+1)/2)]}'
}

queue_counter() { awk '{s+=$8} END {print s+0}' "$QUEUE_FILE" 2>/dev/null || echo 0; }
mbps() { awk "BEGIN {printf \"%.0f\", $1}"; }

echo "--- PHASE A: Baseline (Fiwu STOPPED) ---"
stop_fiwu
CHURN=$(measure_churn)
read -r RPS_BASE LATENCY_BASE <<< "$CHURN"
echo "Baseline RPS:      $RPS_BASE Req/sec (Latency: $LATENCY_BASE ms)"
THROUGHPUT_BASE=$(measure_throughput)
echo "Baseline Throughput: $(mbps "$THROUGHPUT_BASE") Mbps"

echo "--- PHASE B: Active (Fiwu RUNNING) ---"
stop_fiwu
fiwu -g dev >/tmp/fiwu_run.log 2>&1 &
for _ in $(seq 1 20); do   # wait up to 10s for the daemon to attach NFQUEUE
    grep -q . "$QUEUE_FILE" 2>/dev/null && break
    sleep 0.5
done
# Replace Fiwu's fail-open rule with one that forces server replies through the queue
iptables -D OUTPUT -p tcp -j NFQUEUE --queue-num 1 --queue-bypass 2>/dev/null || true
echo "Forcing veth_main traffic into Fiwu's NFQUEUE..."
iptables -I OUTPUT -p tcp --sport "$HTTP_PORT" -j NFQUEUE --queue-num 1
Q_BEFORE=$(queue_counter)

CHURN=$(measure_churn)
read -r RPS_ACTIVE LATENCY_ACTIVE <<< "$CHURN"
echo "Active RPS:        $RPS_ACTIVE Req/sec (Latency: $LATENCY_ACTIVE ms)"
THROUGHPUT_ACTIVE=$(measure_throughput)
echo "Active Throughput:   $(mbps "$THROUGHPUT_ACTIVE") Mbps"

Q_AFTER=$(queue_counter)
if [ "$Q_AFTER" -le "$Q_BEFORE" ] && [ "${BENCH_SKIP_QUEUE_CHECK:-0}" != 1 ]; then
    echo "Error: no packets reached the NFQUEUE during the active phase; results are invalid." >&2
    exit 1
fi
echo "Total packets sent to Fiwu queue during benchmark: $((Q_AFTER - Q_BEFORE))"

pct() { awk "BEGIN {if ($2 > 0) printf \"%.1f\", ($1 / $2) * 100; else print 0}"; }
LATENCY_DELTA=$(awk "BEGIN {printf \"%.3f\", $LATENCY_ACTIVE - $LATENCY_BASE}")
RPS_PCT=$(pct "$RPS_ACTIVE" "$RPS_BASE")
THROUGHPUT_PCT=$(pct "$THROUGHPUT_ACTIVE" "$THROUGHPUT_BASE")

echo
echo "========================================="
echo "         BENCHMARK RESULTS               "
echo "========================================="
echo " Connection Overhead: $(awk "BEGIN {printf \"%+.3f\", $LATENCY_DELTA}") ms"
echo " RPS Retained:        $RPS_PCT %"
echo " Throughput Retained: $THROUGHPUT_PCT %"
echo "========================================="

TAG=${OS_TAG#lxc:}; TAG=${TAG:-local}
OUT_FILE="benchmark_results_${TAG}.json"
jq -n --arg sha "${CI_COMMIT_SHORT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}" --arg tag "$TAG" \
    --argjson lb "$LATENCY_BASE" --argjson la "$LATENCY_ACTIVE" --argjson ld "$LATENCY_DELTA" \
    --argjson rb "$RPS_BASE" --argjson ra "$RPS_ACTIVE" --argjson rp "$RPS_PCT" \
    --argjson tb "$THROUGHPUT_BASE" --argjson ta "$THROUGHPUT_ACTIVE" --argjson tp "$THROUGHPUT_PCT" \
    '{commit_sha: $sha, ($tag): {
        baseline_latency_ms: $lb, active_latency_ms: $la, latency_overhead_ms: $ld,
        baseline_rps: $rb, active_rps: $ra, rps_retention_pct: $rp,
        baseline_throughput_mbps: $tb, active_throughput_mbps: $ta, throughput_retention_pct: $tp}}' > "$OUT_FILE"
echo "Saved metrics to $OUT_FILE"