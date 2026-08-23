#!/bin/sh
set -eu

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_jq() {
  expression=$1
  file=$2
  message=$3
  jq -e "$expression" "$file" >/dev/null || fail "$message"
}

fixture_dir=${FIXTURE_DIR:-/tests/fixtures}
test_root=/tmp/xray-remnasub-smoke
profile_id=p-smoke
core_pid=
lease_owner_pid=
lease_asset_dir=

grep -Fq '[ "$startup_attempt" -lt 300 ]' /entrypoint.sh || fail 'Xray startup readiness window is shorter than 30 seconds'

stop_core() {
  if [ -n "$core_pid" ]; then
    kill -TERM "$core_pid" 2>/dev/null || true
    wait "$core_pid" 2>/dev/null || true
    core_pid=
  fi
  if [ -n "$lease_owner_pid" ]; then
    [ -z "$lease_asset_dir" ] || /scripts/geodata.sh lease-release "$lease_asset_dir" "$lease_owner_pid" >/dev/null 2>&1 || true
    kill "$lease_owner_pid" 2>/dev/null || true
    wait "$lease_owner_pid" 2>/dev/null || true
    lease_owner_pid=
  fi
}

trap stop_core EXIT
trap 'stop_core; exit 130' INT TERM

rm -rf "$test_root" /dev/shm/xray-remnasub
mkdir -p "$test_root/remnasub/profiles" "$test_root/stub-bin"
export XRAY_DIR=$test_root
export GEODATA_STUB_PAYLOAD=fixture-geodata
export GEODATA_STUB_LOG=$test_root/wget.log
GEODATA_STUB_SHA=$(printf '%s' "$GEODATA_STUB_PAYLOAD" | sha256sum | awk '{print $1}')
export GEODATA_STUB_SHA

cat > "$test_root/stub-bin/wget" <<'EOF'
#!/bin/sh
target=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -O) shift; target=$1 ;;
    *) url=$1 ;;
  esac
  shift
done
[ -n "$target" ] && [ -n "$url" ] || exit 1
[ -z "${GEODATA_STUB_LOG:-}" ] || printf '%s\n' "$url" >> "$GEODATA_STUB_LOG"
case "$url" in
  *.sha256sum)
    name=${url%.sha256sum}; name=${name##*/}
    printf '%s  %s\n' "$GEODATA_STUB_SHA" "$name" > "$target"
    ;;
  *) printf '%s' "$GEODATA_STUB_PAYLOAD" > "$target" ;;
esac
EOF
chmod 755 "$test_root/stub-bin/wget"
PATH=$test_root/stub-bin:$PATH
export PATH

. /lib.sh

cat > "$STATE" <<'EOF'
STATE_VERSION=1
ACTIVE_PROFILE_ID=p-smoke
RUN_ENABLED=0
LISTENER_MODE=tproxy
REDIR_PORT=12345
TPROXY_PORT=12346
LOG_LEVEL=warning
NETWORK_DISABLE_IPV6=1
NETWORK_DISABLE_MULTICAST=1
NETWORK_QDISC=fq_codel
XRAY_SNIFFING_ENABLED=1
XRAY_SNIFFING_ROUTE_ONLY=1
XRAY_PROBE_URL_B64=aHR0cHM6Ly93d3cuZ3N0YXRpYy5jb20vZ2VuZXJhdGVfMjA0
XRAY_PROBE_TIMEOUT_SECONDS=5
XRAY_PROBE_HTTP_METHOD=HEAD
GEODATA_STORAGE=memory
EOF

cat > "$(profile_path "$profile_id")" <<'EOF'
PROFILE_VERSION=1
NAME_B64=
URL_B64=
HEADERS_B64=
USE_PROFILE_HEADERS=1
SELECTED_INDEX=1
SELECTED_FINGERPRINT=
REFRESH_SECONDS=3600
TIMEOUT_SECONDS=30
INSECURE_TLS=0
USE_PROVIDER_TITLE=1
USE_PROVIDER_INTERVAL=1
EOF

cp "$fixture_dir/subscription.json" "$(profile_source "$profile_id")"
source_checksum=$(sha256sum "$(profile_source "$profile_id")" | awk '{print $1}')
build_xray_config "$profile_id" || fail "valid subscription was rejected: ${BUILD_ERROR:-unknown error}"

