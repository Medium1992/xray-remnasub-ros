#!/bin/sh
set -u

. /lib.sh

XRAY_PID=
RESTART_REQUESTED=0
STOPPING=0
ROUTING_ACTIVE=0
PROBE_BLOCKED=0
PROBE_BLOCK_REPORTED=0
GEODATA_LEASE_DIR=
GEODATA_BLOCKED_RUNTIME=
GEODATA_PREFLIGHT_DIR=
GEODATA_PREFLIGHT_METADATA=
GEODATA_PREFLIGHT_ERROR=
LISTENER_BLOCKED_SIGNATURE=

create_profile() {
  create_id=$1
  create_file=$(profile_path "$create_id") || return 1
  cat > "$create_file" <<EOF
PROFILE_VERSION=1
NAME_B64=$(b64_encode 'Новая подписка')
URL_B64=
HEADERS_B64=
USE_PROFILE_HEADERS=1
SELECTED_INDEX=0
SELECTED_FINGERPRINT=
REFRESH_SECONDS=3600
TIMEOUT_SECONDS=30
INSECURE_TLS=0
USE_PROVIDER_TITLE=1
USE_PROVIDER_INTERVAL=1
EOF
  chmod 600 "$create_file" 2>/dev/null || true
}

initialize_storage() {
  mkdir -p "$APP_DIR" "$PROFILES_DIR"
  first=
  for file in "$PROFILES_DIR"/p-*.conf; do
    [ -f "$file" ] || continue
    first=${file##*/}; first=${first%.conf}; break
  done
  if [ -z "$first" ]; then
    first=p-$(date +%s)
    create_profile "$first"
  fi
  if [ ! -f "$STATE" ]; then
    ACTIVE_PROFILE_ID=$first RUN_ENABLED=0 GLOBAL_HEADERS_B64= DEFAULT_HEADERS=1 LISTENER_MODE=auto REDIR_PORT=12345 TPROXY_PORT=12346
    LOG_LEVEL=warning
    NETWORK_DISABLE_IPV6=1 NETWORK_DISABLE_MULTICAST=1 NETWORK_QDISC=fq_codel
    NETWORK_CT_ESTABLISHED=86400 NETWORK_CT_SYN_SENT=5 NETWORK_CT_SYN_RECV=5
    NETWORK_CT_FIN_WAIT=10 NETWORK_CT_CLOSE_WAIT=10 NETWORK_CT_LAST_ACK=10
    NETWORK_CT_TIME_WAIT=10 NETWORK_CT_CLOSE=10 NETWORK_CT_UNACKNOWLEDGED=300 NETWORK_CT_UDP_STREAM=180
    XRAY_SNIFFING_ENABLED=1 XRAY_SNIFFING_ROUTE_ONLY=1
    XRAY_PROBE_URL_B64=aHR0cHM6Ly93d3cuZ3N0YXRpYy5jb20vZ2VuZXJhdGVfMjA0 XRAY_PROBE_TIMEOUT_SECONDS=5 XRAY_PROBE_HTTP_METHOD=HEAD
    GEODATA_STORAGE=memory
    UI_THEME=auto UI_ACCENT=
    write_state
  fi
  # Хвосты от install_build_candidates_locked: если контейнер убили ровно
  # между cp и mv, они остаются в персистентном каталоге навсегда. Глоб
  # p-*.conf их не подхватывает, так что вреда нет, но и убирать их некому.
  rm -f "$PROFILES_DIR"/p-*.conf.next.* "$PROFILES_DIR"/p-*.conf.previous.* 2>/dev/null || true
  load_settings
  if ! valid_profile_id "$ACTIVE_PROFILE_ID" || [ ! -f "$(profile_path "$ACTIVE_PROFILE_ID" 2>/dev/null)" ]; then
    ACTIVE_PROFILE_ID=$first
    write_state
  fi
  for profile in "$PROFILES_DIR"/p-*.conf; do
    [ -f "$profile" ] || continue
    id=${profile##*/}; id=${id%.conf}
    [ -s "$(profile_source "$id")" ] && queue_job "$id" build || true
  done
}

# User-Agent здесь не косметика: Remnawave по нему решает, в каком формате
# отдать подписку, и клиентская строка — способ получить именно JSON-массив
# конфигураций. Сам контейнер к этому клиенту отношения не имеет.
effective_headers() {
  header_profile=$1
  load_settings
  header_global=$RUNTIME_DIR/request-global.$$.headers
  header_local=$RUNTIME_DIR/request-local.$$.headers
  b64_decode "$GLOBAL_HEADERS_B64" | awk -v defaults="$DEFAULT_HEADERS" '
    BEGIN {
      count=5
      order[1]="x-hwid"
      order[2]="x-device-os"
      order[3]="x-ver-os"
      order[4]="x-device-model"
      order[5]="user-agent"
      fallback["x-hwid"]="RouterOS-Solomon"
      fallback["x-device-os"]="RouterOS"
      fallback["x-ver-os"]="7"
      fallback["x-device-model"]="MikroTik"
      fallback["user-agent"]="Happ/4.0.1/Android/35"
    }
    {
      line=$0
      sub(/\r$/, "", line)
      separator=index(line, ":")
      if (separator < 2) next
      key=substr(line, 1, separator - 1)
      value=substr(line, separator + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      normalized=tolower(key)
      if (normalized in fallback) {supplied[normalized]=value; seen[normalized]=1}
      else if (key ~ /^[A-Za-z0-9-]+$/) custom[++custom_count]=key ": " value
    }
    END {
      # При выключенных значениях по умолчанию обязательные ключи не
      # подставляются: уходят только те, что пользователь задал явно.
      for (i=1; i<=count; i++) {
        key=order[i]
        if (seen[key] && supplied[key] != "") value=supplied[key]
        else if (defaults == 1) value=fallback[key]
        else continue
        print key ": " value
      }
      for (i=1; i<=custom_count; i++) print custom[i]
    }
  ' > "$header_global"
  if [ "$(state_get "$header_profile" USE_PROFILE_HEADERS 1)" = 1 ]; then
    b64_decode "$(state_get "$header_profile" HEADERS_B64)" > "$header_local"
  else
    : > "$header_local"
  fi
  awk '
    function trim(value) {gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); return value}
    function add(line, separator, key, value, normalized) {
      sub(/\r$/, "", line)
      separator=index(line, ":")
      if (separator < 2) return
      key=trim(substr(line, 1, separator - 1))
      value=trim(substr(line, separator + 1))
      if (key !~ /^[A-Za-z0-9-]+$/) return
      normalized=tolower(key)
      if (FILENAME == ARGV[2] && value == "" && normalized ~ /^(x-hwid|x-device-os|x-ver-os|x-device-model|user-agent)$/) return
      if (!(normalized in position)) {position[normalized]=++count; order[count]=normalized}
      names[normalized]=key
      values[normalized]=value
    }
    {add($0)}
    END {for (i=1; i<=count; i++) {normalized=order[i]; print names[normalized] ": " values[normalized]}}
  ' "$header_global" "$header_local"
  rm -f "$header_global" "$header_local"
}

response_header() {
  response_log=$1
  response_name=$2
  awk -v wanted="$response_name" '
    /^[[:space:]]*HTTP\/[0-9.]+[[:space:]]+[0-9][0-9][0-9]/ {value=""; next}
    {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      sub(/\r$/, "", line)
      split_at=index(line, ":")
      if (split_at == 0) next
      name=tolower(substr(line, 1, split_at - 1))
      if (name == tolower(wanted)) {
        value=substr(line, split_at + 1)
        sub(/^[[:space:]]+/, "", value)
      }
    }
    END {print value}
  ' "$response_log"
}

response_status() {
  awk '/^[[:space:]]*HTTP\/[0-9.]+[[:space:]]+[0-9][0-9][0-9]/ {status=$2} END {print status}' "$1"
}

response_status_line() {
  awk '/^[[:space:]]*HTTP\/[0-9.]+[[:space:]]+[0-9][0-9][0-9]/ {sub(/^[[:space:]]*/, ""); line=$0} END {print line}' "$1"
}

fetch_profile() {
  fetch_id=$1
  FETCH_CANDIDATE=
  FETCH_META_CANDIDATE=
  FETCH_HTTP_STATUS=
  FETCH_HTTP_LINE=
  FETCH_BYTES=0
  fetch_profile_file=$(profile_path "$fetch_id") || return 1
  fetch_url=$(b64_decode "$(state_get "$fetch_profile_file" URL_B64)")
  fetch_timeout=$(state_get "$fetch_profile_file" TIMEOUT_SECONDS 30)
  fetch_insecure=$(state_get "$fetch_profile_file" INSECURE_TLS 0)
  case "$fetch_url" in http://*|https://*) ;; *) FETCH_ERROR='Subscription URL is not configured'; return 1 ;; esac
  fetch_tmp=$RUNTIME_DIR/$fetch_id.download.$$.json
  fetch_log=$RUNTIME_DIR/$fetch_id.download.$$.log
  set -- -S -T "$fetch_timeout" -O "$fetch_tmp"
  while IFS= read -r header; do
    [ -n "$header" ] || continue
    header_name=${header%%:*}
    header_value=${header#*:}
    header_value=$(printf '%s' "$header_value" | sed 's/^[[:space:]]*//')
    case "$(printf '%s' "$header_name" | tr '[:upper:]' '[:lower:]')" in
      user-agent) set -- "$@" --user-agent="$header_value" ;;
      *) set -- "$@" --header="$header" ;;
    esac
  done <<EOF
$(effective_headers "$fetch_profile_file")
EOF
  [ "$fetch_insecure" = 1 ] && set -- "$@" --no-check-certificate
  fetch_policy_status=
  if ! (ulimit -f 32770; exec wget "$@" "$fetch_url") 2> "$fetch_log"; then
    fetch_policy_status=$(response_status "$fetch_log")
    FETCH_HTTP_STATUS=$fetch_policy_status
    FETCH_HTTP_LINE=$(response_status_line "$fetch_log")
    [ ! -f "$fetch_tmp" ] || FETCH_BYTES=$(wc -c < "$fetch_tmp")
    case "$fetch_policy_status" in
      401|403|404|410|451) printf '[]\n' > "$fetch_tmp" ;;
      *)
        if [ "${FETCH_BYTES:-0}" -ge 16777216 ]; then FETCH_ERROR='Subscription is larger than 16 MiB'; else FETCH_ERROR=$(tail -n 2 "$fetch_log" | tr '\n' ' ' | head -c 2048); fi
        rm -f "$fetch_tmp" "$fetch_log"
        return 1
        ;;
      esac
  fi
  [ -n "$FETCH_HTTP_STATUS" ] || FETCH_HTTP_STATUS=$(response_status "$fetch_log")
  [ -n "$FETCH_HTTP_STATUS" ] || FETCH_HTTP_STATUS=200
  [ -n "$FETCH_HTTP_LINE" ] || FETCH_HTTP_LINE=$(response_status_line "$fetch_log")
  fetch_size=$(wc -c < "$fetch_tmp")
  FETCH_BYTES=$fetch_size
  if [ "$fetch_size" -gt 16777216 ]; then
    FETCH_ERROR='Subscription is larger than 16 MiB'
    rm -f "$fetch_tmp" "$fetch_log"
    return 1
  fi
  title=$(response_header "$fetch_log" profile-title)
  interval=$(response_header "$fetch_log" profile-update-interval)
  userinfo=$(response_header "$fetch_log" subscription-userinfo)
  announce=$(response_header "$fetch_log" announce)
  support_url=$(response_header "$fetch_log" support-url)
  web_page_url=$(response_header "$fetch_log" profile-web-page-url)
  refill=$(response_header "$fetch_log" subscription-refill-date)
  hwid_active=$(response_header "$fetch_log" x-hwid-active)
  hwid_unsupported=$(response_header "$fetch_log" x-hwid-not-supported)
  hwid_max=$(response_header "$fetch_log" x-hwid-max-devices-reached)
  hwid_limit=$(response_header "$fetch_log" x-hwid-limit)
  restriction=$(jq -r '
    def sentinel:
      ((.protocol? // "") | ascii_downcase) == "vless" and
      .settings.vnext[0].address? == "0.0.0.0" and
      .settings.vnext[0].port? == 1 and
      .settings.vnext[0].users[0].id? == "00000000-0000-0000-0000-000000000000";
    [.[] as $config |
      $config.outbounds[]? |
      select(sentinel) as $outbound |
      [$config.remarks?, $config.meta.serverDescription?, $config.name?,
       $outbound.remarks?, $outbound.remark?, $outbound.name?, $outbound.ps?][] |
      select(type == "string" and length > 0)] |
    reduce .[] as $message ([]; if any(.[]; . == $message) then . else . + [$message] end) |
    if length == 0 then empty else join("\n") end
  ' "$fetch_tmp" 2>/dev/null || true)
  fetch_usable=$(jq -r '
    def service:
      ((.protocol? // "") | ascii_downcase) as $protocol |
      $protocol == "freedom" or $protocol == "blackhole" or $protocol == "dns" or $protocol == "loopback";
    def sentinel:
      ((.protocol? // "") | ascii_downcase) == "vless" and
      .settings.vnext[0].address? == "0.0.0.0" and
      .settings.vnext[0].port? == 1 and
      .settings.vnext[0].users[0].id? == "00000000-0000-0000-0000-000000000000";
    any(.[]; any(.outbounds[]?; (service | not) and (sentinel | not)))
  ' "$fetch_tmp" 2>/dev/null || printf false)
  fetch_force_empty=0
  if [ -n "$fetch_policy_status" ]; then
    restriction="Subscription access denied (HTTP $fetch_policy_status)"
    fetch_force_empty=1
  elif [ -n "$hwid_unsupported$hwid_max$hwid_limit" ]; then
    [ -n "$restriction" ] || restriction='Subscription access is restricted by HWID policy'
    fetch_force_empty=1
  elif [ -n "$restriction" ] && [ "$fetch_usable" != true ]; then
    fetch_force_empty=1
  fi
  [ "$fetch_force_empty" = 0 ] || printf '[]\n' > "$fetch_tmp"
  if ! jq -e 'type == "array" and all(.[]; type == "object" and (.outbounds | type == "array" and length > 0))' "$fetch_tmp" >/dev/null 2>&1; then
    FETCH_ERROR='Response is not a valid array of Xray configurations'
    rm -f "$fetch_tmp" "$fetch_log"
    return 1
  fi
  fetch_meta_tmp=$RUNTIME_DIR/$fetch_id.meta.$$
  cat > "$fetch_meta_tmp" <<EOF
FETCHED_EPOCH=$(date +%s)
BYTES=$fetch_size
TITLE_B64=$(b64_encode "$title")
INTERVAL_B64=$(b64_encode "$interval")
USERINFO_B64=$(b64_encode "$userinfo")
ANNOUNCE_B64=$(b64_encode "$announce")
SUPPORT_URL_B64=$(b64_encode "$support_url")
WEB_PAGE_URL_B64=$(b64_encode "$web_page_url")
REFILL_B64=$(b64_encode "$refill")
HWID_ACTIVE_B64=$(b64_encode "$hwid_active")
HWID_UNSUPPORTED_B64=$(b64_encode "$hwid_unsupported")
HWID_MAX_B64=$(b64_encode "$hwid_max")
HWID_LIMIT_B64=$(b64_encode "$hwid_limit")
RESTRICTION_B64=$(b64_encode "$restriction")
POLICY_STATUS=$fetch_policy_status
HTTP_STATUS=$FETCH_HTTP_STATUS
HTTP_STATUS_LINE_B64=$(b64_encode "$FETCH_HTTP_LINE")
EOF
  rm -f "$fetch_log"
  FETCH_CANDIDATE=$fetch_tmp
  FETCH_META_CANDIDATE=$fetch_meta_tmp
  FETCH_ERROR=
}

process_jobs() {
  while :; do
    for job in "$JOBS_DIR"/p-*.job; do
      [ -f "$job" ] || continue
      id=${job##*/}; id=${id%.job}
      lock_job "$id" || continue
      work=$job.work.$$
      if ! mv "$job" "$work" 2>/dev/null; then
        unlock_job "$id"
        continue
      fi
      action=$(state_get "$work" ACTION)
      FETCH_HTTP_STATUS=
      FETCH_HTTP_LINE=
      FETCH_BYTES=0
      job_started=$(date +%s)
      if [ "$action" = fetch ]; then
        job_stage=download
      else
        job_stage=build
      fi
      set_status "$id" working "$( [ "$action" = fetch ] && printf 'Скачивание подписки' || printf 'Сборка конфигурации' )" "$job_stage" "$action" "$job_started" 0
      unlock_job "$id"
      rm -f "$work"
      event_log INFO "$id" "$action started"
      if [ "$action" != fetch ] || fetch_profile "$id"; then
        if [ "$action" = fetch ]; then
          BUILD_SOURCE_OVERRIDE=$FETCH_CANDIDATE
          export BUILD_SOURCE_OVERRIDE
        fi
        BUILD_DEFER_INSTALL=1
        export BUILD_DEFER_INSTALL
        if build_xray_config "$id"; then
          job_empty=${BUILD_EMPTY:-0}
          install_ok=1
          install_superseded=0
          install_unchanged=0
          if [ "$action" = fetch ]; then
            if lock_job "$id-selection"; then
              if [ -f "$(profile_path "$id" 2>/dev/null)" ]; then
                install_source=$(profile_source "$id")
                install_meta=$(profile_meta "$id")
                install_source_backup=$RUNTIME_DIR/$id.source.previous.$$
                install_meta_backup=$RUNTIME_DIR/$id.meta.previous.$$
                install_source_had=0
                install_meta_had=0
                if [ -f "$install_source" ]; then
                  cp "$install_source" "$install_source_backup" || install_ok=0
                  install_source_had=1
                fi
                if [ -f "$install_meta" ]; then
                  cp "$install_meta" "$install_meta_backup" || install_ok=0
                  install_meta_had=1
                fi
                if [ "$install_ok" = 1 ]; then
                  atomic_replace "$FETCH_CANDIDATE" "$install_source" || install_ok=0
                fi
                if [ "$install_ok" = 1 ]; then
                  atomic_replace "$FETCH_META_CANDIDATE" "$install_meta" || install_ok=0
                fi
                if [ "$install_ok" = 1 ]; then
                  install_build_candidates_locked "$id"
                  install_result=$?
                  case "$install_result" in
                    0) ;;
                    2) install_superseded=1 ;;
                    3) install_unchanged=1 ;;
                    *) install_ok=0 ;;
                  esac
                fi
                if [ "$install_ok" = 0 ]; then
                  if [ "$install_source_had" = 1 ]; then
                    mv "$install_source_backup" "$install_source" 2>/dev/null || true
                  else
                    rm -f "$install_source" "$install_source_backup"
                  fi
                  if [ "$install_meta_had" = 1 ]; then
                    mv "$install_meta_backup" "$install_meta" 2>/dev/null || true
                  else
                    rm -f "$install_meta" "$install_meta_backup"
                  fi
                else
                  rm -f "$install_source_backup" "$install_meta_backup"
                fi
              else
                BUILD_ERROR='Profile disappeared during installation'
                install_ok=0
              fi
              unlock_job "$id-selection"
            else
              BUILD_ERROR='Could not lock profile configuration'
              install_ok=0
            fi
          else
            install_build_candidates "$id"
            install_result=$?
            case "$install_result" in
              0) ;;
              2) install_superseded=1 ;;
              3) install_unchanged=1 ;;
              *) install_ok=0 ;;
            esac
          fi
          unset BUILD_SOURCE_OVERRIDE BUILD_DEFER_INSTALL
          if [ "$install_superseded" = 1 ]; then
            discard_build_candidate
            rm -f "${FETCH_CANDIDATE:-}" "${FETCH_META_CANDIDATE:-}"
            event_log INFO "$id" 'obsolete configuration build discarded'
            [ -f "$JOBS_DIR/$id.job" ] || queue_job "$id" build || true
            continue
          elif [ "$install_ok" = 1 ]; then
            job_http=$(state_get "$(profile_meta "$id")" HTTP_STATUS)
            job_http_line=$(b64_decode "$(state_get "$(profile_meta "$id")" HTTP_STATUS_LINE_B64)")
            job_bytes=$(state_get "$(profile_meta "$id")" BYTES 0)
            job_validation=$(cat "$RUNTIME_DIR/$id.validation.log" 2>/dev/null || true)
            if [ "$job_empty" = 1 ]; then
              job_message='Подписка не содержит доступных конфигураций; трафик заблокирован'
            elif [ "$install_unchanged" = 1 ]; then
              job_message='Подписка не изменилась; работающая конфигурация сохранена'
            else
              job_message='Выбранная конфигурация проверена Xray'
            fi
            set_final_status "$id" ready "$job_message" ready "$action" "$job_started" "$(date +%s)" "$job_http" "$job_http_line" "$job_bytes" "$job_validation"
            rm -f "$ERRORS_DIR/$id.txt"
            # Перезапускать Xray имеет смысл только когда конфигурация или
            # geodata действительно поменялись: HUP рвёт все клиентские
            # соединения, а обновление подписки идёт раз в час.
            if [ "$install_unchanged" = 1 ]; then
              event_log INFO "$id" 'configuration unchanged; Xray was left running'
            else
              event_log INFO "$id" 'configuration validated'
              load_settings
              [ "$RUN_ENABLED" = 1 ] && [ "$ACTIVE_PROFILE_ID" = "$id" ] && kill -HUP 1 2>/dev/null || true
            fi
          else
            [ -n "${BUILD_ERROR:-}" ] || BUILD_ERROR='Could not install validated subscription'
            discard_build_candidate
            rm -f "${FETCH_CANDIDATE:-}" "${FETCH_META_CANDIDATE:-}"
            printf '%s\n' "$BUILD_ERROR" > "$ERRORS_DIR/$id.txt"
            job_http=${FETCH_HTTP_STATUS:-$(state_get "$(profile_meta "$id")" HTTP_STATUS)}
            job_http_line=${FETCH_HTTP_LINE:-$(b64_decode "$(state_get "$(profile_meta "$id")" HTTP_STATUS_LINE_B64)")}
            job_bytes=$FETCH_BYTES; [ "$action" = fetch ] || job_bytes=$(state_get "$(profile_meta "$id")" BYTES 0)
            set_final_status "$id" error "$BUILD_ERROR" install "$action" "$job_started" "$(date +%s)" "$job_http" "$job_http_line" "$job_bytes"
            event_log ERROR "$id" "$BUILD_ERROR"
          fi
        else
          unset BUILD_SOURCE_OVERRIDE BUILD_DEFER_INSTALL
          discard_build_candidate
          rm -f "${FETCH_CANDIDATE:-}" "${FETCH_META_CANDIDATE:-}"
          printf '%s\n' "$BUILD_ERROR" > "$ERRORS_DIR/$id.txt"
          job_validation=$(cat "$RUNTIME_DIR/$id.validation.log" 2>/dev/null || true)
          job_http=$FETCH_HTTP_STATUS; [ -n "$job_http" ] || job_http=$(state_get "$(profile_meta "$id")" HTTP_STATUS)
          job_http_line=$FETCH_HTTP_LINE; [ -n "$job_http_line" ] || job_http_line=$(b64_decode "$(state_get "$(profile_meta "$id")" HTTP_STATUS_LINE_B64)")
          job_bytes=$FETCH_BYTES; [ "$action" = fetch ] || job_bytes=$(state_get "$(profile_meta "$id")" BYTES 0)
          set_final_status "$id" error "$BUILD_ERROR" validation "$action" "$job_started" "$(date +%s)" "$job_http" "$job_http_line" "$job_bytes" "$job_validation"
          event_log ERROR "$id" "$BUILD_ERROR"
        fi
      else
        printf '%s\n' "$FETCH_ERROR" > "$ERRORS_DIR/$id.txt"
        set_final_status "$id" error "$FETCH_ERROR" download "$action" "$job_started" "$(date +%s)" "${FETCH_HTTP_STATUS:-}" "${FETCH_HTTP_LINE:-}" "${FETCH_BYTES:-0}"
        event_log ERROR "$id" "$FETCH_ERROR"
      fi
    done
    sleep 0.2
  done
}

