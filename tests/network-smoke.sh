#!/bin/sh
set -eu

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

iptables_command=iptables
if ! { command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; } && command -v iptables-legacy >/dev/null 2>&1; then
  iptables_command=iptables-legacy
fi

tun_pid=

cleanup() {
  /scripts/network.sh shutdown >/dev/null 2>&1 || true
  [ -n "$tun_pid" ] || return 0
  kill -TERM "$tun_pid" 2>/dev/null || true
  wait "$tun_pid" 2>/dev/null || true
  tun_pid=
}

trap cleanup EXIT INT TERM

export LISTENER_MODE=tproxy
export REDIR_PORT=12345
export TPROXY_PORT=12346

resolved_tproxy=$(/scripts/network.sh resolve)
if [ "$resolved_tproxy" = tproxy ]; then
  [ "$(LISTENER_MODE_STRICT=1 /scripts/network.sh resolve)" = tproxy ] || fail 'pinned TPROXY mode was not retained'
  [ "$(/scripts/network.sh apply)" = tproxy ] || fail 'tproxy network mode was not applied'
  rules=$(nft list table inet xray_remnasub)
  printf '%s\n' "$rules" | grep -q 'chain pre' || fail 'TPROXY prerouting chain is missing'
  printf '%s\n' "$rules" | grep -q 'tproxy ip to 127.0.0.1:12346' || fail 'single TCP/UDP TPROXY rule is missing'
  printf '%s\n' "$rules" | grep -q 'socket transparent 1' || fail 'TPROXY divert rule is missing'
  printf '%s\n' "$rules" | grep -q '12345' && fail 'pure TPROXY unexpectedly uses the REDIR port'
  ip rule show | grep -q '^100:.*lookup 100' || fail 'fwmark policy rule is missing'

  /scripts/network.sh cleanup
  nft list table inet xray_remnasub >/dev/null 2>&1 && fail 'route cleanup left the owned nftables table behind'
  ip rule show | grep -q '^100:' && fail 'route cleanup left the owned fwmark rule behind'

  export LISTENER_MODE=redir-tproxy
  [ "$(/scripts/network.sh apply)" = redir-tproxy ] || fail 'redirect plus TPROXY network mode was not applied'
  rules=$(nft list table inet xray_remnasub)
  printf '%s\n' "$rules" | grep -q 'chain nat' || fail 'TCP REDIR chain is missing'
  printf '%s\n' "$rules" | grep -q 'redirect to :12345' || fail 'TCP REDIR rule is missing'
  printf '%s\n' "$rules" | grep -q 'tproxy ip to 127.0.0.1:12346' || fail 'UDP TPROXY rule is missing'
  printf '%s\n' "$rules" | grep -q 'socket transparent 1' || fail 'UDP divert rule is missing'
  /scripts/network.sh cleanup
else
  [ "$resolved_tproxy" = redir-tun ] || fail 'TPROXY capability fallback was not resolved'
  if LISTENER_MODE_STRICT=1 /scripts/network.sh resolve >/dev/null 2>&1; then
    fail 'pinned TPROXY mode silently fell back to TUN'
  fi
fi

grep -q 'LISTENER_MODE="$runtime_listener_mode" LISTENER_MODE_STRICT=1' /entrypoint.sh || fail 'supervisor does not apply the pinned runtime listener mode'

NETWORK_RESET_IPV4_FORWARDING=1 /scripts/network-alpine.sh >/tmp/xray-remnasub-network-alpine.log
ip rule show | grep -q '^0:.*lookup local' || fail 'local policy rule was not normalized'
ip rule show | grep -q '^32766:.*lookup main' || fail 'main policy rule was not normalized'
ip rule show | grep -q '^32767:.*lookup default' || fail 'default policy rule was not normalized'
[ "$(ip rule show | grep -c 'lookup local')" = 1 ] || fail 'duplicate local policy rules remain'
[ "$(ip rule show | grep -c 'lookup main')" = 1 ] || fail 'duplicate main policy rules remain'
[ "$(ip rule show | grep -c 'lookup default')" = 1 ] || fail 'duplicate default policy rules remain'

tun_root=/tmp/xray-remnasub-network-smoke
profile_id=p-network
rm -rf "$tun_root" /dev/shm/xray-remnasub
mkdir -p "$tun_root/remnasub/profiles" "$tun_root/stub-bin"
export XRAY_DIR=$tun_root
export GEODATA_STUB_PAYLOAD=fixture-geodata
GEODATA_STUB_SHA=$(printf '%s' "$GEODATA_STUB_PAYLOAD" | sha256sum | awk '{print $1}')
export GEODATA_STUB_SHA
cat > "$tun_root/stub-bin/wget" <<'EOF'
#!/bin/sh
target=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in -O) shift; target=$1 ;; *) url=$1 ;; esac
  shift
done
case "$url" in
  *.sha256sum) name=${url%.sha256sum}; name=${name##*/}; printf '%s  %s\n' "$GEODATA_STUB_SHA" "$name" > "$target" ;;
  *) printf '%s' "$GEODATA_STUB_PAYLOAD" > "$target" ;;
