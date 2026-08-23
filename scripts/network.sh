#!/bin/sh
set -eu

action=${1:-apply}
mode=${LISTENER_MODE:-auto}
strict=${LISTENER_MODE_STRICT:-0}
redir=${REDIR_PORT:-12345}
tproxy=${TPROXY_PORT:-12346}
mark=1
tproxy_table=100
tun_table=110
tun=Xray
tun_gateway=100.64.0.1

resolve_interface() {
  requested=${ROUTE_IFACE:-${NETWORK_INTERFACE:-auto}}
  if [ "$requested" != auto ] && ip link show dev "$requested" >/dev/null 2>&1; then
    printf '%s\n' "$requested"
    return 0
  fi
  resolved=$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
  [ -n "$resolved" ] && { printf '%s\n' "$resolved"; return 0; }
  ip -o link show up | awk -F': ' '/link\/ether/ {
    gsub(/@.*$/, "", $2)
    if ($2 != "lo" && $2 != "Xray" && $2 != "Meta" && $2 !~ /^hs5t/) {print $2; exit}
  }'
}

nft_available() {
  command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1
}

nft_tproxy_available() {
  nft_available || return 1
  printf '%s\n' \
    'add table inet xray_remnasub_probe' \
    'add chain inet xray_remnasub_probe prerouting { type filter hook prerouting priority filter; policy accept; }' \
    'add rule inet xray_remnasub_probe prerouting meta mark 4294967295 meta l4proto udp tproxy ip to 127.0.0.1:1 accept' \
    'add chain inet xray_remnasub_probe divert { type filter hook prerouting priority mangle -1; policy accept; }' \
    'add rule inet xray_remnasub_probe divert meta l4proto udp socket transparent 1 meta mark set 4294967295 accept' \
    'delete table inet xray_remnasub_probe' | nft --check -f - >/dev/null 2>&1
}

resolve_mode() {
  case "$mode" in
    auto) nft_tproxy_available && printf 'redir-tproxy\n' || printf 'redir-tun\n' ;;
    tproxy|redir-tproxy)
      if nft_tproxy_available; then
        printf '%s\n' "$mode"
      elif [ "$strict" = 1 ]; then
        return 1
      else
        printf 'redir-tun\n'
      fi
      ;;
    redir-tun) printf 'redir-tun\n' ;;
    *) return 1 ;;
  esac
}

IPTABLES_COMMAND=iptables
if ! nft_available && command -v iptables-legacy >/dev/null 2>&1; then
  IPTABLES_COMMAND=iptables-legacy
fi

iface=$(resolve_interface || true)
iface_cidr=
[ -z "$iface" ] || iface_cidr=$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4; exit}')
[ -n "$iface_cidr" ] || iface_cidr=127.0.0.1/32

route_cleanup() {
  nft delete table inet xray_remnasub 2>/dev/null || true
  nft delete table inet xray_remnasub_forward 2>/dev/null || true
  nft delete table ip xray_remnasub_output 2>/dev/null || true
  while "$IPTABLES_COMMAND" -t nat -D PREROUTING -j XRAY_REMNA_PREROUTING 2>/dev/null; do :; done
  "$IPTABLES_COMMAND" -t nat -F XRAY_REMNA_PREROUTING 2>/dev/null || true
  "$IPTABLES_COMMAND" -t nat -X XRAY_REMNA_PREROUTING 2>/dev/null || true
  while "$IPTABLES_COMMAND" -t mangle -D PREROUTING -j XRAY_REMNA_MANGLE_PRE 2>/dev/null; do :; done
  "$IPTABLES_COMMAND" -t mangle -F XRAY_REMNA_MANGLE_PRE 2>/dev/null || true
  "$IPTABLES_COMMAND" -t mangle -X XRAY_REMNA_MANGLE_PRE 2>/dev/null || true
  while "$IPTABLES_COMMAND" -D FORWARD -j XRAY_REMNA_FORWARD 2>/dev/null; do :; done
  "$IPTABLES_COMMAND" -F XRAY_REMNA_FORWARD 2>/dev/null || true
  "$IPTABLES_COMMAND" -X XRAY_REMNA_FORWARD 2>/dev/null || true
  while ip rule del fwmark "$mark" table "$tproxy_table" 2>/dev/null; do :; done
  for pref in 10000 10001 10002 10003 10004 10005; do
    while ip rule del pref "$pref" 2>/dev/null; do :; done
  done
  ip route flush table "$tproxy_table" 2>/dev/null || true
  ip route flush table "$tun_table" 2>/dev/null || true
  sysctl -w net.ipv4.ip_forward=0 >/dev/null 2>&1 || true
}

probe_cleanup() {
  nft delete table inet xray_remnasub_gateway 2>/dev/null || true
  while "$IPTABLES_COMMAND" -D INPUT -j XRAY_REMNA_GATEWAY 2>/dev/null; do :; done
  "$IPTABLES_COMMAND" -F XRAY_REMNA_GATEWAY 2>/dev/null || true
  "$IPTABLES_COMMAND" -X XRAY_REMNA_GATEWAY 2>/dev/null || true
}