refresh_worker() {
  while :; do
    now=$(date +%s)
    for profile in "$PROFILES_DIR"/p-*.conf; do
      [ -f "$profile" ] || continue
      id=${profile##*/}; id=${id%.conf}
      { read -r refresh_url_b64
        read -r interval
        read -r use_provider_interval
      } <<EOF
$(state_load "$profile" URL_B64 REFRESH_SECONDS USE_PROVIDER_INTERVAL)
EOF
      [ -n "$refresh_url_b64" ] || continue
      { read -r provider_interval_b64
        read -r fetched
      } <<EOF
$(state_load "$(profile_meta "$id")" INTERVAL_B64 FETCHED_EPOCH)
EOF
      if [ "${use_provider_interval:-1}" != 0 ]; then
        provider_interval=$(b64_decode "$provider_interval_b64")
        valid_number "$provider_interval" && [ "$provider_interval" -ge 1 ] && [ "$provider_interval" -le 168 ] && interval=$((provider_interval * 3600))
      fi
      valid_number "$interval" || interval=3600
      valid_number "$fetched" || fetched=0
      { read -r refresh_state
        read -r refresh_action
        read -r refresh_finished
      } <<EOF
$(state_load "$STATUS_DIR/$id.conf" STATE ACTION FINISHED_EPOCH)
EOF
      case "$refresh_state" in queued|working) continue ;; esac
      valid_number "$refresh_finished" || refresh_finished=0
      [ "$refresh_action" != fetch ] || [ "$refresh_finished" -le "$fetched" ] || fetched=$refresh_finished
      [ -f "$JOBS_DIR/$id.job" ] || [ $((fetched + interval)) -gt "$now" ] || queue_job "$id" fetch
    done
    sleep 15
  done
}