esac
EOF
chmod 755 "$tun_root/stub-bin/wget"
PATH=$tun_root/stub-bin:$PATH
export PATH

. /lib.sh
cat > "$STATE" <<'EOF'
STATE_VERSION=1
ACTIVE_PROFILE_ID=p-network
RUN_ENABLED=0
LISTENER_MODE=redir-tun
REDIR_PORT=12345
TPROXY_PORT=12346
LOG_LEVEL=warning
NETWORK_DISABLE_IPV6=1
NETWORK_DISABLE_MULTICAST=1
NETWORK_QDISC=fq_codel
XRAY_SNIFFING_ENABLED=1
XRAY_SNIFFING_ROUTE_ONLY=1
GEODATA_STORAGE=memory
EOF
cat > "$(profile_path "$profile_id")" <<'EOF'
PROFILE_VERSION=1
SELECTED_INDEX=1
SELECTED_FINGERPRINT=
EOF

cp /tests/fixtures/subscription.json "$(profile_source "$profile_id")"
build_xray_config "$profile_id" || fail "redir-tun config was rejected: ${BUILD_ERROR:-unknown error}"
runtime_dir=$(profile_runtime_dir "$profile_id")
runtime=$runtime_dir/.metadata/runtime.json
jq -e '[.inbounds[].tag] == ["xray-remnasub-mixed","xray-remnasub-tcp","xray-remnasub-tun"]' "$runtime" >/dev/null || fail 'managed REDIR plus TUN inbound tags are not stable'
asset_dir=$(jq -r '.asset_dir' "$runtime_dir/.metadata/geodata.json")
XRAY_LOCATION_ASSET="$asset_dir" xray run -confdir "$runtime_dir" >/tmp/xray-remnasub-tun.log 2>&1 &
tun_pid=$!
tun_ready=0
for _ in $(seq 1 100); do
  kill -0 "$tun_pid" 2>/dev/null || { cat /tmp/xray-remnasub-tun.log >&2; fail 'Xray exited before creating TUN'; }
  if ip link show Xray >/dev/null 2>&1; then tun_ready=1; break; fi
  sleep 0.1
done
[ "$tun_ready" = 1 ] || fail 'Xray TUN interface did not become ready'

export LISTENER_MODE=redir-tun
[ "$(/scripts/network.sh apply)" = redir-tun ] || fail 'redirect plus TUN network mode was not applied'
if nft list table inet xray_remnasub >/dev/null 2>&1; then
  nat_rules=$(nft list table inet xray_remnasub)
  forward_rules=$(nft list table inet xray_remnasub_forward)
  printf '%s\n' "$nat_rules" | grep -q 'redirect to :12345' || fail 'nft REDIR rule is missing'
  printf '%s\n' "$forward_rules" | grep -q 'oifname "Xray"' || fail 'nft TUN forward rule is missing'
else
  "$iptables_command" -t nat -S XRAY_REMNA_PREROUTING | grep -q -- '--to-ports 12345' || fail 'iptables REDIR rule is missing'
  "$iptables_command" -S XRAY_REMNA_FORWARD | grep -q -- '-o Xray -p udp -j ACCEPT' || fail 'iptables TUN forward rule is missing'
fi
for pref in 10000 10001 10002 10003 10004 10005; do
  ip rule show | grep -q "^$pref:" || fail "TUN policy rule $pref is missing"
done
ip route show table 110 | grep -q '^default via 100.64.0.1 dev Xray' || fail 'TUN route table 110 is missing'
NETWORK_RESET_IPV4_FORWARDING=0 /scripts/network-alpine.sh >/tmp/xray-remnasub-network-alpine-live.log
for pref in 10000 10001 10002 10003 10004 10005; do
  ip rule show | grep -q "^$pref:" || fail "Alpine settings removed active TUN policy rule $pref"
done

/scripts/network.sh cleanup
for pref in 10000 10001 10002 10003 10004 10005; do
  ip rule show | grep -q "^$pref:" && fail "cleanup left policy rule $pref behind"
done
kill -TERM "$tun_pid"
wait "$tun_pid" 2>/dev/null || true
tun_pid=

/scripts/network.sh probe-block
/scripts/network.sh probe-block
if nft list table inet xray_remnasub_gateway >/dev/null 2>&1; then
  probe_rules=$(nft list table inet xray_remnasub_gateway)
  [ "$(printf '%s\n' "$probe_rules" | grep -c 'icmp type echo-request drop')" = 1 ] || fail 'nft probe block is not idempotent'
else
  [ "$("$iptables_command" -S XRAY_REMNA_GATEWAY | grep -c -- '--icmp-type 8 -j DROP')" = 1 ] || fail 'iptables probe block is not idempotent'
fi
/scripts/network.sh probe-allow

printf 'PASS: Alpine rules, TPROXY, REDIR+TPROXY, REDIR+TUN, cleanup, and probe firewall\n'
