#!/bin/sh
set -eu

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  docker logs "$app" >&2 2>/dev/null || true
  exit 1
}

cleanup() {
  docker rm -f "$app" "$server" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
}

api_get() {
  docker exec "$app" wget -qO- "http://127.0.0.1/cgi-bin/api?action=$1"
}

api_post() {
  action=$1 body=$2
  docker exec "$app" wget -qO- \
    --header='Origin: http://127.0.0.1' \
    --post-data="$body" \
    "http://127.0.0.1/cgi-bin/api?action=$action"
}

post_ok() {
  response=$(api_post "$1" "$2") || fail "API action $1 failed"
  printf '%s' "$response" | docker exec -i "$app" jq -e '.ok == true' >/dev/null || fail "API action $1 returned: $response"
}

status_matches() {
  filter=$1
  api_get status 2>/dev/null | docker exec -i "$app" jq -e "$filter" >/dev/null 2>&1
}

wait_status() {
  filter=$1 message=$2
  for _ in $(seq 1 120); do
    status_matches "$filter" && return 0
    sleep 0.25
  done
  fail "$message"
}

save_profile() {
  encoded_url=$1
  post_ok save-profile "profile_id=$profile_id&name=E2E&url=$encoded_url&headers=X-Test%3A+e2e&use_profile_headers=1&use_provider_title=1&use_provider_interval=1&refresh_seconds=3600&timeout_seconds=10&insecure_tls=0"
}

image=${1:-xray-remnasub-ros:test}
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
suffix=$$-$(date +%s)
app=xrr-e2e-app-$suffix
server=xrr-e2e-server-$suffix
network=xrr-e2e-net-$suffix
volume=xrr-e2e-data-$suffix

trap cleanup EXIT INT TERM

docker network create "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker run -d \
  --name "$server" \
  --network "$network" \
  --network-alias subscription \
  -v "$script_dir/fixtures:/fixtures:ro" \
  -v "$script_dir/nginx.conf:/etc/nginx/nginx.conf:ro" \
  nginx:1.29-alpine >/dev/null
docker run -d \
  --name "$app" \
  --network "$network" \
  --privileged \
  -e BASIC_AUTH=off \
  -v "$volume:/etc/xray" \
  "$image" >/dev/null

web_ready=0
for _ in $(seq 1 80); do
  if api_get status 2>/dev/null | docker exec -i "$app" jq -e '.ok == true' >/dev/null 2>&1; then
    web_ready=1
    break
  fi
  sleep 0.25
done
[ "$web_ready" = 1 ] || fail 'Web API did not become ready'

profile_id=$(api_get status | docker exec -i "$app" jq -r '.active_profile_id')
case "$profile_id" in p-*) ;; *) fail 'Initial profile was not created' ;; esac

cross_origin=$(docker exec "$app" wget -qO- --header='Origin: http://example.invalid' --post-data="profile_id=$profile_id" 'http://127.0.0.1/cgi-bin/api?action=refresh')
printf '%s' "$cross_origin" | docker exec -i "$app" jq -e '.ok == false and (.error | contains("Cross-origin"))' >/dev/null || fail 'Cross-origin POST was not rejected'

save_profile 'http%3A%2F%2Fsubscription%2Fsubscription.json'
wait_status '.profiles[0].status == "ready" and .profiles[0].source_present and .profiles[0].config_present and (.configs | length) == 2' 'Valid subscription was not fetched and built'
status_matches '.profiles[0].title_b64 | @base64d == "E2E Subscription"' || fail 'Profile-Title metadata was not stored'
status_matches '.profiles[0].interval_b64 | @base64d == "12"' || fail 'Profile-Update-Interval metadata was not stored'
status_matches '.profiles[0].userinfo_b64 | @base64d | contains("total=4096")' || fail 'Subscription-Userinfo metadata was not stored'
status_matches '.profiles[0].announce_b64 | @base64d == "Planned maintenance"' || fail 'Announce metadata was not stored'
status_matches '.profiles[0].hwid_active_b64 | @base64d == "true"' || fail 'HWID metadata was not stored'

source_path=/etc/xray/remnasub/profiles/$profile_id.source.json
runtime_dir=$(docker exec "$app" sh -c '. /lib.sh; profile_runtime_dir "$1"' sh "$profile_id")
runtime_path=$runtime_dir/.metadata/runtime.json
source_checksum=$(docker exec "$app" sha256sum "$source_path" | awk '{print $1}')
runtime_checksum=$(docker exec "$app" sha256sum "$runtime_path" | awk '{print $1}')

save_profile 'http%3A%2F%2Fsubscription%2Fmalformed.json'
wait_status '.profiles[0].status == "error"' 'Malformed subscription did not report an error'
[ "$(docker exec "$app" sha256sum "$source_path" | awk '{print $1}')" = "$source_checksum" ] || fail 'Malformed response replaced the last-good source'
[ "$(docker exec "$app" sha256sum "$runtime_path" | awk '{print $1}')" = "$runtime_checksum" ] || fail 'Malformed response replaced the last-good runtime'

save_profile 'http%3A%2F%2Fsubscription%2Fsubscription.json'
wait_status '.profiles[0].status == "ready" and .profiles[0].error_b64 == "" and (.configs | length) == 2' 'Valid subscription did not recover after malformed input'