reload() {
  RESTART_REQUESTED=1
  [ -n "$XRAY_PID" ] && terminate_xray "$XRAY_PID" || true
}

terminate_xray() {
  terminate_pid=$1
  kill -TERM "$terminate_pid" 2>/dev/null || return 0
  terminate_attempt=0
  while [ "$terminate_attempt" -lt 50 ]; do
    kill -0 "$terminate_pid" 2>/dev/null || return 0
    terminate_attempt=$((terminate_attempt + 1))
    sleep 0.1
  done
  kill -KILL "$terminate_pid" 2>/dev/null || true
}

acquire_geodata_lease() {
  acquire_dir=$1
  if [ -n "$GEODATA_LEASE_DIR" ]; then
    release_geodata_lease || return 1
  fi
  /scripts/geodata.sh lease-acquire "$acquire_dir" "$$" || return 1
  GEODATA_LEASE_DIR=$acquire_dir
}

release_geodata_lease() {
  [ -n "$GEODATA_LEASE_DIR" ] || return 0
  release_dir=$GEODATA_LEASE_DIR
  /scripts/geodata.sh lease-release "$release_dir" "$$" || return 1
  GEODATA_LEASE_DIR=
}

discard_geodata_preflight() {
  case "$GEODATA_PREFLIGHT_DIR" in
    "$RUNTIME_DIR"/geodata-start.*) rm -rf "$GEODATA_PREFLIGHT_DIR" 2>/dev/null || true ;;
  esac
  GEODATA_PREFLIGHT_DIR=
  GEODATA_PREFLIGHT_METADATA=
}