probe_block() {
  [ -n "$iface" ] || { echo 'network interface not found' >&2; return 1; }
  if nft_available; then
    probe_cleanup
    if ! nft add table inet xray_remnasub_gateway ||
       ! nft add chain inet xray_remnasub_gateway input_filter '{ type filter hook input priority filter; policy accept; }' ||
       ! nft add rule inet xray_remnasub_gateway input_filter iifname "$iface" ip protocol icmp icmp type echo-request drop; then
      probe_cleanup
      echo "could not install the nftables ICMP probe rule on $iface" >&2
      return 1
    fi
  elif command -v "$IPTABLES_COMMAND" >/dev/null 2>&1; then
    probe_cleanup
    if ! "$IPTABLES_COMMAND" -N XRAY_REMNA_GATEWAY ||
       ! "$IPTABLES_COMMAND" -I INPUT 1 -j XRAY_REMNA_GATEWAY ||
       ! "$IPTABLES_COMMAND" -A XRAY_REMNA_GATEWAY -i "$iface" -p icmp --icmp-type echo-request -j DROP; then
      probe_cleanup
      echo "could not install the iptables ICMP probe rule on $iface" >&2
      return 1
    fi
  else
    echo 'firewall backend not found' >&2
    return 1
  fi
}

wait_for_tun() {
  i=0
  while [ "$i" -lt 50 ]; do
    ip link show "$tun" >/dev/null 2>&1 && return 0
    i=$((i + 1))
    sleep 0.2
  done
  echo 'Xray TUN was not created' >&2
  return 1
}

apply_tproxy() {
  nft add table inet xray_remnasub
  nft add chain inet xray_remnasub pre '{ type filter hook prerouting priority filter; policy accept; }'
  nft add rule inet xray_remnasub pre meta iifname != "$iface" return
  nft add rule inet xray_remnasub pre tcp option mptcp exists drop
  nft add rule inet xray_remnasub pre ip daddr "{ $iface_cidr, 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 }" return
  nft add rule inet xray_remnasub pre meta l4proto "{ tcp, udp }" meta mark set "$mark" tproxy ip to 127.0.0.1:"$tproxy" accept
  nft add chain inet xray_remnasub divert '{ type filter hook prerouting priority mangle -1; policy accept; }'
  nft add rule inet xray_remnasub divert meta l4proto "{ tcp, udp }" socket transparent 1 meta mark set "$mark" accept
  ip rule add fwmark "$mark" table "$tproxy_table" pref 100
  ip route replace local 0.0.0.0/0 dev lo table "$tproxy_table"
}

apply_redir_tproxy() {
  nft add table inet xray_remnasub
  nft add chain inet xray_remnasub nat '{ type nat hook prerouting priority dstnat + 1; policy accept; }'
  nft add rule inet xray_remnasub nat meta iifname != "$iface" return
  nft add rule inet xray_remnasub nat tcp option mptcp exists drop
  nft add rule inet xray_remnasub nat ip daddr "{ $iface_cidr, 127.0.0.0/8, $tun_gateway/32, 224.0.0.0/4, 255.255.255.255 }" return
  nft add rule inet xray_remnasub nat meta l4proto tcp redirect to "$redir"
  nft add chain inet xray_remnasub pre '{ type filter hook prerouting priority filter; policy accept; }'
  nft add rule inet xray_remnasub pre meta iifname != "$iface" return
  nft add rule inet xray_remnasub pre ip daddr "{ $iface_cidr, 127.0.0.0/8, 224.0.0.0/4, 255.255.255.255 }" return
  nft add rule inet xray_remnasub pre meta l4proto udp meta mark set "$mark" tproxy ip to 127.0.0.1:"$tproxy" accept
  nft add chain inet xray_remnasub divert '{ type filter hook prerouting priority mangle -1; policy accept; }'
  nft add rule inet xray_remnasub divert meta l4proto udp socket transparent 1 meta mark set "$mark" accept
  ip rule add fwmark "$mark" table "$tproxy_table" pref 100
  ip route replace local 0.0.0.0/0 dev lo table "$tproxy_table"
}

apply_tun_policy() {
  ip rule add iif "$iface" ipproto tcp lookup main priority 10000
  ip rule add to "$iface_cidr" lookup main priority 10001
  ip rule add to 127.0.0.0/8 lookup main priority 10002
  ip rule add to 224.0.0.0/4 lookup main priority 10003
  ip rule add to 255.255.255.255 lookup main priority 10004
  ip rule add iif "$iface" ipproto udp lookup "$tun_table" priority 10005
  ip route replace default via "$tun_gateway" dev "$tun" table "$tun_table"
}