post_ok start ''
wait_status '.run_enabled == 1 and .running == true' 'Xray did not start through the Web API'
docker exec "$app" nft list table inet xray_remnasub >/dev/null 2>&1 || fail 'Traffic interception rules were not installed'
post_ok select-config "profile_id=$profile_id&config_index=1"
wait_status '.profiles[0].selected_config_index == 1 and (.configs | map(select(.selected)) | .[0].index) == 1 and .running == true' 'Full configuration selection was not applied'
runtime_dir=$(docker exec "$app" sh -c '. /lib.sh; profile_runtime_dir "$1"' sh "$profile_id")
docker exec "$app" jq -e '.remarks == "E2E Beta"' "$runtime_dir/10-subscription.json" >/dev/null || fail 'Selected full configuration was not published'
selected_version=$(api_get status | docker exec -i "$app" jq -r '.profiles[0].final_version')
same_selection=$(api_post select-config "profile_id=$profile_id&config_index=1") || fail 'Repeated selection request failed'
printf '%s' "$same_selection" | docker exec -i "$app" jq -e '.ok == true and .changed == false and .queued == ""' >/dev/null || fail 'Repeated selection queued a rebuild'
sleep 1
status_matches ".profiles[0].final_version == $selected_version" || fail 'Repeated selection changed the runtime version'

# Обновление подписки, которая не изменилась, не должно ни публиковать новую
# версию runtime, ни перезапускать Xray: иначе почасовой опрос рвал бы все
# клиентские соединения на ровном месте.
unchanged_version=$(api_get status | docker exec -i "$app" jq -r '.profiles[0].final_version')
unchanged_pid=$(docker exec "$app" cat /dev/shm/xray-remnasub/xray.pid)
case "$unchanged_pid" in ''|*[!0-9]*) fail 'Xray pid file was not readable' ;; esac
post_ok refresh "profile_id=$profile_id"
wait_status '.profiles[0].status == "ready"' 'Unchanged refresh did not finish'
status_matches ".profiles[0].final_version == $unchanged_version" || fail 'Unchanged subscription published a new runtime version'
status_matches '.running == true' || fail 'Unchanged subscription stopped Xray'
sleep 2
[ "$(docker exec "$app" cat /dev/shm/xray-remnasub/xray.pid)" = "$unchanged_pid" ] || fail 'Unchanged subscription restarted Xray'
docker exec "$app" grep -q 'configuration unchanged' /dev/shm/xray-remnasub/events.log || fail 'Unchanged refresh was not reported in the event log'

# Тема хранится в контейнере, а не в браузере, и переживает перезапись
# остальных настроек.
post_ok save-settings 'listener_mode=auto&redir_port=12345&tproxy_port=12346&log_level=warning&network_qdisc=fq_codel&network_disable_ipv6=1&network_disable_multicast=1&xray_probe_url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&xray_probe_timeout_seconds=5&xray_probe_http_method=HEAD&geodata_storage=memory&ui_theme=midnight&ui_accent_present=1&ui_accent=%23587ce0'
status_matches '.ui_theme == "midnight" and .ui_accent == "#587ce0"' || fail 'Interface theme was not stored'
bad_theme=$(api_post save-settings 'listener_mode=auto&redir_port=12345&tproxy_port=12346&log_level=warning&network_qdisc=fq_codel&network_disable_ipv6=1&network_disable_multicast=1&xray_probe_url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&xray_probe_timeout_seconds=5&xray_probe_http_method=HEAD&geodata_storage=memory&ui_theme=neon')
printf '%s' "$bad_theme" | docker exec -i "$app" jq -e '.ok == false' >/dev/null || fail 'Unknown theme was accepted'

# Сторож обязан поднять веб-сервер обратно.
docker exec "$app" sh -c 'kill -KILL $(pidof httpd) 2>/dev/null' || true
httpd_back=0
for _ in $(seq 1 40); do
  if api_get status >/dev/null 2>&1; then httpd_back=1; break; fi
  sleep 0.5
done
[ "$httpd_back" = 1 ] || fail 'Web server was not restarted by the watchdog'

post_ok stop ''
wait_status '.run_enabled == 0 and .running == false' 'Xray did not stop through the Web API'
rules_removed=0
for _ in $(seq 1 40); do
  if ! docker exec "$app" nft list table inet xray_remnasub >/dev/null 2>&1; then
    rules_removed=1
    break
  fi
  sleep 0.25
done
[ "$rules_removed" = 1 ] || fail 'Traffic interception rules remained after stop'

save_profile 'http%3A%2F%2Fsubscription%2Fdenied.json'
wait_status '.profiles[0].status == "ready" and .profiles[0].policy_status == "403" and .profiles[0].config_present == false and (.configs | length) == 0' 'HTTP policy denial was not converted to fail-closed state'
docker exec "$app" jq -e 'length == 0' "$source_path" >/dev/null || fail 'HTTP policy denial did not install an authoritative empty source'
status_matches '.profiles[0].restriction_b64 | @base64d | contains("HTTP 403")' || fail 'HTTP policy denial reason was not exposed'

save_profile 'http%3A%2F%2Fsubscription%2Fhwid.json'
wait_status '.profiles[0].status == "ready" and .profiles[0].policy_status == "" and (.profiles[0].hwid_max_b64 | @base64d) == "true" and .profiles[0].config_present == false and (.configs | length) == 0' 'HWID denial was not converted to fail-closed state'
docker exec "$app" jq -e 'length == 0' "$source_path" >/dev/null || fail 'HWID denial did not install an authoritative empty source'
status_matches '.profiles[0].restriction_b64 | @base64d | contains("HWID")' || fail 'HWID denial reason was not exposed'

printf 'PASS: HTTP fetch, metadata, transactional recovery, lifecycle, full-config selection, unchanged-refresh stability, stored theme, watchdog, and fail-closed policy checks\n'