prepare_runtime_geodata() {
  preflight_runtime=$1
  GEODATA_PREFLIGHT_ERROR=
  discard_geodata_preflight
  GEODATA_PREFLIGHT_DIR=$RUNTIME_DIR/geodata-start.$$.$(date +%s)
  mkdir -m 700 "$GEODATA_PREFLIGHT_DIR" || { GEODATA_PREFLIGHT_ERROR='could not create geodata preflight directory'; discard_geodata_preflight; return 1; }
  preflight_storage=$(jq -r '.storage // empty' "$preflight_runtime/.metadata/geodata.json" 2>/dev/null || true)
  case "$preflight_storage" in memory|persistent) ;; *) GEODATA_PREFLIGHT_ERROR='runtime geodata storage is invalid'; discard_geodata_preflight; return 2 ;; esac
  if [ "$preflight_storage" != "$GEODATA_STORAGE" ]; then
    GEODATA_PREFLIGHT_ERROR='runtime geodata storage is outdated'
    discard_geodata_preflight
    return 2
  fi
  preflight_overlay=$GEODATA_PREFLIGHT_DIR/overlay.json
  GEODATA_PREFLIGHT_METADATA=$GEODATA_PREFLIGHT_DIR/metadata.json
  preflight_log=$GEODATA_PREFLIGHT_DIR/prepare.log
  /scripts/geodata.sh prepare-start "$preflight_runtime/10-subscription.json" "$preflight_overlay" "$GEODATA_PREFLIGHT_METADATA" "$preflight_storage" 2> "$preflight_log"
  preflight_result=$?
  if [ "$preflight_result" -ne 0 ]; then
    GEODATA_PREFLIGHT_ERROR=$(tail -n 10 "$preflight_log" 2>/dev/null | tr '\r\n' '  ' | head -c 2048)
    [ -n "$GEODATA_PREFLIGHT_ERROR" ] || GEODATA_PREFLIGHT_ERROR='geodata preflight failed'
    discard_geodata_preflight
    return "$preflight_result"
  fi
  preflight_asset_dir=$(jq -r '.asset_dir // empty' "$GEODATA_PREFLIGHT_METADATA" 2>/dev/null || true)
  preflight_runtime_asset_dir=$(jq -r '.asset_dir // empty' "$preflight_runtime/.metadata/geodata.json" 2>/dev/null || true)
  if [ -z "$preflight_asset_dir" ] || [ "$preflight_asset_dir" != "$preflight_runtime_asset_dir" ]; then
    GEODATA_PREFLIGHT_ERROR='runtime geodata asset set is outdated'
    discard_geodata_preflight
    return 2
  fi
  jq -cS . "$preflight_overlay" > "$GEODATA_PREFLIGHT_DIR/overlay.new" 2>/dev/null &&
    jq -cS . "$preflight_runtime/70-container-geodata-tail.json" > "$GEODATA_PREFLIGHT_DIR/overlay.current" 2>/dev/null &&
    cmp -s "$GEODATA_PREFLIGHT_DIR/overlay.new" "$GEODATA_PREFLIGHT_DIR/overlay.current" || {
      GEODATA_PREFLIGHT_ERROR='runtime geodata overlay is outdated'
      discard_geodata_preflight
      return 2
    }
}