apply_redir_tun_nft() {
  nft add table inet xray_remnasub
  nft add chain inet xray_remnasub nat '{ type nat hook prerouting priority dstnat + 1; policy accept; }'
  nft add rule inet xray_remnasub nat meta iifname != "$iface" return
  nft add rule inet xray_remnasub nat tcp option mptcp exists drop
  nft add rule inet xray_remnasub nat ip daddr "{ $iface_cidr, 127.0.0.0/8, $tun_gateway/32, 224.0.0.0/4, 255.255.255.255 }" return
  nft add rule inet xray_remnasub nat meta l4proto tcp redirect to "$redir"
  nft add table ip xray_remnasub_output
  nft add chain ip xray_remnasub_output output '{ type nat hook output priority dstnat + 1; policy accept; }'
  nft add rule ip xray_remnasub_output output meta l4proto tcp oifname "$tun" redirect to "$redir"
  apply_tun_policy
  nft add table inet xray_remnasub_forward
  nft add chain inet xray_remnasub_forward forward '{ type filter hook forward priority filter; policy drop; }'
  nft add rule inet xray_remnasub_forward forward ct state "{ established, related, untracked }" accept
  nft add rule inet xray_remnasub_forward forward ct state invalid drop
  nft add rule inet xray_remnasub_forward forward iifname "$iface" oifname "$tun" meta l4proto udp accept
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
}

apply_redir_tun_iptables() {
  command -v "$IPTABLES_COMMAND" >/dev/null 2>&1 || { echo 'firewall backend not found' >&2; return 1; }
  "$IPTABLES_COMMAND" -t nat -N XRAY_REMNA_PREROUTING
  "$IPTABLES_COMMAND" -t nat -I PREROUTING 1 -j XRAY_REMNA_PREROUTING
  "$IPTABLES_COMMAND" -t nat -A XRAY_REMNA_PREROUTING ! -i "$iface" -j RETURN
  # Аналог nft-правила `tcp option mptcp exists drop`: MPTCP-соединение
  # перехватить нельзя, поэтому SYN с опцией 30 роняем, и клиент откатывается
  # на обычный TCP. В nft дроп стоит в nat-цепочке, но iptables запрещает DROP
  # в таблице nat ("not intended for filtering") — поэтому здесь отдельная
  # цепочка в mangle, которая к тому же отрабатывает раньше nat. Матч даёт
  # модуль xt_tcpudp; если ядро роутера собрано без него, теряем только это
  # усиление, а не весь перехват, поэтому шаг некритичный.
  if ! { "$IPTABLES_COMMAND" -t mangle -N XRAY_REMNA_MANGLE_PRE &&
         "$IPTABLES_COMMAND" -t mangle -I PREROUTING 1 -j XRAY_REMNA_MANGLE_PRE &&
         "$IPTABLES_COMMAND" -t mangle -A XRAY_REMNA_MANGLE_PRE \
           -i "$iface" -p tcp -m tcp --tcp-option 30 -j DROP; }; then
    echo 'could not install the MPTCP drop rule; MPTCP clients may bypass interception' >&2
  fi
  "$IPTABLES_COMMAND" -t nat -A XRAY_REMNA_PREROUTING -m addrtype --dst-type LOCAL -j RETURN
  "$IPTABLES_COMMAND" -t nat -A XRAY_REMNA_PREROUTING -m addrtype ! --dst-type UNICAST -j RETURN
  "$IPTABLES_COMMAND" -t nat -A XRAY_REMNA_PREROUTING -d "$iface_cidr" -j RETURN
  "$IPTABLES_COMMAND" -t nat -A XRAY_REMNA_PREROUTING -d "$tun_gateway" -j RETURN
  "$IPTABLES_COMMAND" -t nat -A XRAY_REMNA_PREROUTING -p tcp -j REDIRECT --to-ports "$redir"
  apply_tun_policy
  "$IPTABLES_COMMAND" -N XRAY_REMNA_FORWARD
  "$IPTABLES_COMMAND" -I FORWARD 1 -j XRAY_REMNA_FORWARD
  "$IPTABLES_COMMAND" -A XRAY_REMNA_FORWARD -m conntrack --ctstate ESTABLISHED,RELATED,UNTRACKED -j ACCEPT
  "$IPTABLES_COMMAND" -A XRAY_REMNA_FORWARD -m conntrack --ctstate INVALID -j DROP
  "$IPTABLES_COMMAND" -A XRAY_REMNA_FORWARD -i "$iface" -o "$tun" -p udp -j ACCEPT
  "$IPTABLES_COMMAND" -A XRAY_REMNA_FORWARD -j DROP
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
}

case "$action" in
  resolve) resolve_mode; exit $? ;;
  cleanup) route_cleanup; exit 0 ;;
  probe-block) probe_block; exit $? ;;
  probe-allow) probe_cleanup; exit 0 ;;
  shutdown) route_cleanup; probe_cleanup; exit 0 ;;
  apply) ;;
  *) echo "unsupported network action: $action" >&2; exit 1 ;;
esac

[ -n "$iface" ] || { echo 'network interface not found' >&2; exit 1; }
route_cleanup
mode=$(resolve_mode) || { echo "unsupported listener mode: $mode" >&2; exit 1; }

case "$mode" in
  tproxy) apply_tproxy ;;
  redir-tproxy) apply_redir_tproxy ;;
  redir-tun)
    wait_for_tun
    if nft_available; then
      apply_redir_tun_nft
    else
      apply_redir_tun_iptables
    fi
    ;;
esac

printf '%s\n' "$mode"