runtime_dir=$(profile_runtime_dir "$profile_id")
runtime=$(profile_runtime "$profile_id")
configs=$(profile_configs "$profile_id")
selected=$runtime_dir/10-subscription.json
geodata=$runtime_dir/.metadata/geodata.json
listener=$runtime_dir/.metadata/listener.json
[ -s "$runtime" ] && [ -s "$configs" ] && [ -s "$geodata" ] && [ -s "$listener" ] || fail 'runtime metadata was not created'
[ "$(sha256sum "$(profile_source "$profile_id")" | awk '{print $1}')" = "$source_checksum" ] || fail 'source subscription was modified'
assert_jq 'length == 4 and (map(select(.selected)) | .[0].index) == 1' "$configs" 'full configuration index is incorrect'
assert_jq '.meta.serverDescription == "Beta" and [.outbounds[].tag] == ["source-block","source-beta"]' "$selected" 'selected full configuration was rewritten'
assert_jq '[.outbounds[0].tag,.outbounds[1].tag] == ["source-block","source-beta"]' "$runtime" 'container outbound changed provider ordering'
jq -e -s '.[0].routing == .[1].routing' "$selected" "$runtime" >/dev/null || fail 'container rewrote source inboundTag routing rules'
assert_jq '.geodata.cron == "0 4 * * *" and (.geodata.assets | length) == 2' "$runtime" 'default geodata was not applied'
assert_jq '(.outbounds[-1].protocol == "freedom") and (.geodata.outbound == .outbounds[-1].tag)' "$runtime" 'geodata helper outbound was not appended safely'
assert_jq '.storage == "memory" and (.assets | length) == 2' "$geodata" 'geodata assets were not prepared'
assert_jq '.mode == "tproxy" and .redir_port == 12345 and .tproxy_port == 12346' "$listener" 'effective listener settings were not pinned to the runtime'
[ ! -e "$RUNTIME_DIR/effective-listener-mode" ] || fail 'effective listener mode leaked into global runtime state'
! grep -q 'effective-listener-mode' /lib.sh /entrypoint.sh /www/cgi-bin/api || fail 'production code still uses global listener mode state'
grep -q 'active_runtime_dir/.metadata/listener.json' /www/cgi-bin/api || fail 'API status does not read the active runtime listener mode'
assert_jq 'any(.inbounds[]; .protocol == "dokodemo-door" and .port == 12346 and .settings.network == "tcp,udp" and .streamSettings.sockopt.tproxy == "tproxy")' "$runtime" 'single TPROXY inbound is missing'
assert_jq '[.inbounds[].tag] == ["xray-remnasub-mixed","xray-remnasub-tproxy"]' "$runtime" 'managed TPROXY inbound tags are not stable'

asset_dir=$(jq -r '.asset_dir' "$geodata")

# Обновление geodata — работа самого Xray: он делает это по своему cron через
# собственный outbound и перечитывает файлы без перезапуска. Контейнер обязан
# создать только недостающее, иначе ядро не примет конфигурацию (StatAsset в
# infra/conf/geodata.go). Уже лежащий файл он трогать не должен: это и лишняя
# запись в хранилище, и гонка с ядром за один и тот же файл.
downloads_before=$(wc -l < "$GEODATA_STUB_LOG")
asset_mtime_before=$(stat -c %Y "$asset_dir/geoip.dat")
sleep 1
/scripts/geodata.sh prepare "$selected" "$test_root/reprepare-overlay.json" "$test_root/reprepare-meta.json" memory \
  || fail 'repeated geodata prepare failed'
[ "$(wc -l < "$GEODATA_STUB_LOG")" = "$downloads_before" ] || fail 'existing geodata asset was downloaded again'
[ "$(stat -c %Y "$asset_dir/geoip.dat")" = "$asset_mtime_before" ] || fail 'existing geodata asset was rewritten'

# Недостающий файл, наоборот, обязан быть восстановлен, иначе Xray не стартует.
rm -f "$asset_dir/geoip.dat"
/scripts/geodata.sh prepare "$selected" "$test_root/rebootstrap-overlay.json" "$test_root/rebootstrap-meta.json" memory \
  || fail 'missing geodata asset was not bootstrapped'
[ -s "$asset_dir/geoip.dat" ] || fail 'missing geodata asset was not restored'
[ "$(wc -l < "$GEODATA_STUB_LOG")" != "$downloads_before" ] || fail 'missing geodata asset did not trigger a download'

XRAY_LOCATION_ASSET="$asset_dir" xray run -test -confdir "$runtime_dir" >/tmp/xray-remnasub-validation.log 2>&1 || {
  cat /tmp/xray-remnasub-validation.log >&2
  fail 'selected full configuration failed Xray validation'
}

XRAY_LOCATION_ASSET="$asset_dir" xray run -confdir "$runtime_dir" >/tmp/xray-remnasub-core.log 2>&1 &
core_pid=$!
ready=0
for _ in $(seq 1 100); do
  kill -0 "$core_pid" 2>/dev/null || break
  if nc -z -w 1 127.0.0.1 1080 >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] || { cat /tmp/xray-remnasub-core.log >&2; fail 'Xray did not start from the published confdir'; }
stop_core