runtime_geodata_ready() {
  runtime_geodata_dir=$1
  runtime_geodata_asset_dir=$2
  runtime_geodata_metadata=$runtime_geodata_dir/.metadata/geodata.json
  jq -e '
    def safe_path_char:
      (. >= 48 and . <= 57) or (. >= 65 and . <= 90) or (. >= 97 and . <= 122) or
      . == 45 or . == 46 or . == 95;
    def safe_path_segment:
      type == "string" and length > 0 and (explode | all(.[]; safe_path_char));
    def safe_path:
      type == "string" and length > 0 and length <= 512 and
      (startswith("/") | not) and (contains("\\") | not) and
      (split("/") | all(.[]; . != "" and . != "." and . != ".." and safe_path_segment));
    (.assets | type) == "array" and all(.assets[]; type == "object" and (.file | safe_path))
  ' "$runtime_geodata_metadata" >/dev/null 2>&1 || return 1
  while IFS= read -r runtime_geodata_file; do
    [ -n "$runtime_geodata_file" ] || continue
    runtime_geodata_asset=$runtime_geodata_asset_dir/$runtime_geodata_file
    [ -f "$runtime_geodata_asset" ] && [ -s "$runtime_geodata_asset" ] && [ ! -L "$runtime_geodata_asset" ] || return 1
  done <<EOF
$(jq -r '.assets[].file' "$runtime_geodata_metadata")
EOF
}

