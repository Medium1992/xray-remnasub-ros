#!/bin/sh
set -eu

NETWORK_INTERFACE=${NETWORK_INTERFACE:-auto}
NETWORK_RESET_IPV4_FORWARDING=${NETWORK_RESET_IPV4_FORWARDING:-1}
NETWORK_DISABLE_IPV6=${NETWORK_DISABLE_IPV6:-1}
NETWORK_QDISC=${NETWORK_QDISC:-fq_codel}
NETWORK_DISABLE_MULTICAST=${NETWORK_DISABLE_MULTICAST:-1}
NETWORK_CT_ESTABLISHED=${NETWORK_CT_ESTABLISHED:-86400}
NETWORK_CT_SYN_SENT=${NETWORK_CT_SYN_SENT:-5}
NETWORK_CT_SYN_RECV=${NETWORK_CT_SYN_RECV:-5}
NETWORK_CT_FIN_WAIT=${NETWORK_CT_FIN_WAIT:-10}
NETWORK_CT_CLOSE_WAIT=${NETWORK_CT_CLOSE_WAIT:-10}
NETWORK_CT_LAST_ACK=${NETWORK_CT_LAST_ACK:-10}
NETWORK_CT_TIME_WAIT=${NETWORK_CT_TIME_WAIT:-10}
NETWORK_CT_CLOSE=${NETWORK_CT_CLOSE:-10}
NETWORK_CT_UNACKNOWLEDGED=${NETWORK_CT_UNACKNOWLEDGED:-300}
NETWORK_CT_UDP_STREAM=${NETWORK_CT_UDP_STREAM:-180}

resolve_interface() {
  if [ "$NETWORK_INTERFACE" != auto ] && ip link show dev "$NETWORK_INTERFACE" >/dev/null 2>&1; then
    printf '%s\n' "$NETWORK_INTERFACE"
    return 0
  fi
  resolved=$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
  [ -n "$resolved" ] && { printf '%s\n' "$resolved"; return 0; }
  ip -o link show up | awk -F': ' '/link\/ether/ {
    gsub(/@.*$/, "", $2)
    if ($2 != "lo" && $2 != "Xray" && $2 != "Meta" && $2 !~ /^hs5t/) {print $2; exit}
  }'
}

iface=$(resolve_interface)
[ -n "$iface" ] || { echo 'network interface not found' >&2; exit 1; }

if [ "$NETWORK_RESET_IPV4_FORWARDING" = 1 ]; then
  sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
fi
sysctl -w net.ipv6.conf.all.disable_ipv6="$NETWORK_DISABLE_IPV6" >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6="$NETWORK_DISABLE_IPV6" >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.all.forwarding=0 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.forwarding=0 >/dev/null 2>&1 || true
for value in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
  [ -e "$value" ] || continue
  printf '%s\n' "$NETWORK_DISABLE_IPV6" > "$value" 2>/dev/null || true
done

sysctl -w net.netfilter.nf_conntrack_tcp_timeout_established="$NETWORK_CT_ESTABLISHED" >/dev/null 2>&1 || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_syn_sent="$NETWORK_CT_SYN_SENT" >/dev/null 2>&1 || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_syn_recv="$NETWORK_CT_SYN_RECV" >/dev/null 2>&1 || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_fin_wait="$NETWORK_CT_FIN_WAIT" >/dev/null 2>&1 || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close_wait="$NETWORK_CT_CLOSE_WAIT" >/dev/null 2>&1 || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_last_ack="$NETWORK_CT_LAST_ACK" >/dev/null 2>&1 || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait="$NETWORK_CT_TIME_WAIT" >/dev/null 2>&1 || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_close="$NETWORK_CT_CLOSE" >/dev/null 2>&1 || true
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_unacknowledged="$NETWORK_CT_UNACKNOWLEDGED" >/dev/null 2>&1 || true
sysctl -w net.netfilter.nf_conntrack_udp_timeout_stream="$NETWORK_CT_UDP_STREAM" >/dev/null 2>&1 || true

case "$NETWORK_QDISC" in
  system)
    tc qdisc del dev "$iface" root >/dev/null 2>&1 || true
    ;;
  fq_codel|cake|codel|sfq|pfifo|bfifo)
    if ! tc qdisc replace dev "$iface" root "$NETWORK_QDISC" >/dev/null 2>&1; then
      echo "qdisc '$NETWORK_QDISC' unavailable on $iface; use this queue in RouterOS first" >&2
    fi
    ;;
esac

if [ "$NETWORK_DISABLE_MULTICAST" = 1 ]; then
  ip link set dev "$iface" multicast off >/dev/null 2>&1 || true
else
  ip link set dev "$iface" multicast on >/dev/null 2>&1 || true
fi

for table in unspec masquerade; do
  for pref in $(ip rule show | awk -v table="$table" '$2 == "from" && $3 == "all" && $4 == "lookup" && $5 == table && NF == 5 {gsub(/:/, "", $1); print $1}'); do
    ip rule del pref "$pref" 2>/dev/null || true
  done
done

for table_pref in 'local 0' 'main 32766' 'default 32767'; do
  table=${table_pref% *}
  wanted=${table_pref#* }
  for pref in $(ip rule show | awk -v table="$table" '$2 == "from" && $3 == "all" && $4 == "lookup" && $5 == table && NF == 5 {gsub(/:/, "", $1); print $1}'); do
    ip rule del pref "$pref" 2>/dev/null || true
  done
  ip rule add pref "$wanted" lookup "$table"
done

printf 'interface=%s ipv6_disabled=%s qdisc=%s multicast_disabled=%s\n' \
  "$iface" "$NETWORK_DISABLE_IPV6" "$NETWORK_QDISC" "$NETWORK_DISABLE_MULTICAST"