conflict_runtime=$(profile_runtime_dir "$profile_id")
conflict_index=$(state_get "$(profile_path "$profile_id")" SELECTED_INDEX)
conflict_fingerprint=$(state_get "$(profile_path "$profile_id")" SELECTED_FINGERPRINT)
cp "$fixture_dir/subscription-inbound-conflicts.json" "$(profile_source "$profile_id")"
for conflict_case in \
  'tproxy|0|container mixed listener TCP/1080' \
  'tproxy|1|container TPROXY listener UDP/12346' \
  'redir-tun|2|container TUN interface Xray' \
  'tproxy|3|container web UI listener TCP/80' \
  'tproxy|4|Source inbound tag xray-remnasub-mixed is reserved for container-managed listeners'; do
  conflict_mode=${conflict_case%%|*}
  conflict_rest=${conflict_case#*|}
  conflict_selected=${conflict_rest%%|*}
  conflict_expected=${conflict_rest#*|}
  set_file_value "$STATE" LISTENER_MODE "$conflict_mode"
  set_profile_selection "$(profile_path "$profile_id")" "$conflict_selected" ''
  if build_xray_config "$profile_id"; then
    fail "source inbound conflict was accepted: $conflict_expected"
  fi
  case "$BUILD_ERROR" in
    *"$conflict_expected"*) ;;
    *) fail "source inbound conflict returned an unclear error: ${BUILD_ERROR:-empty}" ;;
  esac
  [ "$(profile_runtime_dir "$profile_id")" = "$conflict_runtime" ] || fail 'source inbound conflict replaced the last-good runtime'
done
set_file_value "$STATE" LISTENER_MODE tproxy
set_profile_selection "$(profile_path "$profile_id")" "$conflict_index" "$conflict_fingerprint"

rollback_source=$test_root/geodata-rollback.json
rollback_log=$test_root/geodata-rollback.log
rollback_overlay=$test_root/geodata-rollback-overlay.json
rollback_metadata=$test_root/geodata-rollback-metadata.json
GEODATA_STUB_PAYLOAD=fixture-custom-geodata
cat > "$rollback_source" <<'EOF'
{
  "geodata": {
    "cron": "* * * * *",
    "assets": [
      {"url": "https://example.invalid/bad.dat", "file": "bad.dat"}
    ],
    "outbound": "direct"
  },
  "outbounds": [
    {"tag": "direct", "protocol": "freedom", "settings": {}}
  ]
}
EOF
/scripts/geodata.sh prepare "$rollback_source" "$rollback_overlay" "$rollback_metadata" memory > "$rollback_log" 2>&1 || {
  cat "$rollback_log" >&2
  fail 'could not prepare baseline geodata rollback fixture'
}
rollback_asset=$(jq -r '.asset_dir + "/bad.dat"' "$rollback_metadata")
[ "$(cat "$rollback_asset")" = fixture-custom-geodata ] || fail 'baseline geodata asset was not installed'
rollback_asset_dir=$(jq -r '.asset_dir' "$rollback_metadata")
lease_asset_dir=$rollback_asset_dir
/scripts/geodata.sh lease-acquire "$rollback_asset_dir" "$$" || fail 'could not acquire the live geodata lease'
sleep 300 &
lease_owner_pid=$!
/scripts/geodata.sh lease-acquire "$rollback_asset_dir" "$lease_owner_pid" || fail 'could not acquire a second geodata lease'
/scripts/geodata.sh lease-release "$rollback_asset_dir" "$$" || fail 'could not release the first geodata lease'
GEODATA_STUB_PAYLOAD=leased-custom-geodata
: > "$GEODATA_STUB_LOG"
rm -f "$rollback_asset"
prestart_result=0
if /scripts/geodata.sh prepare-start "$rollback_source" "$rollback_overlay" "$rollback_metadata" memory > "$rollback_log" 2>&1; then
  fail 'geodata pre-start did not wait for a live asset lease'
else
  prestart_result=$?
fi
[ "$prestart_result" -eq 75 ] || { cat "$rollback_log" >&2; fail 'geodata pre-start returned the wrong busy status'; }
[ ! -s "$GEODATA_STUB_LOG" ] || fail 'geodata pre-start downloaded while the asset set was in use'
printf '%s' fixture-custom-geodata > "$rollback_asset"
/scripts/geodata.sh prepare "$rollback_source" "$rollback_overlay" "$rollback_metadata" memory > "$rollback_log" 2>&1 || {
  /scripts/geodata.sh lease-release "$rollback_asset_dir" "$lease_owner_pid" >/dev/null 2>&1 || true
  kill "$lease_owner_pid" 2>/dev/null || true
  wait "$lease_owner_pid" 2>/dev/null || true
  lease_owner_pid=
  lease_asset_dir=
  cat "$rollback_log" >&2
  fail 'live geodata assets could not be reused'
}
[ ! -s "$GEODATA_STUB_LOG" ] || fail 'container downloaded geodata that was already in place'
[ "$(cat "$rollback_asset")" = fixture-custom-geodata ] || fail 'live geodata asset was changed by the container'
/scripts/geodata.sh lease-release "$rollback_asset_dir" "$lease_owner_pid" || fail 'could not release the remaining geodata lease'
kill "$lease_owner_pid" 2>/dev/null || true
wait "$lease_owner_pid" 2>/dev/null || true
lease_owner_pid=
lease_asset_dir=