stop() {
  STOPPING=1
  [ -n "$XRAY_PID" ] && terminate_xray "$XRAY_PID" || true
  LISTENER_MODE=${LISTENER_MODE:-auto} REDIR_PORT=${REDIR_PORT:-12345} TPROXY_PORT=${TPROXY_PORT:-12346} /scripts/network.sh shutdown || true
}

cleanup_routing() {
  [ "$ROUTING_ACTIVE" = 1 ] || return 0
  LISTENER_MODE=${LISTENER_MODE:-auto} REDIR_PORT=${REDIR_PORT:-12345} TPROXY_PORT=${TPROXY_PORT:-12346} /scripts/network.sh cleanup >/dev/null 2>&1 || true
  ROUTING_ACTIVE=0
}

# Пока Xray не обслуживает трафик, контейнер перестаёт отвечать на ICMP
# echo-request с интерфейса RouterOS: на этом держится обнаружение недоступного
# шлюза со стороны netwatch и recursive routing, то есть переключение на
# резервный канал. Молчать о неудаче здесь нельзя — не поставленное правило
# означает, что RouterOS продолжает считать шлюз живым, а трафик в это время
# уходит в никуда. Раньше обе функции глушили любой отказ в /dev/null.
block_probe() {
  [ "$PROBE_BLOCKED" = 0 ] || return 0
  if ! /scripts/network.sh probe-block > "$RUNTIME_DIR/probe.log" 2>&1; then
    probe_error=$(tail -n 5 "$RUNTIME_DIR/probe.log" 2>/dev/null | tr '\r\n' '  ' | head -c 512)
    [ "$PROBE_BLOCK_REPORTED" = 1 ] || event_log ERROR system "ICMP gateway probe could not be blocked: ${probe_error:-unknown error}"
    PROBE_BLOCK_REPORTED=1
    return 1
  fi
  PROBE_BLOCKED=1
  PROBE_BLOCK_REPORTED=0
  event_log INFO system 'ICMP gateway probe blocked until Xray is running'
}

allow_probe() {
  [ "$PROBE_BLOCKED" = 1 ] || return 0
  if ! /scripts/network.sh probe-allow > "$RUNTIME_DIR/probe.log" 2>&1; then
    probe_error=$(tail -n 5 "$RUNTIME_DIR/probe.log" 2>/dev/null | tr '\r\n' '  ' | head -c 512)
    event_log ERROR system "ICMP gateway probe could not be restored: ${probe_error:-unknown error}"
    return 1
  fi
  PROBE_BLOCKED=0
  event_log INFO system 'ICMP gateway probe restored: Xray is running'
}

