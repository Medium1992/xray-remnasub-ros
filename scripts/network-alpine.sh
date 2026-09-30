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
NETWORK_TCP_NOTSENT_LOWAT=${NETWORK_TCP_NOTSENT_LOWAT:-131072}
NETWORK_TCP_SLOW_START_AFTER_IDLE=${NETWORK_TCP_SLOW_START_AFTER_IDLE:-0}
NETWORK_TCP_MTU_PROBING=${NETWORK_TCP_MTU_PROBING:-1}
NETWORK_TCP_FIN_TIMEOUT=${NETWORK_TCP_FIN_TIMEOUT:-30}
NETWORK_TCP_CONGESTION=${NETWORK_TCP_CONGESTION:-system}
NETWORK_TCP_BUFFER_MAX=${NETWORK_TCP_BUFFER_MAX:-system}
NETWORK_INFO_FILE=${NETWORK_INFO_FILE:-}
NETWORK_SYSCTL_ORIGINAL_FILE=${NETWORK_SYSCTL_ORIGINAL_FILE:-}

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

# Сокеты контейнера, то есть исходящие соединения Xray к серверам. Контейнер
# живёт в своём netns: часть net.ipv4.tcp_* там своя и пишется, часть
# принадлежит RouterOS и доступна только на чтение или не видна вовсе. Поэтому
# каждое значение пишется отдельно, перечитывается и получает статус для
# панели. Исходные значения ядра запоминаются при первом запуске: system
# означает вернуть их, а не оставить выставленное ранее.
sysctl_path() { printf '/proc/sys/%s' "$(printf '%s' "$1" | tr . /)"; }

if [ -n "$NETWORK_SYSCTL_ORIGINAL_FILE" ] && [ ! -f "$NETWORK_SYSCTL_ORIGINAL_FILE" ]; then
  for name in net.ipv4.tcp_notsent_lowat net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_mtu_probing \
              net.ipv4.tcp_fin_timeout net.ipv4.tcp_congestion_control net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
    path=$(sysctl_path "$name")
    [ -r "$path" ] || continue
    printf '%s=%s\n' "$name" "$(tr -s '\t ' '  ' < "$path")"
  done > "$NETWORK_SYSCTL_ORIGINAL_FILE.tmp" && mv "$NETWORK_SYSCTL_ORIGINAL_FILE.tmp" "$NETWORK_SYSCTL_ORIGINAL_FILE"
fi

sysctl_original() {
  [ -n "$NETWORK_SYSCTL_ORIGINAL_FILE" ] || return 1
  awk -v key="$1" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); found=1; exit } END { exit !found }' \
    "$NETWORK_SYSCTL_ORIGINAL_FILE" 2>/dev/null
}

SYSCTL_REPORT=
# Статусы: applied, system, readonly, missing, unavailable.
sysctl_apply() {
  label="$1" name="$2" wanted="$3"
  path=$(sysctl_path "$name")
  if [ ! -e "$path" ]; then
    SYSCTL_REPORT="${SYSCTL_REPORT}SYSCTL_$label=missing
"
    return 0
  fi
  result=applied
  if [ "$wanted" = system ]; then
    wanted=$(sysctl_original "$name") || wanted=
    result=system
    [ -n "$wanted" ] || { SYSCTL_REPORT="${SYSCTL_REPORT}SYSCTL_$label=system
"; return 0; }
  fi
  printf '%s\n' "$wanted" > "$path" 2>/dev/null || true
  current=$(tr -s '\t ' '  ' < "$path" 2>/dev/null)
  [ "$current" = "$wanted" ] || result=readonly
  SYSCTL_REPORT="${SYSCTL_REPORT}SYSCTL_$label=$result
"
}

sysctl_apply TCP_NOTSENT_LOWAT net.ipv4.tcp_notsent_lowat "$NETWORK_TCP_NOTSENT_LOWAT"
sysctl_apply TCP_SLOW_START_AFTER_IDLE net.ipv4.tcp_slow_start_after_idle "$NETWORK_TCP_SLOW_START_AFTER_IDLE"
sysctl_apply TCP_MTU_PROBING net.ipv4.tcp_mtu_probing "$NETWORK_TCP_MTU_PROBING"
sysctl_apply TCP_FIN_TIMEOUT net.ipv4.tcp_fin_timeout "$NETWORK_TCP_FIN_TIMEOUT"

cc_available=$(tr -cd 'a-z0-9_ ' < /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)
if [ "$NETWORK_TCP_CONGESTION" != system ] && ! printf ' %s ' "$cc_available" | grep -q " $NETWORK_TCP_CONGESTION "; then
  SYSCTL_REPORT="${SYSCTL_REPORT}SYSCTL_TCP_CONGESTION=unavailable
"
else
  sysctl_apply TCP_CONGESTION net.ipv4.tcp_congestion_control "$NETWORK_TCP_CONGESTION"
fi

# Потолок буфера сокета — третье поле tcp_rmem/tcp_wmem. Первые два берутся из
# исходных значений ядра, чтобы не трогать минимум и значение по умолчанию.
for buffer_sysctl in tcp_rmem tcp_wmem; do
  label=TCP_BUFFER_$(printf '%s' "$buffer_sysctl" | tr a-z A-Z | sed 's/^TCP_//')
  if [ "$NETWORK_TCP_BUFFER_MAX" = system ]; then
    sysctl_apply "$label" "net.ipv4.$buffer_sysctl" system
    continue
  fi
  original=$(sysctl_original "net.ipv4.$buffer_sysctl") ||
    original=$(tr -s '\t ' '  ' < "/proc/sys/net/ipv4/$buffer_sysctl" 2>/dev/null)
  set -- $original
  if [ $# -ne 3 ]; then
    SYSCTL_REPORT="${SYSCTL_REPORT}SYSCTL_$label=missing
"
    continue
  fi
  buffer_default=$2
  [ "$buffer_default" -le "$NETWORK_TCP_BUFFER_MAX" ] || buffer_default=$NETWORK_TCP_BUFFER_MAX
  sysctl_apply "$label" "net.ipv4.$buffer_sysctl" "$1 $buffer_default $NETWORK_TCP_BUFFER_MAX"
done

# Сводка для панели: CGI читает её встроенным read, без ip и awk на каждый
# опрос статуса.
if [ -n "$NETWORK_INFO_FILE" ]; then
  iface_cidr=$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}')
  {
    printf 'NET_IFACE=%s\n' "$(printf '%s' "$iface" | tr -cd 'A-Za-z0-9@._-')"
    printf 'NET_CIDR=%s\n' "$(printf '%s' "$iface_cidr" | tr -cd '0-9./')"
    printf 'NET_TCP_CC_AVAILABLE=%s\n' "$cc_available"
    printf '%s' "$SYSCTL_REPORT"
  } > "$NETWORK_INFO_FILE.tmp" && mv "$NETWORK_INFO_FILE.tmp" "$NETWORK_INFO_FILE"
fi

printf 'interface=%s ipv6_disabled=%s qdisc=%s multicast_disabled=%s\n' \
  "$iface" "$NETWORK_DISABLE_IPV6" "$NETWORK_QDISC" "$NETWORK_DISABLE_MULTICAST"
printf '%s' "$SYSCTL_REPORT" | sed 's/^SYSCTL_/sysctl /'