busy_asset_lock=/dev/shm/xray-remnasub/geodata-locks/memory-${rollback_asset_dir##*/}.lock
mkdir "$busy_asset_lock" || fail 'could not create the geodata lock contention fixture'
printf '%s:%s\n' "$$" "$(awk '{print $22}' "/proc/$$/stat")" > "$busy_asset_lock/pid"
busy_result=0
if GEODATA_LOCK_MAX_ATTEMPTS=1 /scripts/geodata.sh prepare-start "$rollback_source" "$rollback_overlay" "$rollback_metadata" memory > "$rollback_log" 2>&1; then
  rm -f "$busy_asset_lock/pid"; rmdir "$busy_asset_lock" 2>/dev/null || true
  fail 'geodata pre-start accepted a busy asset transaction'
else
  busy_result=$?
fi
rm -f "$busy_asset_lock/pid"; rmdir "$busy_asset_lock" 2>/dev/null || true
[ "$busy_result" -eq 75 ] || { cat "$rollback_log" >&2; fail 'geodata pre-start treated lock contention as a permanent error'; }

# Откат публикации. Единственный путь, на котором контейнер вообще пишет
# ассет, — это восстановление недостающего файла, поэтому и проверять откат
# нужно на нём: если Xray отверг конфигурацию, скачанный файл не должен
# остаться в хранилище.
jq '.outbounds[0].protocol = "definitely-invalid"' "$rollback_source" > "$rollback_source.tmp"
mv "$rollback_source.tmp" "$rollback_source"
GEODATA_STUB_PAYLOAD=updated-custom-geodata
: > "$GEODATA_STUB_LOG"
rm -f "$rollback_asset"
if /scripts/geodata.sh prepare "$rollback_source" "$rollback_overlay" "$rollback_metadata" memory > "$rollback_log" 2>&1; then
  fail 'invalid Xray configuration committed a bootstrapped geodata asset'
fi
grep -q '^https://example.invalid/bad.dat$' "$GEODATA_STUB_LOG" || fail 'geodata rollback test did not download the missing asset'
grep -q 'Prepared geodata failed Xray validation' "$rollback_log" || fail 'geodata rollback test failed before Xray validation'
[ ! -e "$rollback_asset" ] || fail 'failed Xray validation left the bootstrapped geodata asset behind'
GEODATA_STUB_PAYLOAD=fixture-geodata
GEODATA_STUB_SHA=$(printf '%s' "$GEODATA_STUB_PAYLOAD" | sha256sum | awk '{print $1}')
export GEODATA_STUB_SHA

selected_fingerprint=$(state_get "$(profile_path "$profile_id")" SELECTED_FINGERPRINT)
cp "$fixture_dir/subscription-reordered.json" "$(profile_source "$profile_id")"
build_xray_config "$profile_id" || fail "reordered subscription was rejected: ${BUILD_ERROR:-unknown error}"
[ "$(state_get "$(profile_path "$profile_id")" SELECTED_INDEX)" = 3 ] || fail 'selection did not follow the full-config fingerprint'
[ "$(state_get "$(profile_path "$profile_id")" SELECTED_FINGERPRINT)" = "$selected_fingerprint" ] || fail 'selected fingerprint changed after reorder'
assert_jq '.meta.serverDescription == "Beta"' "$(profile_runtime_dir "$profile_id")/10-subscription.json" 'wrong full configuration selected after reorder'

last_runtime=$(profile_runtime_dir "$profile_id")
printf '[{"remarks":"broken","outbounds":[]}]\n' > "$(profile_source "$profile_id")"
if build_xray_config "$profile_id"; then fail 'invalid full configuration was accepted'; fi
[ "$(profile_runtime_dir "$profile_id")" = "$last_runtime" ] || fail 'failed build replaced the last-good runtime'

cp "$fixture_dir/empty-subscription.json" "$(profile_source "$profile_id")"
build_xray_config "$profile_id" || fail "empty subscription was rejected: ${BUILD_ERROR:-unknown error}"
if profile_runtime_dir "$profile_id" >/dev/null 2>&1; then fail 'empty subscription kept an active runtime'; fi

printf 'PASS: full-config selection, inbound conflict rejection, geodata bootstrap and lease, confdir runtime, reorder, rollback, and empty state\n'