supervisor() {
  while [ "$STOPPING" = 0 ]; do
    RESTART_REQUESTED=0
    load_settings
    if [ "$RUN_ENABLED" != 1 ]; then
      GEODATA_BLOCKED_RUNTIME=
      LISTENER_BLOCKED_SIGNATURE=
      cleanup_routing
      block_probe || true
      sleep 1
      continue
    fi
    runtime_state=$(state_get "$STATUS_DIR/$ACTIVE_PROFILE_ID.conf" STATE idle)
    if [ -f "$JOBS_DIR/$ACTIVE_PROFILE_ID.job" ] || [ "$runtime_state" = queued ] || [ "$runtime_state" = working ]; then
      cleanup_routing
      block_probe || true
      sleep 0.2
      continue
    fi
    runtime=$(profile_runtime_dir "$ACTIVE_PROFILE_ID")
    if [ -z "$runtime" ] || [ ! -d "$runtime" ]; then
      cleanup_routing
      block_probe || true
      runtime_source=$(profile_source "$ACTIVE_PROFILE_ID")
      runtime_empty=0
      if [ -s "$runtime_source" ] && jq -e 'type == "array" and length == 0' "$runtime_source" >/dev/null 2>&1; then runtime_empty=1; fi
      if [ "$runtime_empty" = 0 ] && [ ! -f "$JOBS_DIR/$ACTIVE_PROFILE_ID.job" ]; then
        case "$runtime_state" in
          queued|working|error) ;;
          *) [ -s "$runtime_source" ] && queue_job "$ACTIVE_PROFILE_ID" build || queue_job "$ACTIVE_PROFILE_ID" fetch ;;
        esac
      fi
      sleep 1
      continue
    fi
    if [ "$GEODATA_BLOCKED_RUNTIME" = "$runtime" ]; then
      cleanup_routing
      block_probe || true
      sleep 1
      continue
    fi
    runtime_listener_metadata=$runtime/.metadata/listener.json
    runtime_listener_valid=1
    if ! jq -e '
      type == "object" and
      (.mode == "tproxy" or .mode == "redir-tproxy" or .mode == "redir-tun") and
      (.redir_port | type) == "number" and (.redir_port | floor) == .redir_port and .redir_port >= 1 and .redir_port <= 65535 and
      (.tproxy_port | type) == "number" and (.tproxy_port | floor) == .tproxy_port and .tproxy_port >= 1 and .tproxy_port <= 65535
    ' "$runtime_listener_metadata" >/dev/null 2>&1; then
      runtime_listener_valid=0
      runtime_listener_mode=
      runtime_redir_port=
      runtime_tproxy_port=
    else
      runtime_listener_mode=$(jq -r '.mode' "$runtime_listener_metadata")
      runtime_redir_port=$(jq -r '.redir_port' "$runtime_listener_metadata")
      runtime_tproxy_port=$(jq -r '.tproxy_port' "$runtime_listener_metadata")
    fi
    if ! desired_listener_mode=$(LISTENER_MODE="$LISTENER_MODE" REDIR_PORT="$REDIR_PORT" TPROXY_PORT="$TPROXY_PORT" /scripts/network.sh resolve 2>/dev/null); then
      cleanup_routing
      block_probe || true
      event_log ERROR "$ACTIVE_PROFILE_ID" 'could not resolve current RouterOS listener mode'
      sleep 1
      continue
    fi
    listener_signature=$runtime:$desired_listener_mode:$REDIR_PORT:$TPROXY_PORT
    if [ "$runtime_listener_valid" != 1 ] ||
       [ "$runtime_listener_mode" != "$desired_listener_mode" ] ||
       [ "$runtime_redir_port" != "$REDIR_PORT" ] ||
       [ "$runtime_tproxy_port" != "$TPROXY_PORT" ]; then
      cleanup_routing
      block_probe || true
      if [ "$LISTENER_BLOCKED_SIGNATURE" != "$listener_signature" ]; then
        event_log INFO "$ACTIVE_PROFILE_ID" 'RouterOS listener runtime requires rebuild'
        if queue_job "$ACTIVE_PROFILE_ID" build; then
          LISTENER_BLOCKED_SIGNATURE=$listener_signature
        else
          event_log ERROR "$ACTIVE_PROFILE_ID" 'could not queue RouterOS listener rebuild'
        fi
      fi
      sleep 0.2
      continue
    fi
    LISTENER_BLOCKED_SIGNATURE=
    runtime_asset_dir=$(jq -r '.asset_dir // empty' "$runtime/.metadata/geodata.json" 2>/dev/null || true)
    case "$runtime_asset_dir" in
      "$RUNTIME_DIR"/geodata/*|"$APP_DIR"/geodata/*) ;;
      *) event_log ERROR "$ACTIVE_PROFILE_ID" 'invalid geodata asset directory'; sleep 3; continue ;;
    esac
    if [ -n "$GEODATA_LEASE_DIR" ] && ! release_geodata_lease; then
      event_log ERROR "$ACTIVE_PROFILE_ID" 'could not release stale geodata lease'
      sleep 1
      continue
    fi
    if ! /scripts/geodata.sh lease-release "$runtime_asset_dir" "$$" >/dev/null 2>&1; then
      event_log ERROR "$ACTIVE_PROFILE_ID" 'could not clear an untracked geodata lease'
      sleep 1
      continue
    fi
    prepare_runtime_geodata "$runtime"
    preflight_result=$?
    case "$preflight_result" in
      0) ;;
      2)
        event_log INFO "$ACTIVE_PROFILE_ID" "${GEODATA_PREFLIGHT_ERROR:-geodata runtime requires rebuild}"
        if queue_job "$ACTIVE_PROFILE_ID" build; then
          GEODATA_BLOCKED_RUNTIME=$runtime
        else
          event_log ERROR "$ACTIVE_PROFILE_ID" 'could not queue geodata runtime rebuild'
        fi
        sleep 0.2
        continue
        ;;
      75)
        sleep 0.2
        continue
        ;;
      *)
        event_log ERROR "$ACTIVE_PROFILE_ID" "${GEODATA_PREFLIGHT_ERROR:-geodata preflight failed}"
        GEODATA_BLOCKED_RUNTIME=$runtime
        cleanup_routing
        block_probe || true
        sleep 1
        continue
        ;;
    esac
    current_runtime=$(profile_runtime_dir "$ACTIVE_PROFILE_ID" 2>/dev/null || true)
    current_runtime_state=$(state_get "$STATUS_DIR/$ACTIVE_PROFILE_ID.conf" STATE idle)
    if [ "$STOPPING" = 1 ] || [ "$RESTART_REQUESTED" = 1 ] || [ "$current_runtime" != "$runtime" ] ||
       [ -f "$JOBS_DIR/$ACTIVE_PROFILE_ID.job" ] || [ "$current_runtime_state" = queued ] || [ "$current_runtime_state" = working ]; then
      discard_geodata_preflight
      [ "$STOPPING" = 0 ] || break
      continue
    fi
    if ! atomic_replace "$GEODATA_PREFLIGHT_METADATA" "$runtime/.metadata/geodata.json"; then
      GEODATA_PREFLIGHT_ERROR='could not update geodata runtime metadata'
      discard_geodata_preflight
      event_log ERROR "$ACTIVE_PROFILE_ID" "$GEODATA_PREFLIGHT_ERROR"
      GEODATA_BLOCKED_RUNTIME=$runtime
      sleep 1
      continue
    fi
    discard_geodata_preflight
    GEODATA_BLOCKED_RUNTIME=
    if ! runtime_geodata_ready "$runtime" "$runtime_asset_dir"; then
      event_log ERROR "$ACTIVE_PROFILE_ID" 'geodata assets are not ready'
      GEODATA_BLOCKED_RUNTIME=$runtime
      sleep 1
      continue
    fi
    apply_kernel_settings
    cleanup_routing
    block_probe || true
    [ "$STOPPING" = 0 ] || break
    [ "$RESTART_REQUESTED" = 0 ] || continue
    if ! acquire_geodata_lease "$runtime_asset_dir"; then
      event_log ERROR "$ACTIVE_PROFILE_ID" 'could not reserve geodata assets for Xray'
      sleep 1
      continue
    fi
    if [ "$STOPPING" = 1 ] || [ "$RESTART_REQUESTED" = 1 ]; then
      release_geodata_lease || event_log ERROR "$ACTIVE_PROFILE_ID" 'could not release geodata assets'
      [ "$STOPPING" = 0 ] || break
      continue
    fi
    event_log INFO "$ACTIVE_PROFILE_ID" "starting $(xray version 2>/dev/null | head -n1)"
    XRAY_LOCATION_ASSET="$runtime_asset_dir" xray run -confdir "$runtime" &
    XRAY_PID=$!
    printf '%s\n' "$XRAY_PID" > "$RUNTIME_DIR/xray.pid"
    if [ "$STOPPING" = 1 ] || [ "$RESTART_REQUESTED" = 1 ]; then
      terminate_xray "$XRAY_PID"
      wait "$XRAY_PID" 2>/dev/null || true
      XRAY_PID=
      rm -f "$RUNTIME_DIR/xray.pid"
      release_geodata_lease || event_log ERROR "$ACTIVE_PROFILE_ID" 'could not release geodata assets'
      [ "$STOPPING" = 0 ] || break
      continue
    fi
    xray_ready=0
    startup_attempt=0
    while [ "$startup_attempt" -lt 300 ] && kill -0 "$XRAY_PID" 2>/dev/null; do
      if nc -z -w 1 127.0.0.1 1080 >/dev/null 2>&1; then
        xray_ready=1
        break
      fi
      startup_attempt=$((startup_attempt + 1))
      sleep 0.1
    done
    if [ "$xray_ready" != 1 ]; then
      kill -0 "$XRAY_PID" 2>/dev/null && terminate_xray "$XRAY_PID"
      wait "$XRAY_PID" || true
      XRAY_PID=
      rm -f "$RUNTIME_DIR/xray.pid"
      release_geodata_lease || event_log ERROR "$ACTIVE_PROFILE_ID" 'could not release geodata assets'
      [ "$STOPPING" = 0 ] || break
      [ "$RESTART_REQUESTED" = 1 ] || sleep 3
      continue
    fi
    if [ "$STOPPING" = 1 ] || [ "$RESTART_REQUESTED" = 1 ]; then
      terminate_xray "$XRAY_PID"
      wait "$XRAY_PID" 2>/dev/null || true
      XRAY_PID=
      rm -f "$RUNTIME_DIR/xray.pid"
      release_geodata_lease || event_log ERROR "$ACTIVE_PROFILE_ID" 'could not release geodata assets'
      [ "$STOPPING" = 0 ] || break
      continue
    fi
    if ! LISTENER_MODE="$runtime_listener_mode" LISTENER_MODE_STRICT=1 REDIR_PORT="$runtime_redir_port" TPROXY_PORT="$runtime_tproxy_port" /scripts/network.sh apply > "$RUNTIME_DIR/network.log" 2>&1; then
      network_error=$(tail -n 20 "$RUNTIME_DIR/network.log" 2>/dev/null | tr '\r\n' '  ' | head -c 2048)
      event_log ERROR system "network rules failed: ${network_error:-unknown error}"
      LISTENER_MODE="$LISTENER_MODE" REDIR_PORT="$REDIR_PORT" TPROXY_PORT="$TPROXY_PORT" /scripts/network.sh cleanup >/dev/null 2>&1 || true
      terminate_xray "$XRAY_PID"
    else
      ROUTING_ACTIVE=1
      if [ "$STOPPING" = 1 ] || [ "$RESTART_REQUESTED" = 1 ] || ! kill -0 "$XRAY_PID" 2>/dev/null; then
        cleanup_routing
        block_probe || true
        terminate_xray "$XRAY_PID"
      else
        allow_probe || true
      fi
    fi
    wait "$XRAY_PID"
    rc=$?
    XRAY_PID=
    rm -f "$RUNTIME_DIR/xray.pid"
    release_geodata_lease || event_log ERROR "$ACTIVE_PROFILE_ID" 'could not release geodata assets'
    cleanup_routing
    block_probe || true
    [ "$STOPPING" = 1 ] && break
    [ "$RESTART_REQUESTED" = 1 ] || { event_log ERROR "$ACTIVE_PROFILE_ID" "Xray exited with code $rc"; sleep 3; }
  done
}

initialize_storage
apply_kernel_settings 1
trap reload HUP USR1
trap stop TERM INT
LISTENER_MODE=${LISTENER_MODE:-auto} REDIR_PORT=${REDIR_PORT:-12345} TPROXY_PORT=${TPROXY_PORT:-12346} /scripts/network.sh shutdown >/dev/null 2>&1 || true
block_probe || true

# Опрос статуса из вебки идёт раз в 3 секунды, и на каждый из них раньше
# запускался xray version и nft. Ни версия ядра в образе, ни доступность
# nftables в ядре роутера в рантайме не меняются, так что вычисляем их один раз.
xray version 2>/dev/null | head -n1 > "$RUNTIME_DIR/xray.version" || : > "$RUNTIME_DIR/xray.version"
if command -v nft >/dev/null 2>&1 && nft list tables >/dev/null 2>&1; then
  printf 'nftables\n' > "$RUNTIME_DIR/firewall.backend"
else
  printf 'iptables\n' > "$RUNTIME_DIR/firewall.backend"
fi

# md5crypt от admin. Умолчание задокументировано в README, как в соседних
# контейнерах: панель должна открываться сразу после установки, а смена пароля
# остаётся шагом пользователя.
BASIC_AUTH_HASH_DEFAULT='$1$xrayremn$Gr4qGSm.dBD8OHZ43KD2a.'

start_httpd() {
  auth=${BASIC_AUTH:-on}
  if [ "$auth" = off ]; then
    httpd -f -p 80 -h /www &
  else
    auth_user=${BASIC_AUTH_USER:-admin}
    auth_hash=${BASIC_AUTH_HASH:-$BASIC_AUTH_HASH_DEFAULT}
    printf '/:%s:%s\n' "$auth_user" "$auth_hash" > "$RUNTIME_DIR/httpd.conf"
    chmod 600 "$RUNTIME_DIR/httpd.conf" 2>/dev/null || true
    httpd -f -p 80 -h /www -c "$RUNTIME_DIR/httpd.conf" &
  fi
  HTTPD_PID=$!
}

start_process_jobs() {
  # Воркер мог умереть, забрав задание с собой: файл уже переименован в .work,
  # но обработать его некому. Возвращаем такие задания в очередь, иначе профиль
  # молча зависнет в состоянии working до перезапуска контейнера.
  for orphan in "$JOBS_DIR"/p-*.job.work.*; do
    [ -f "$orphan" ] || continue
    orphan_job=${orphan%%.job.work.*}.job
    if [ -f "$orphan_job" ]; then
      rm -f "$orphan"
    else
      mv "$orphan" "$orphan_job" 2>/dev/null || rm -f "$orphan"
    fi
  done
  process_jobs &
  JOBS_PID=$!
}

start_refresh_worker() {
  refresh_worker &
  REFRESH_PID=$!
}

# Сторож. Раньше httpd и оба воркера запускались и больше никем не
# проверялись: падение любого из них означало исчезнувшую вебку или намертво
# вставшую очередь заданий до ручного перезапуска контейнера. Сам сторож
# намеренно состоит из одного kill -0 на процесс — падать в нём нечему.
# Живёт в подшелле, поэтому STOPPING из основного процесса сюда не доходит и
# цикл бесконечный: при завершении PID 1 ядро снимает всё, что осталось в
# namespace контейнера.
watchdog() {
  while :; do
    sleep 5
    if ! kill -0 "$HTTPD_PID" 2>/dev/null; then
      event_log ERROR system 'web server stopped; restarting it'
      start_httpd
    fi
    if ! kill -0 "$JOBS_PID" 2>/dev/null; then
      event_log ERROR system 'job worker stopped; restarting it'
      start_process_jobs
    fi
    if ! kill -0 "$REFRESH_PID" 2>/dev/null; then
      event_log ERROR system 'refresh worker stopped; restarting it'
      start_refresh_worker
    fi
  done
}

start_httpd
event_log INFO system 'Web UI started on port 80'
start_process_jobs
start_refresh_worker
watchdog &
supervisor
stop
