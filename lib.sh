#!/bin/sh

XRAY_DIR=${XRAY_DIR:-/etc/xray}
APP_DIR=$XRAY_DIR/remnasub
PROFILES_DIR=$APP_DIR/profiles
STATE=$APP_DIR/state.conf
RUNTIME_DIR=/dev/shm/xray-remnasub
JOBS_DIR=$RUNTIME_DIR/jobs
STATUS_DIR=$RUNTIME_DIR/status
ERRORS_DIR=$RUNTIME_DIR/errors
EVENT_LOG=$RUNTIME_DIR/events.log

mkdir -p "$PROFILES_DIR" "$JOBS_DIR" "$STATUS_DIR" "$ERRORS_DIR"

valid_number() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; }
file_mtime() {
  if command -v stat >/dev/null 2>&1; then
    stat -c %Y "$1"
  elif command -v date >/dev/null 2>&1; then
    date -r "$1" +%s
  else
    busybox stat -c %Y "$1"
  fi
}
valid_header_block() {
  [ "${#1}" -le 16384 ] || return 1
  case "$1" in *"$(printf '\r')"*) return 1 ;; esac
  printf '%s\n' "$1" | awk '
    function trim(value) {gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); return value}
    /^[[:space:]]*$/ {next}
    {
      # Ведущая решётка — выключенный заголовок: строка сохраняется, чтобы
      # значение не потерялось, но в запрос не попадает.
      line=$0
      sub(/^[[:space:]]*#/, "", line)
      separator=index(line, ":")
      if (separator < 2) exit 1
      key=trim(substr(line, 1, separator - 1))
      if (key !~ /^[A-Za-z0-9-]+$/) exit 1
      key=tolower(key)
      if (seen[key]++) exit 1
    }
  '
}
# Тема и акцент живут в state.conf, а не только в localStorage: панель
# открывают с разных устройств, и вид не должен зависеть от того, с какого
# браузера зашли. Пустой акцент означает «взять родной цвет темы».
# Приёмник лога Xray: стандартные потоки контейнера, none (Xray сам понимает
# это как «не писать») или абсолютный путь без пробелов и обхода каталогов.
# Значение проверяется по имени переменной, чтобы негодное молчаливо
# заменялось умолчанием, а не роняло сборку конфигурации.
valid_log_sink() {
  eval "log_sink_value=\${$1:-}"
  case "$log_sink_value" in
    /dev/stdout|/dev/stderr|none) return 0 ;;
    /*[!\ ]*) case "$log_sink_value" in *..*|*' '*) ;; *) return 0 ;; esac ;;
  esac
  eval "$1=\$2"
}
valid_theme() {
  case "${1:-}" in auto|dark|light|graphite|midnight|forest|sepia) return 0 ;; *) return 1 ;; esac
}
valid_accent() {
  case "${1:-}" in
    '#'[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) return 0 ;;
    *) return 1 ;;
  esac
}
valid_profile_id() {
  case "${1:-}" in p-*) ;; *) return 1 ;; esac
  case "${1#p-}" in ''|*[!0-9A-Za-z_-]*) return 1 ;; *) return 0 ;; esac
}
b64_encode() { printf '%s' "${1:-}" | openssl base64 -A 2>/dev/null; }
b64_decode() { [ -n "${1:-}" ] && printf '%s' "$1" | openssl base64 -d -A 2>/dev/null || true; }
json_string() { jq -Rn --arg value "${1:-}" '$value'; }

state_get() {
  state_file=$1 state_key=$2 state_fallback=${3:-}
  state_value=$(awk -F= -v key="$state_key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$state_file" 2>/dev/null || true)
  printf '%s' "${state_value:-$state_fallback}"
}

# Читает несколько ключей за один запуск awk и печатает их значения по одному
# на строку в том же порядке, в каком они перечислены. Отдельный state_get на
# каждый ключ стоил отдельного fork awk, а load_settings и profiles_json
# читают их десятками на каждый опрос статуса — на роутере это заметная доля
# процессорного времени.
#
# Значение отделяется по первому '=', остаток строки берётся целиком, поэтому
# base64 с хвостовым '=' не теряет padding. Замыкающая точка нужна вызывающему
# коду: подстановка команд срезает финальные переводы строк, и без неё
# последний ключ с пустым значением не дочитался бы.
state_load() {
  state_load_file=$1
  shift
  [ -f "$state_load_file" ] || state_load_file=/dev/null
  awk -v keys="$*" '
    BEGIN {count = split(keys, wanted, " ")}
    {
      separator = index($0, "=")
      if (separator < 2) next
      key = substr($0, 1, separator - 1)
      if (key in value) next
      for (i = 1; i <= count; i++) {
        if (wanted[i] != key) continue
        value[key] = substr($0, separator + 1)
        break
      }
    }
    END {
      for (i = 1; i <= count; i++) print value[wanted[i]]
      print "."
    }
  ' "$state_load_file" 2>/dev/null
}

atomic_replace() {
  replace_source=$1 replace_target=$2
  if [ -f "$replace_target" ] && cmp -s "$replace_source" "$replace_target"; then
    rm -f "$replace_source"
    return 0
  fi
  replace_tmp=$replace_target.tmp.$$
  cp "$replace_source" "$replace_tmp" && chmod 600 "$replace_tmp" 2>/dev/null && mv "$replace_tmp" "$replace_target"
  replace_rc=$?
  rm -f "$replace_source" "$replace_tmp"
  return "$replace_rc"
}

event_log() {
  event_level=$1 event_scope=$2
  shift 2
  event_text=$(printf '%s' "$*" | tr '\r\n' '  ' | head -c 2048)
  printf '[%s] [%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$event_level" "$event_scope" "$event_text" >> "$EVENT_LOG"
  event_size=$(wc -c < "$EVENT_LOG" 2>/dev/null || printf 0)
  if valid_number "$event_size" && [ "$event_size" -gt 262144 ]; then
    tail -c 131072 "$EVENT_LOG" > "$EVENT_LOG.tmp.$$" && mv "$EVENT_LOG.tmp.$$" "$EVENT_LOG"
  fi
}

profile_path() { valid_profile_id "$1" && printf '%s/%s.conf' "$PROFILES_DIR" "$1"; }
profile_source() { printf '%s/%s.source.json' "$PROFILES_DIR" "$1"; }
profile_meta() { printf '%s/%s.meta' "$PROFILES_DIR" "$1"; }
profile_active_pointer() { valid_profile_id "$1" && printf '%s/%s.active' "$RUNTIME_DIR" "$1"; }
profile_versions_dir() { valid_profile_id "$1" && printf '%s/%s.versions' "$RUNTIME_DIR" "$1"; }
profile_runtime_dir() {
  runtime_id=$1
  runtime_pointer=$(profile_active_pointer "$runtime_id") || return 1
  runtime_version=$(cat "$runtime_pointer" 2>/dev/null || true)
  case "$runtime_version" in ''|NONE|*[!0-9A-Za-z._-]*) return 1 ;; esac
  runtime_versions=$(profile_versions_dir "$runtime_id") || return 1
  [ -d "$runtime_versions/$runtime_version" ] || return 1
  printf '%s/%s' "$runtime_versions" "$runtime_version"
}
profile_runtime() {
  runtime_metadata_dir=$(profile_runtime_dir "$1") || return 1
  printf '%s/.metadata/runtime.json' "$runtime_metadata_dir"
}
profile_configs() {
  configs_metadata_dir=$(profile_runtime_dir "$1") || return 1
  printf '%s/.metadata/configs.json' "$configs_metadata_dir"
}

discard_build_candidate() {
  case "${BUILD_CANDIDATE_DIR:-}" in
    "$RUNTIME_DIR"/p-*.candidate.*) [ ! -e "$BUILD_CANDIDATE_DIR" ] || rm -rf "$BUILD_CANDIDATE_DIR" ;;
  esac
  BUILD_CANDIDATE_DIR=
}

clear_profile_runtime() {
  clear_id=$1
  clear_pointer=$(profile_active_pointer "$clear_id") || return 1
  clear_versions=$(profile_versions_dir "$clear_id") || return 1
  clear_pointer_tmp=$clear_pointer.tmp.$$
  printf 'NONE\n' > "$clear_pointer_tmp" || return 1
  chmod 600 "$clear_pointer_tmp" 2>/dev/null || true
  mv "$clear_pointer_tmp" "$clear_pointer" || { rm -f "$clear_pointer_tmp"; return 1; }
  for clear_version in "$clear_versions"/v-*; do
    [ ! -d "$clear_version" ] || rm -rf "$clear_version" || return 1
  done
  return 0
}

lock_job() {
  lock_path=$JOBS_DIR/$1.lock lock_attempt=0
  while ! mkdir "$lock_path" 2>/dev/null; do
    lock_attempt=$((lock_attempt + 1))
    if [ "$lock_attempt" -ge 50 ]; then
      lock_owner=$(cat "$lock_path/pid" 2>/dev/null || true)
      if valid_number "$lock_owner" && kill -0 "$lock_owner" 2>/dev/null; then
        return 1
      fi
      rm -f "$lock_path/pid"
      rmdir "$lock_path" 2>/dev/null || return 1
      lock_attempt=0
    fi
    sleep 0.05
  done
  printf '%s\n' "$$" > "$lock_path/pid" || { rm -f "$lock_path/pid"; rmdir "$lock_path" 2>/dev/null; return 1; }
}

unlock_job() {
  unlock_path=$JOBS_DIR/$1.lock
  rm -f "$unlock_path/pid"
  rmdir "$unlock_path" 2>/dev/null || true
}

queue_job_locked() {
  queue_id=$1 queue_action=$2
  valid_profile_id "$queue_id" || return 1
  case "$queue_action" in fetch|build) ;; *) return 1 ;; esac
  lock_job "$queue_id" || return 1
  queue_file=$JOBS_DIR/$queue_id.job
  [ "$(state_get "$queue_file" ACTION)" != fetch ] || queue_action=fetch
  queue_tmp=$JOBS_DIR/$queue_id.job.tmp.$$
  if ! printf 'ACTION=%s\nREQUESTED=%s\n' "$queue_action" "$(date +%s)" > "$queue_tmp"; then
    unlock_job "$queue_id"
    return 1
  fi
  chmod 600 "$queue_tmp" 2>/dev/null || true
  if ! mv "$queue_tmp" "$queue_file"; then
    rm -f "$queue_tmp"
    unlock_job "$queue_id"
    return 1
  fi
  set_status "$queue_id" queued 'Задание поставлено в очередь' queued "$queue_action" 0 0 || true
  unlock_job "$queue_id"
}

queue_job() {
  queue_lock_id=$1-selection
  if ! lock_job "$queue_lock_id"; then
    return 1
  fi
  if ! valid_profile_id "$1" || [ ! -f "$(profile_path "$1" 2>/dev/null)" ]; then
    unlock_job "$queue_lock_id"
    return 1
  fi
  queue_job_locked "$1" "$2"
  queue_result=$?
  unlock_job "$queue_lock_id"
  return "$queue_result"
}

set_final_status() {
  final_id=$1
  shift
  lock_job "$final_id" || return 1
  if [ ! -f "$JOBS_DIR/$final_id.job" ]; then
    set_status "$final_id" "$@"
    final_result=$?
  else
    final_result=0
  fi
  unlock_job "$final_id"
  return "$final_result"
}

set_status() {
  status_id=$1 status_state=$2 status_message=$3
  status_file=$STATUS_DIR/$status_id.conf
  status_stage=${4:-$status_state}
  status_action=${5:-$(state_get "$status_file" ACTION)}
  status_started=${6:-$(state_get "$status_file" STARTED_EPOCH 0)}
  status_finished=${7:-$(state_get "$status_file" FINISHED_EPOCH 0)}
  status_http=${8:-$(state_get "$status_file" HTTP_STATUS)}
  status_http_line=${9:-$(b64_decode "$(state_get "$status_file" HTTP_STATUS_LINE_B64)")}
  status_bytes=${10:-$(state_get "$status_file" BYTES 0)}
  status_validation=${11:-$(b64_decode "$(state_get "$status_file" VALIDATION_B64)")}
  status_tmp=$STATUS_DIR/$status_id.conf.tmp.$$
  cat > "$status_tmp" <<EOF
STATE=$status_state
STAGE=$status_stage
ACTION=$status_action
STARTED_EPOCH=$status_started
FINISHED_EPOCH=$status_finished
UPDATED=$(date +%s)
HTTP_STATUS=$status_http
HTTP_STATUS_LINE_B64=$(b64_encode "$status_http_line")
BYTES=$status_bytes
MESSAGE_B64=$(b64_encode "$status_message")
VALIDATION_B64=$(b64_encode "$status_validation")
EOF
  chmod 600 "$status_tmp" 2>/dev/null || true
  mv "$status_tmp" "$status_file"
}

set_file_value() {
  value_file=$1 value_key=$2 value_data=$3
  value_tmp=$RUNTIME_DIR/value.$$
  awk -F= -v key="$value_key" -v value="$value_data" '
    BEGIN{found=0}
    $1==key{print key "=" value; found=1; next}
    {print}
    END{if(!found) print key "=" value}
  ' "$value_file" > "$value_tmp" && atomic_replace "$value_tmp" "$value_file"
}

set_profile_selection() {
  selection_file=$1 selection_index=$2 selection_fingerprint=$3
  selection_tmp=$RUNTIME_DIR/selection.$$
  awk -F= -v selected_index="$selection_index" -v fingerprint="$selection_fingerprint" '
    BEGIN{have_index=0; have_fingerprint=0}
    $1=="MODE"{next}
    $1=="SELECTED_INDEX"{print "SELECTED_INDEX=" selected_index; have_index=1; next}
    $1=="SELECTED_FINGERPRINT"{print "SELECTED_FINGERPRINT=" fingerprint; have_fingerprint=1; next}
    {print}
    END{if(!have_index) print "SELECTED_INDEX=" selected_index; if(!have_fingerprint) print "SELECTED_FINGERPRINT=" fingerprint}
  ' "$selection_file" > "$selection_tmp" && atomic_replace "$selection_tmp" "$selection_file"
}

# Сравнивает собранного кандидата с уже работающим runtime. Публикация новой
# версии неизбежно приводит к перезапуску Xray, а он рвёт все клиентские
# соединения, поэтому при почасовом обновлении подписки, которая не менялась,
# платить этим нельзя.
#
# Сравниваются файлы, которые читает Xray, плюс отпечаток исходника и
# выбранная позиция.
#
# Содержимое самих файлов geodata в сравнение намеренно НЕ входит. Xray
# обновляет их сам по своему cron (app/geodata), скачивая через собственный
# outbound и перезагружая геобазы в памяти без перезапуска процесса. Если
# сравнивать их размер и mtime, то первое же обновление, сделанное ядром,
# выглядело бы как изменившаяся конфигурация и приводило бы к перезапуску —
# ровно к тому, что этот код должен предотвращать. Значение имеет только
# идентичность набора ассетов: она закодирована в asset_dir (каталог назван по
# хешу списка) и в 70-container-geodata-tail.json, а те сравниваются.
#
# configs.json Xray не читает, но в сравнение включён намеренно: он описывает
# список конфигураций для панели и лежит внутри версии runtime, которая при
# публикации новой заменяется целиком. Разделять «опубликовать» и
# «перезапустить» пришлось бы ценой удержания старого каталога версии живым
# под работающим ядром. Плата за это — перезапуск, когда провайдер поменял
# конфигурацию, которая сейчас не выбрана; на фоне почасовых перезапусков на
# ровном месте это приемлемо.
runtime_matches_candidate() {
  matches_id=$1
  matches_runtime=$(profile_runtime_dir "$matches_id" 2>/dev/null) || return 1
  [ -d "$matches_runtime" ] || return 1
  case "${BUILD_CANDIDATE_DIR:-}" in "$RUNTIME_DIR"/p-*.candidate.*) ;; *) return 1 ;; esac
  [ -d "$BUILD_CANDIDATE_DIR" ] || return 1
  for matches_file in \
    10-subscription.json 70-container-geodata-tail.json 80-container-log.json 90-container-inbounds.json \
    .metadata/configs.json .metadata/listener.json .metadata/source.sha256; do
    cmp -s "$BUILD_CANDIDATE_DIR/$matches_file" "$matches_runtime/$matches_file" || return 1
  done
  matches_new=$(jq -r '.asset_key // empty' "$BUILD_CANDIDATE_DIR/.metadata/geodata.json" 2>/dev/null) || return 1
  matches_old=$(jq -r '.asset_key // empty' "$matches_runtime/.metadata/geodata.json" 2>/dev/null) || return 1
  [ -n "$matches_new" ] && [ "$matches_new" = "$matches_old" ]
}

install_build_candidates_locked() {
  install_id=$1
  install_profile=$(profile_path "$install_id") || { BUILD_ERROR='Profile disappeared during installation'; return 1; }
  [ -f "$install_profile" ] || { BUILD_ERROR='Profile disappeared during installation'; return 1; }
  install_pointer=$(profile_active_pointer "$install_id") || { BUILD_ERROR='Profile runtime path is invalid'; return 1; }
  install_versions=$(profile_versions_dir "$install_id") || { BUILD_ERROR='Profile runtime path is invalid'; return 1; }
  install_version_file=$STATUS_DIR/$install_id.version
  install_version=$(cat "$install_version_file" 2>/dev/null || printf 0)
  valid_number "$install_version" || install_version=0
  install_version=$((install_version + 1))
  install_profile_next=$install_profile.next.$$
  install_profile_previous=$install_profile.previous.$$
  install_version_next=$install_version_file.next.$$
  install_version_previous=$install_version_file.previous.$$
  install_pointer_next=$install_pointer.next.$$
  install_had_version=0
  install_current_index=$(state_get "$install_profile" SELECTED_INDEX 0)
  valid_number "$install_current_index" || install_current_index=0
  install_current_fingerprint=$(state_get "$install_profile" SELECTED_FINGERPRINT)
  if [ "$install_current_index" != "${BUILD_REQUESTED_INDEX:-$install_current_index}" ] ||
     [ "$install_current_fingerprint" != "${BUILD_REQUESTED_FINGERPRINT:-$install_current_fingerprint}" ]; then
    BUILD_SUPERSEDED=1
    discard_build_candidate
    return 2
  fi
  install_selected_index=$BUILD_SELECTED_INDEX
  install_selected_fingerprint=$BUILD_SELECTED_FINGERPRINT
  if [ "$install_current_index" = "$install_selected_index" ] &&
     [ "$install_current_fingerprint" = "$install_selected_fingerprint" ]; then
    if [ "${BUILD_EMPTY:-0}" = 1 ]; then
      if [ "$(cat "$install_pointer" 2>/dev/null || true)" = NONE ]; then
        BUILD_UNCHANGED=1
        return 3
      fi
    elif runtime_matches_candidate "$install_id"; then
      BUILD_UNCHANGED=1
      discard_build_candidate
      return 3
    fi
  fi
  if [ -f "$install_version_file" ]; then
    cp "$install_version_file" "$install_version_previous" || { BUILD_ERROR='Could not stage current runtime version'; return 1; }
    install_had_version=1
  fi
  if ! cp "$install_profile" "$install_profile_previous" ||
     ! cp "$install_profile" "$install_profile_next" ||
     ! printf '%s\n' "$install_version" > "$install_version_next" ||
     ! set_profile_selection "$install_profile_next" "$install_selected_index" "$install_selected_fingerprint"; then
    rm -f "$install_profile_next" "$install_profile_previous" "$install_version_next" "$install_version_previous" "$install_pointer_next"
    discard_build_candidate
    BUILD_ERROR='Could not stage validated Xray configuration'
    return 1
  fi
  chmod 600 "$install_profile_next" "$install_profile_previous" "$install_version_next" "$install_pointer_next" 2>/dev/null || true
  install_target=
  if [ "${BUILD_EMPTY:-0}" = 1 ]; then
    printf 'NONE\n' > "$install_pointer_next" || {
      rm -f "$install_profile_next" "$install_profile_previous" "$install_version_next" "$install_version_previous" "$install_pointer_next"
      BUILD_ERROR='Could not stage empty subscription state'
      return 1
    }
  else
    case "${BUILD_CANDIDATE_DIR:-}" in
      "$RUNTIME_DIR"/p-*.candidate.*) ;;
      *) BUILD_ERROR='Validated configuration directory is missing'; return 1 ;;
    esac
    [ -d "$BUILD_CANDIDATE_DIR" ] &&
      [ -s "$BUILD_CANDIDATE_DIR/10-subscription.json" ] &&
      [ -s "$BUILD_CANDIDATE_DIR/70-container-geodata-tail.json" ] &&
      [ -s "$BUILD_CANDIDATE_DIR/80-container-log.json" ] &&
      [ -s "$BUILD_CANDIDATE_DIR/90-container-inbounds.json" ] &&
      [ -s "$BUILD_CANDIDATE_DIR/.metadata/runtime.json" ] &&
      [ -s "$BUILD_CANDIDATE_DIR/.metadata/configs.json" ] &&
      [ -s "$BUILD_CANDIDATE_DIR/.metadata/geodata.json" ] &&
      [ -s "$BUILD_CANDIDATE_DIR/.metadata/listener.json" ] &&
      [ -s "$BUILD_CANDIDATE_DIR/.metadata/source.sha256" ] || {
        rm -f "$install_profile_next" "$install_profile_previous" "$install_version_next" "$install_version_previous" "$install_pointer_next"
        discard_build_candidate
        BUILD_ERROR='Validated configuration directory is incomplete'
        return 1
      }
    mkdir -p "$install_versions" || {
      rm -f "$install_profile_next" "$install_profile_previous" "$install_version_next" "$install_version_previous" "$install_pointer_next"
      discard_build_candidate
      BUILD_ERROR='Could not create profile runtime directory'
      return 1
    }
    install_target=$install_versions/v-$install_version-$$
    [ ! -e "$install_target" ] || {
      rm -f "$install_profile_next" "$install_profile_previous" "$install_version_next" "$install_version_previous" "$install_pointer_next"
      discard_build_candidate
      BUILD_ERROR='Runtime version already exists'
      return 1
    }
    if ! mv "$BUILD_CANDIDATE_DIR" "$install_target"; then
      rm -f "$install_profile_next" "$install_profile_previous" "$install_version_next" "$install_version_previous" "$install_pointer_next"
      discard_build_candidate
      BUILD_ERROR='Could not stage validated configuration directory'
      return 1
    fi
    BUILD_CANDIDATE_DIR=
    printf '%s\n' "${install_target##*/}" > "$install_pointer_next" || {
      rm -rf "$install_target"
      rm -f "$install_profile_next" "$install_profile_previous" "$install_version_next" "$install_version_previous" "$install_pointer_next"
      BUILD_ERROR='Could not stage active runtime pointer'
      return 1
    }
  fi
  chmod 600 "$install_profile_next" "$install_version_next" "$install_pointer_next" 2>/dev/null || true
  if ! mv "$install_profile_next" "$install_profile"; then
    [ -z "$install_target" ] || rm -rf "$install_target"
    rm -f "$install_profile_next" "$install_profile_previous" "$install_version_next" "$install_version_previous" "$install_pointer_next"
    BUILD_ERROR='Could not publish validated Xray configuration'
    return 1
  fi
  if ! mv "$install_version_next" "$install_version_file"; then
    mv "$install_profile_previous" "$install_profile" 2>/dev/null || true
    [ -z "$install_target" ] || rm -rf "$install_target"
    rm -f "$install_profile_next" "$install_version_next" "$install_version_previous" "$install_pointer_next"
    BUILD_ERROR='Could not publish Xray runtime metadata'
    return 1
  fi
  if ! mv "$install_pointer_next" "$install_pointer"; then
    mv "$install_profile_previous" "$install_profile" 2>/dev/null || true
    if [ "$install_had_version" = 1 ]; then
      mv "$install_version_previous" "$install_version_file" 2>/dev/null || true
    else
      rm -f "$install_version_file"
    fi
    [ -z "$install_target" ] || rm -rf "$install_target"
    rm -f "$install_profile_next" "$install_version_next" "$install_pointer_next"
    BUILD_ERROR='Could not activate validated Xray configuration'
    return 1
  fi
  rm -f "$install_profile_previous" "$install_version_previous"
  for install_old in "$install_versions"/v-*; do
    [ -d "$install_old" ] || continue
    [ -n "$install_target" ] && [ "$install_old" = "$install_target" ] || rm -rf "$install_old" 2>/dev/null || true
  done
  return 0
}

install_build_candidates() {
  install_lock_id=$1-selection
  if ! lock_job "$install_lock_id"; then
    BUILD_ERROR='Could not lock profile selection'
    return 1
  fi
  install_build_candidates_locked "$1"
  install_result=$?
  unlock_job "$install_lock_id"
  return "$install_result"
}

# Значения по умолчанию отделены от чтения: state_load отдаёт пустую строку и
# для отсутствующего ключа, и для ключа с пустым значением, а дальше идущая
# валидация всё равно приводит каждое поле к допустимому диапазону.
load_settings() {
  { read -r ACTIVE_PROFILE_ID
    read -r RUN_ENABLED
    read -r GLOBAL_HEADERS_B64
    read -r LISTENER_MODE
    read -r REDIR_PORT
    read -r TPROXY_PORT
    read -r LOG_LEVEL
    read -r XRAY_LOG_ERROR
    read -r XRAY_LOG_ACCESS
    read -r XRAY_LOG_DNS
    read -r XRAY_LOG_MASK_ADDRESS
    read -r NETWORK_DISABLE_IPV6
    read -r NETWORK_DISABLE_MULTICAST
    read -r NETWORK_QDISC
    read -r NETWORK_CT_ESTABLISHED
    read -r NETWORK_CT_SYN_SENT
    read -r NETWORK_CT_SYN_RECV
    read -r NETWORK_CT_FIN_WAIT
    read -r NETWORK_CT_CLOSE_WAIT
    read -r NETWORK_CT_LAST_ACK
    read -r NETWORK_CT_TIME_WAIT
    read -r NETWORK_CT_CLOSE
    read -r NETWORK_CT_UNACKNOWLEDGED
    read -r NETWORK_CT_UDP_STREAM
    read -r XRAY_SNIFFING_ENABLED
    read -r XRAY_SNIFFING_ROUTE_ONLY
    read -r XRAY_PROBE_URL_B64
    read -r XRAY_PROBE_TIMEOUT_SECONDS
    read -r XRAY_PROBE_HTTP_METHOD
    read -r GEODATA_STORAGE
    read -r UI_THEME
    read -r UI_ACCENT
  } <<EOF
$(state_load "$STATE" \
  ACTIVE_PROFILE_ID RUN_ENABLED GLOBAL_HEADERS_B64 LISTENER_MODE REDIR_PORT TPROXY_PORT LOG_LEVEL \
  XRAY_LOG_ERROR XRAY_LOG_ACCESS XRAY_LOG_DNS XRAY_LOG_MASK_ADDRESS \
  NETWORK_DISABLE_IPV6 NETWORK_DISABLE_MULTICAST NETWORK_QDISC \
  NETWORK_CT_ESTABLISHED NETWORK_CT_SYN_SENT NETWORK_CT_SYN_RECV NETWORK_CT_FIN_WAIT \
  NETWORK_CT_CLOSE_WAIT NETWORK_CT_LAST_ACK NETWORK_CT_TIME_WAIT NETWORK_CT_CLOSE \
  NETWORK_CT_UNACKNOWLEDGED NETWORK_CT_UDP_STREAM \
  XRAY_SNIFFING_ENABLED XRAY_SNIFFING_ROUTE_ONLY \
  XRAY_PROBE_URL_B64 XRAY_PROBE_TIMEOUT_SECONDS XRAY_PROBE_HTTP_METHOD \
  GEODATA_STORAGE UI_THEME UI_ACCENT)
EOF

  case "$RUN_ENABLED" in 0|1) ;; *) RUN_ENABLED=0 ;; esac
  case "$LISTENER_MODE" in auto|tproxy|redir-tproxy|redir-tun) ;; *) LISTENER_MODE=auto ;; esac
  valid_number "$REDIR_PORT" && [ "$REDIR_PORT" -ge 1 ] && [ "$REDIR_PORT" -le 65535 ] || REDIR_PORT=12345
  valid_number "$TPROXY_PORT" && [ "$TPROXY_PORT" -ge 1 ] && [ "$TPROXY_PORT" -le 65535 ] || TPROXY_PORT=12346
  [ "$REDIR_PORT" != "$TPROXY_PORT" ] || TPROXY_PORT=12346
  case "$LOG_LEVEL" in none|debug|info|warning|error) ;; *) LOG_LEVEL=warning ;; esac
  # По умолчанию логи уходят в stdout/stderr контейнера, то есть в журнал
  # RouterOS и в оперативную память. Файл на накопителе допускается, но это
  # осознанный выбор пользователя: постоянная запись логов на флешку роутера
  # изнашивает её ровно так же, как geodata. Пустое значение означает, что
  # ключ в конфигурацию не попадёт и Xray применит своё умолчание.
  valid_log_sink XRAY_LOG_ERROR /dev/stderr
  valid_log_sink XRAY_LOG_ACCESS /dev/stdout
  case "$XRAY_LOG_DNS" in 1) ;; *) XRAY_LOG_DNS=0 ;; esac
  case "$XRAY_LOG_MASK_ADDRESS" in 1) ;; *) XRAY_LOG_MASK_ADDRESS=0 ;; esac
  case "$NETWORK_DISABLE_IPV6" in 0|1) ;; *) NETWORK_DISABLE_IPV6=1 ;; esac
  case "$NETWORK_DISABLE_MULTICAST" in 0|1) ;; *) NETWORK_DISABLE_MULTICAST=1 ;; esac
  case "$NETWORK_QDISC" in system|fq_codel|cake|codel|sfq|pfifo|bfifo) ;; *) NETWORK_QDISC=fq_codel ;; esac
  valid_number "$NETWORK_CT_ESTABLISHED" && [ "$NETWORK_CT_ESTABLISHED" -ge 1 ] && [ "$NETWORK_CT_ESTABLISHED" -le 604800 ] || NETWORK_CT_ESTABLISHED=86400
  valid_number "$NETWORK_CT_SYN_SENT" && [ "$NETWORK_CT_SYN_SENT" -ge 1 ] && [ "$NETWORK_CT_SYN_SENT" -le 604800 ] || NETWORK_CT_SYN_SENT=5
  valid_number "$NETWORK_CT_SYN_RECV" && [ "$NETWORK_CT_SYN_RECV" -ge 1 ] && [ "$NETWORK_CT_SYN_RECV" -le 604800 ] || NETWORK_CT_SYN_RECV=5
  valid_number "$NETWORK_CT_FIN_WAIT" && [ "$NETWORK_CT_FIN_WAIT" -ge 1 ] && [ "$NETWORK_CT_FIN_WAIT" -le 604800 ] || NETWORK_CT_FIN_WAIT=10
  valid_number "$NETWORK_CT_CLOSE_WAIT" && [ "$NETWORK_CT_CLOSE_WAIT" -ge 1 ] && [ "$NETWORK_CT_CLOSE_WAIT" -le 604800 ] || NETWORK_CT_CLOSE_WAIT=10
  valid_number "$NETWORK_CT_LAST_ACK" && [ "$NETWORK_CT_LAST_ACK" -ge 1 ] && [ "$NETWORK_CT_LAST_ACK" -le 604800 ] || NETWORK_CT_LAST_ACK=10
  valid_number "$NETWORK_CT_TIME_WAIT" && [ "$NETWORK_CT_TIME_WAIT" -ge 1 ] && [ "$NETWORK_CT_TIME_WAIT" -le 604800 ] || NETWORK_CT_TIME_WAIT=10
  valid_number "$NETWORK_CT_CLOSE" && [ "$NETWORK_CT_CLOSE" -ge 1 ] && [ "$NETWORK_CT_CLOSE" -le 604800 ] || NETWORK_CT_CLOSE=10
  valid_number "$NETWORK_CT_UNACKNOWLEDGED" && [ "$NETWORK_CT_UNACKNOWLEDGED" -ge 1 ] && [ "$NETWORK_CT_UNACKNOWLEDGED" -le 604800 ] || NETWORK_CT_UNACKNOWLEDGED=300
  valid_number "$NETWORK_CT_UDP_STREAM" && [ "$NETWORK_CT_UDP_STREAM" -ge 1 ] && [ "$NETWORK_CT_UDP_STREAM" -le 604800 ] || NETWORK_CT_UDP_STREAM=180
  case "$XRAY_SNIFFING_ENABLED" in 0|1) ;; *) XRAY_SNIFFING_ENABLED=1 ;; esac
  case "$XRAY_SNIFFING_ROUTE_ONLY" in 0|1) ;; *) XRAY_SNIFFING_ROUTE_ONLY=1 ;; esac
  probe_url=$(b64_decode "$XRAY_PROBE_URL_B64")
  case "$probe_url" in http://*|https://*) ;; *) XRAY_PROBE_URL_B64=aHR0cHM6Ly93d3cuZ3N0YXRpYy5jb20vZ2VuZXJhdGVfMjA0 ;; esac
  valid_number "$XRAY_PROBE_TIMEOUT_SECONDS" && [ "$XRAY_PROBE_TIMEOUT_SECONDS" -ge 1 ] && [ "$XRAY_PROBE_TIMEOUT_SECONDS" -le 30 ] || XRAY_PROBE_TIMEOUT_SECONDS=5
  case "$XRAY_PROBE_HTTP_METHOD" in GET|HEAD) ;; *) XRAY_PROBE_HTTP_METHOD=HEAD ;; esac
  case "$GEODATA_STORAGE" in memory|persistent) ;; *) GEODATA_STORAGE=memory ;; esac
  valid_theme "$UI_THEME" || UI_THEME=auto
  valid_accent "$UI_ACCENT" || UI_ACCENT=
}

write_state() {
  state_tmp=$RUNTIME_DIR/state.$$
  cat > "$state_tmp" <<EOF
STATE_VERSION=1
ACTIVE_PROFILE_ID=$ACTIVE_PROFILE_ID
RUN_ENABLED=$RUN_ENABLED
GLOBAL_HEADERS_B64=$GLOBAL_HEADERS_B64
LISTENER_MODE=$LISTENER_MODE
REDIR_PORT=$REDIR_PORT
TPROXY_PORT=$TPROXY_PORT
LOG_LEVEL=$LOG_LEVEL
XRAY_LOG_ERROR=$XRAY_LOG_ERROR
XRAY_LOG_ACCESS=$XRAY_LOG_ACCESS
XRAY_LOG_DNS=$XRAY_LOG_DNS
XRAY_LOG_MASK_ADDRESS=$XRAY_LOG_MASK_ADDRESS
NETWORK_DISABLE_IPV6=$NETWORK_DISABLE_IPV6
NETWORK_DISABLE_MULTICAST=$NETWORK_DISABLE_MULTICAST
NETWORK_QDISC=$NETWORK_QDISC
NETWORK_CT_ESTABLISHED=$NETWORK_CT_ESTABLISHED
NETWORK_CT_SYN_SENT=$NETWORK_CT_SYN_SENT
NETWORK_CT_SYN_RECV=$NETWORK_CT_SYN_RECV
NETWORK_CT_FIN_WAIT=$NETWORK_CT_FIN_WAIT
NETWORK_CT_CLOSE_WAIT=$NETWORK_CT_CLOSE_WAIT
NETWORK_CT_LAST_ACK=$NETWORK_CT_LAST_ACK
NETWORK_CT_TIME_WAIT=$NETWORK_CT_TIME_WAIT
NETWORK_CT_CLOSE=$NETWORK_CT_CLOSE
NETWORK_CT_UNACKNOWLEDGED=$NETWORK_CT_UNACKNOWLEDGED
NETWORK_CT_UDP_STREAM=$NETWORK_CT_UDP_STREAM
XRAY_SNIFFING_ENABLED=$XRAY_SNIFFING_ENABLED
XRAY_SNIFFING_ROUTE_ONLY=$XRAY_SNIFFING_ROUTE_ONLY
XRAY_PROBE_URL_B64=$XRAY_PROBE_URL_B64
XRAY_PROBE_TIMEOUT_SECONDS=$XRAY_PROBE_TIMEOUT_SECONDS
XRAY_PROBE_HTTP_METHOD=$XRAY_PROBE_HTTP_METHOD
GEODATA_STORAGE=$GEODATA_STORAGE
UI_THEME=$UI_THEME
UI_ACCENT=$UI_ACCENT
EOF
  atomic_replace "$state_tmp" "$STATE"
}

apply_kernel_settings() {
  network_reset_ipv4_forwarding=${1:-0}
  load_settings
  NETWORK_RESET_IPV4_FORWARDING="$network_reset_ipv4_forwarding" \
  NETWORK_DISABLE_IPV6="$NETWORK_DISABLE_IPV6" \
  NETWORK_DISABLE_MULTICAST="$NETWORK_DISABLE_MULTICAST" \
  NETWORK_QDISC="$NETWORK_QDISC" \
  NETWORK_CT_ESTABLISHED="$NETWORK_CT_ESTABLISHED" \
  NETWORK_CT_SYN_SENT="$NETWORK_CT_SYN_SENT" \
  NETWORK_CT_SYN_RECV="$NETWORK_CT_SYN_RECV" \
  NETWORK_CT_FIN_WAIT="$NETWORK_CT_FIN_WAIT" \
  NETWORK_CT_CLOSE_WAIT="$NETWORK_CT_CLOSE_WAIT" \
  NETWORK_CT_LAST_ACK="$NETWORK_CT_LAST_ACK" \
  NETWORK_CT_TIME_WAIT="$NETWORK_CT_TIME_WAIT" \
  NETWORK_CT_CLOSE="$NETWORK_CT_CLOSE" \
  NETWORK_CT_UNACKNOWLEDGED="$NETWORK_CT_UNACKNOWLEDGED" \
  NETWORK_CT_UDP_STREAM="$NETWORK_CT_UDP_STREAM" \
    /scripts/network-alpine.sh
}

build_xray_config() {
  build_id=$1
  discard_build_candidate
  BUILD_SELECTED_INDEX=
  BUILD_SELECTED_FINGERPRINT=
  BUILD_EMPTY=0
  BUILD_SUPERSEDED=0
  BUILD_UNCHANGED=0
  BUILD_ERROR=
  build_profile=$(profile_path "$build_id") || return 1
  build_source=${BUILD_SOURCE_OVERRIDE:-$(profile_source "$build_id")}
  BUILD_REQUESTED_INDEX=$(state_get "$build_profile" SELECTED_INDEX 0)
  valid_number "$BUILD_REQUESTED_INDEX" || BUILD_REQUESTED_INDEX=0
  BUILD_REQUESTED_FINGERPRINT=$(state_get "$build_profile" SELECTED_FINGERPRINT)
  build_validation=$RUNTIME_DIR/$build_id.validation.log
  : > "$build_validation"
  [ -s "$build_source" ] || { BUILD_ERROR='Subscription has not been downloaded'; return 1; }
  if ! jq -e 'type == "array" and all(.[]; type == "object" and (.outbounds | type == "array" and length > 0))' "$build_source" >/dev/null 2>&1; then
    BUILD_ERROR='Subscription must be an array of Xray configurations'
    return 1
  fi
  build_count=$(jq -r 'length' "$build_source" 2>/dev/null || printf 0)
  valid_number "$build_count" || { BUILD_ERROR='Could not count subscription configurations'; return 1; }
  if [ "$build_count" -eq 0 ]; then
    BUILD_SELECTED_INDEX=0
    BUILD_SELECTED_FINGERPRINT=
    BUILD_EMPTY=1
    printf '%s\n' 'Subscription contains no configurations; active runtime will be cleared.' > "$build_validation"
    if [ "${BUILD_DEFER_INSTALL:-0}" != 1 ]; then
      install_build_candidates "$build_id"
      case $? in 0|2|3) ;; *) return 1 ;; esac
    fi
    BUILD_ERROR=
    return 0
  fi

  load_settings
  if ! build_listener_mode=$(LISTENER_MODE="$LISTENER_MODE" REDIR_PORT="$REDIR_PORT" TPROXY_PORT="$TPROXY_PORT" /scripts/network.sh resolve 2>/dev/null); then
    BUILD_ERROR='Could not resolve RouterOS listener mode'
    return 1
  fi
  case "$build_listener_mode" in tproxy|redir-tproxy|redir-tun) ;; *) BUILD_ERROR='RouterOS listener mode is invalid'; return 1 ;; esac

  BUILD_CANDIDATE_DIR=$RUNTIME_DIR/$build_id.candidate.$$
  build_metadata=$BUILD_CANDIDATE_DIR/.metadata
  if ! mkdir -p "$build_metadata"; then
    BUILD_ERROR='Could not create candidate configuration directory'
    discard_build_candidate
    return 1
  fi
  if ! jq -n \
       --arg mode "$build_listener_mode" \
       --argjson redir_port "$REDIR_PORT" \
       --argjson tproxy_port "$TPROXY_PORT" \
       '{mode:$mode,redir_port:$redir_port,tproxy_port:$tproxy_port}' > "$build_metadata/listener.json"; then
    BUILD_ERROR='Could not record RouterOS listener settings'
    discard_build_candidate
    return 1
  fi
  build_source_sha256=$(openssl dgst -sha256 "$build_source" 2>/dev/null | awk '{print $NF}')
  case "$build_source_sha256" in ''|*[!0-9a-f]*) BUILD_ERROR='Could not fingerprint subscription source'; discard_build_candidate; return 1 ;; esac
  [ "${#build_source_sha256}" -eq 64 ] || { BUILD_ERROR='Could not fingerprint subscription source'; discard_build_candidate; return 1; }
  printf '%s\n' "$build_source_sha256" > "$build_metadata/source.sha256" || {
    BUILD_ERROR='Could not store subscription fingerprint'
    discard_build_candidate
    return 1
  }
  build_cached_configs=$(profile_configs "$build_id" 2>/dev/null || true)
  build_cached_sha=
  [ -z "$build_cached_configs" ] || build_cached_sha=$(cat "${build_cached_configs%/configs.json}/source.sha256" 2>/dev/null || true)
  if [ "$build_cached_sha" = "$build_source_sha256" ] &&
     jq -e --argjson count "$build_count" 'type == "array" and length == $count and all(.[]; (.index | type == "number") and (.fingerprint | type == "string" and length == 64) and has("port"))' "$build_cached_configs" >/dev/null 2>&1; then
    if ! jq 'map(.selected = false)' "$build_cached_configs" > "$build_metadata/configs.unselected.json"; then
      BUILD_ERROR='Could not reuse subscription metadata'
      discard_build_candidate
      return 1
    fi
  else
    build_entries=$build_metadata/configs.entries.jsonl
    build_configs_raw=$build_metadata/configs.raw.jsonl
    if ! jq -c 'to_entries[] | {index:.key,config:.value}' "$build_source" > "$build_entries"; then
      BUILD_ERROR='Could not read subscription configurations'
      discard_build_candidate
      return 1
    fi
    : > "$build_configs_raw"
    while IFS= read -r build_entry; do
      if ! build_canonical=$(printf '%s' "$build_entry" | jq -cS '.config'); then
        BUILD_ERROR='Could not canonicalize a subscription configuration'
        discard_build_candidate
        return 1
      fi
      build_fingerprint=$(printf '%s' "$build_canonical" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}')
      case "$build_fingerprint" in ''|*[!0-9a-f]*) BUILD_ERROR='Could not fingerprint a subscription configuration'; discard_build_candidate; return 1 ;; esac
      [ "${#build_fingerprint}" -eq 64 ] || { BUILD_ERROR='Could not fingerprint a subscription configuration'; discard_build_candidate; return 1; }
      if ! printf '%s' "$build_entry" | jq -c --arg fingerprint "$build_fingerprint" '
      def ascii_digit:
        . >= 48 and . <= 57;
      def numeric_text:
        type == "string" and length > 0 and (explode | all(.[]; ascii_digit));
      def endpoint_parts:
        if type != "string" then {}
        elif startswith("[") then
          (.[1:] | split("]:")) as $parts |
          if ($parts | length) == 2 and ($parts[0] | length) > 0 and
             (($parts[0] | contains("]")) | not) and ($parts[1] | numeric_text)
          then {bracket:$parts[0],endpoint_port:$parts[1]}
          else {} end
        else
          (split(":")) as $parts |
          if ($parts | length) == 2 and ($parts[0] | length) > 0 and ($parts[1] | numeric_text)
          then {plain:$parts[0],endpoint_port:$parts[1]}
          else {} end
        end;
      .index as $index |
      .config as $config |
      (($config.outbounds? // []) | if type == "array" then . else [] end |
        map(select(((.protocol? // "") | tostring | ascii_downcase) as $protocol |
          ($protocol != "freedom" and $protocol != "blackhole" and $protocol != "dns" and $protocol != "loopback"))) | .[0]) as $outbound |
      ([$config.remarks?, $config.name?, $config.meta.serverDescription?, $config.ps?, $outbound.tag?] |
        map(select(type == "string" and length > 0)) | .[0]) as $name |
      ([$config.meta.serverDescription?, $config.description?] |
        map(select(type == "string" and length > 0)) | .[0]) as $description |
      (($outbound.settings.peers[0].endpoint? // $outbound.settings.endpoint? // "") | tostring) as $endpoint |
      ($endpoint | endpoint_parts) as $endpoint_parts |
      ([$outbound.settings.vnext[0].address?, $outbound.settings.servers[0].address?,
        $outbound.settings.address?, $outbound.settings.server?, ($endpoint_parts.bracket // $endpoint_parts.plain),
        $outbound.streamSettings.realitySettings.serverName?,
        $outbound.streamSettings.tlsSettings.serverName?, $outbound.streamSettings.wsSettings.headers.Host?] |
        map(if type == "number" then tostring else . end | select(type == "string" and length > 0)) | .[0]) as $address |
      ([$outbound.settings.vnext[0].port?, $outbound.settings.servers[0].port?,
        $outbound.settings.port?, $outbound.settings.peers[0].port?, $endpoint_parts.endpoint_port?] |
        map(if type == "number" then . elif numeric_text then tonumber else empty end | select(. >= 1 and . <= 65535)) | .[0]) as $port |
      {index:$index,name:($name // ("\u041a\u043e\u043d\u0444\u0438\u0433\u0443\u0440\u0430\u0446\u0438\u044f " + (($index + 1) | tostring))),description:($description // ""),protocol:(($outbound.protocol? // "") | tostring),address:($address // ""),port:($port // 0),fingerprint:$fingerprint,selected:false}
      ' >> "$build_configs_raw"; then
        BUILD_ERROR='Could not describe a subscription configuration'
        discard_build_candidate
        return 1
      fi
    done < "$build_entries"
    if ! jq -s . "$build_configs_raw" > "$build_metadata/configs.unselected.json"; then
      BUILD_ERROR='Could not assemble subscription metadata'
      discard_build_candidate
      return 1
    fi
    rm -f "$build_entries" "$build_configs_raw"
  fi

  build_requested_index=$BUILD_REQUESTED_INDEX
  build_requested_fingerprint=$BUILD_REQUESTED_FINGERPRINT
  build_selected=0
  build_matched=
  if [ -n "$build_requested_fingerprint" ]; then
    build_matched=$(jq -r --arg fingerprint "$build_requested_fingerprint" '.[] | select(.fingerprint == $fingerprint) | .index' "$build_metadata/configs.unselected.json" | head -n1)
  fi
  if valid_number "$build_matched" && [ "$build_matched" -lt "$build_count" ]; then
    build_selected=$build_matched
  elif valid_number "$build_requested_index" && [ "$build_requested_index" -lt "$build_count" ]; then
    build_selected=$build_requested_index
  fi
  build_selected_fingerprint=$(jq -r --argjson selected "$build_selected" '.[] | select(.index == $selected) | .fingerprint' "$build_metadata/configs.unselected.json" | head -n1)
  if ! jq --argjson selected "$build_selected" 'map(.selected = (.index == $selected))' "$build_metadata/configs.unselected.json" > "$build_metadata/configs.json" ||
     ! jq --argjson selected "$build_selected" '.[$selected]' "$build_source" > "$BUILD_CANDIDATE_DIR/10-subscription.json"; then
    BUILD_ERROR='Could not select a subscription configuration'
    discard_build_candidate
    return 1
  fi
  rm -f "$build_metadata/configs.unselected.json"

  if ! build_inbound_conflict=$(jq -r \
       --arg listener_mode "$build_listener_mode" \
       --argjson redir_port "$REDIR_PORT" \
       --argjson tproxy_port "$TPROXY_PORT" '
       def ascii_space:
         . == 9 or . == 10 or . == 11 or . == 12 or . == 13 or . == 32;
       def ascii_digit:
         . >= 48 and . <= 57;
       def numeric_text:
         type == "string" and length > 0 and (explode | all(.[]; ascii_digit));
       def trim_left_space:
         if length > 0 and (.[0] | ascii_space) then .[1:] | trim_left_space else . end;
       def trim_space:
         explode | trim_left_space | reverse | trim_left_space | reverse | implode;
       def remove_space:
         explode | map(select((ascii_space) | not)) | implode;
       def clean_text:
         (. // "" | tostring | explode |
          map(if . == 9 or . == 10 or . == 13 then 32 else . end) |
          implode | .[0:128]);
       def resolved_port($config; $value):
         ($value | tostring | trim_space) as $raw |
         if ($raw | startswith("env:")) then
           (($config.env? // {})[($raw[4:])] // env[($raw[4:])] // "" | tostring | trim_space)
         else $raw end;
       def uses_port($config; $inbound; $port):
         ($inbound.port? // "") as $configured |
         (if ($configured | type) == "number" then [($configured | floor | tostring)]
          elif ($configured | type) == "string" then ($configured | split(",") | map(resolved_port($config; .)))
          else [] end) |
         any(.[];
           (remove_space | split("-")) as $range |
           if ($range | length) == 1 and ($range[0] | numeric_text) then
             ($range[0] | tonumber) == $port
           elif ($range | length) == 2 and all($range[]; numeric_text) then
             (($range[0] | tonumber) <= $port and $port <= ($range[1] | tonumber))
           else false end);
       def uses_ip_listener($inbound):
         (($inbound.listen? // "") | if type == "string" then . else "" end) as $listen |
         ((($listen | startswith("/")) or ($listen | startswith("@"))) | not);
       def configured_networks($inbound):
         (($inbound.protocol? // "") | tostring | ascii_downcase) as $protocol |
         if $protocol == "tun" then []
         elif $protocol == "wireguard" then ["udp"]
         elif $protocol == "dokodemo-door" or $protocol == "tunnel" or $protocol == "shadowsocks" then
           ($inbound.settings.network? // $inbound.settings.allowedNetwork? // "tcp") |
           (if type == "array" then . else tostring | split(",") end) |
           map(tostring | ascii_downcase | remove_space | select(. == "tcp" or . == "udp"))
         else ["tcp"] end |
         map(if . == "tcp" then
           (($inbound.streamSettings.network? // "tcp") | tostring | ascii_downcase) as $transport |
           if $transport == "mkcp" or $transport == "kcp" or $transport == "quic" or $transport == "hysteria" then "udp" else "tcp" end
         else . end) |
         unique;
       def managed_listeners($mode; $redir; $tproxy):
         [{name:"web UI",network:"tcp",port:80},{name:"mixed",network:"tcp",port:1080}] +
         if $mode == "tproxy" then [
           {name:"TPROXY",network:"tcp",port:$tproxy},
           {name:"TPROXY",network:"udp",port:$tproxy}
         ] elif $mode == "redir-tproxy" then [
           {name:"REDIR",network:"tcp",port:$redir},
           {name:"TPROXY",network:"udp",port:$tproxy}
         ] else [
           {name:"REDIR",network:"tcp",port:$redir}
         ] end;
       . as $config |
       ((.inbounds? // []) | if type == "array" then . else [] end) as $inbounds |
       ([managed_listeners($listener_mode; $redir_port; $tproxy_port)[] as $managed |
         $inbounds[] as $inbound |
         select(uses_ip_listener($inbound)) |
         select((configured_networks($inbound) | index($managed.network)) != null) |
         select(uses_port($config; $inbound; $managed.port)) |
         {type:"listener",tag:($inbound.tag? | clean_text),protocol:($inbound.protocol? | clean_text),managed:$managed}] +
        [select($listener_mode == "redir-tun") |
         $inbounds[] as $inbound |
         select((($inbound.protocol? // "") | tostring | ascii_downcase) == "tun" and $inbound.settings.name? == "Xray") |
         {type:"tun",tag:($inbound.tag? | clean_text),protocol:"tun"}]) as $conflicts |
       if ($conflicts | length) == 0 then empty
       else $conflicts[0] |
         (.tag | if length == 0 then "(untagged)" else . end) as $tag |
         if .type == "tun" then
           "Source inbound " + $tag + " (tun) conflicts with container TUN interface Xray"
         else
           "Source inbound " + $tag + " (" + (.protocol | if length == 0 then "unknown" else . end) + ") conflicts with container " +
           .managed.name + " listener " + (.managed.network | ascii_upcase) + "/" + (.managed.port | tostring)
         end
       end
     ' "$BUILD_CANDIDATE_DIR/10-subscription.json" 2>/dev/null); then
    BUILD_ERROR='Could not inspect source inbound listeners'
    discard_build_candidate
    return 1
  fi
  if [ -n "$build_inbound_conflict" ]; then
    BUILD_ERROR=$build_inbound_conflict
    discard_build_candidate
    return 1
  fi

  if ! build_reserved_inbound_tag=$(jq -r '
       ["xray-remnasub-mixed", "xray-remnasub-tcp", "xray-remnasub-udp", "xray-remnasub-tproxy", "xray-remnasub-tun"] as $reserved |
       ([.inbounds[]?.tag? |
         select(type == "string") |
         . as $tag |
         select(($reserved | index($tag)) != null)][0] // empty)
     ' "$BUILD_CANDIDATE_DIR/10-subscription.json" 2>/dev/null); then
    BUILD_ERROR='Could not inspect source inbound tags'
    discard_build_candidate
    return 1
  fi
  if [ -n "$build_reserved_inbound_tag" ]; then
    BUILD_ERROR="Source inbound tag $build_reserved_inbound_tag is reserved for container-managed listeners"
    discard_build_candidate
    return 1
  fi

  build_geodata_log=$build_metadata/geodata.prepare.log
  if ! /scripts/geodata.sh prepare \
       "$BUILD_CANDIDATE_DIR/10-subscription.json" \
       "$BUILD_CANDIDATE_DIR/70-container-geodata-tail.json" \
       "$build_metadata/geodata.json" \
       "$GEODATA_STORAGE" 2> "$build_geodata_log"; then
    cp "$build_geodata_log" "$build_validation" 2>/dev/null || true
    BUILD_ERROR=$(tail -n 20 "$build_geodata_log" 2>/dev/null | tr '\n' ' ' | head -c 4096)
    [ -n "$BUILD_ERROR" ] || BUILD_ERROR='Could not prepare Xray geodata assets'
    discard_build_candidate
    return 1
  fi
  rm -f "$build_geodata_log"
  build_asset_dir=$(jq -r '.asset_dir // empty' "$build_metadata/geodata.json" 2>/dev/null || true)
  case "$GEODATA_STORAGE:$build_asset_dir" in
    memory:"$RUNTIME_DIR"/geodata/*|persistent:"$APP_DIR"/geodata/*) ;;
    *)
      BUILD_ERROR='Geodata asset directory is invalid'
      discard_build_candidate
      return 1
      ;;
  esac
  if [ ! -d "$build_asset_dir" ]; then
    BUILD_ERROR='Geodata assets are not ready'
    discard_build_candidate
    return 1
  fi

  [ "$XRAY_SNIFFING_ENABLED" = 1 ] && build_sniffing=true || build_sniffing=false
  [ "$XRAY_SNIFFING_ROUTE_ONLY" = 1 ] && build_route_only=true || build_route_only=false
  jq -e '(.fakeDns? != null) or (.fakedns? != null)' "$BUILD_CANDIDATE_DIR/10-subscription.json" >/dev/null 2>&1 && build_fakedns=true || build_fakedns=false
  if ! jq -n --arg log_level "$LOG_LEVEL" --arg error "$XRAY_LOG_ERROR" --arg access "$XRAY_LOG_ACCESS" \
        --argjson dns_log "$XRAY_LOG_DNS" --argjson mask_address "$XRAY_LOG_MASK_ADDRESS" \
        '{log: ({loglevel: $log_level, dnsLog: ($dns_log == 1), maskAddress: (if $mask_address == 1 then "quarter" else "" end)}
                + (if $error == "" then {} else {error: $error} end)
                + (if $access == "" then {} else {access: $access} end))}' > "$BUILD_CANDIDATE_DIR/80-container-log.json" ||
     ! jq -n \
       --arg listener_mode "$build_listener_mode" \
       --argjson redir_port "$REDIR_PORT" \
       --argjson tproxy_port "$TPROXY_PORT" \
       --argjson sniffing_enabled "$build_sniffing" \
       --argjson route_only "$build_route_only" \
       --argjson fakedns "$build_fakedns" '
       def managed_sniffing: {
         enabled:$sniffing_enabled,
         destOverride:(["http","tls","quic"] + (if $fakedns then ["fakedns"] else [] end)),
         metadataOnly:false,
         routeOnly:$route_only
       };
       {inbounds:([
         {tag:"xray-remnasub-mixed",port:1080,protocol:"mixed",settings:{udp:true},sniffing:managed_sniffing}
       ] + if $listener_mode == "tproxy" then [
         {tag:"xray-remnasub-tproxy",port:$tproxy_port,protocol:"dokodemo-door",settings:{network:"tcp,udp",followRedirect:true},streamSettings:{sockopt:{tproxy:"tproxy"}},sniffing:managed_sniffing}
       ] elif $listener_mode == "redir-tproxy" then [
         {tag:"xray-remnasub-tcp",port:$redir_port,protocol:"dokodemo-door",settings:{network:"tcp",followRedirect:true},streamSettings:{sockopt:{tproxy:"redirect"}},sniffing:managed_sniffing},
         {tag:"xray-remnasub-udp",port:$tproxy_port,protocol:"dokodemo-door",settings:{network:"udp",followRedirect:true},streamSettings:{sockopt:{tproxy:"tproxy"}},sniffing:managed_sniffing}
       ] else [
         {tag:"xray-remnasub-tcp",port:$redir_port,protocol:"dokodemo-door",settings:{network:"tcp",followRedirect:true},streamSettings:{sockopt:{tproxy:"redirect"}},sniffing:managed_sniffing},
         {tag:"xray-remnasub-tun",protocol:"tun",settings:{name:"Xray",MTU:1500,gateway:["100.64.0.1/32"]},sniffing:managed_sniffing}
       ] end)}
     ' > "$BUILD_CANDIDATE_DIR/90-container-inbounds.json"; then
    BUILD_ERROR='Could not assemble RouterOS configuration overlay'
    discard_build_candidate
    return 1
  fi
  chmod 700 "$BUILD_CANDIDATE_DIR" "$build_metadata" 2>/dev/null || true
  chmod 600 "$BUILD_CANDIDATE_DIR/10-subscription.json" "$BUILD_CANDIDATE_DIR/70-container-geodata-tail.json" "$BUILD_CANDIDATE_DIR/80-container-log.json" "$BUILD_CANDIDATE_DIR/90-container-inbounds.json" "$build_metadata/configs.json" "$build_metadata/geodata.json" "$build_metadata/listener.json" "$build_metadata/source.sha256" 2>/dev/null || true

  if ! XRAY_LOCATION_ASSET="$build_asset_dir" xray run -test -confdir "$BUILD_CANDIDATE_DIR" > "$build_validation" 2>&1; then
    BUILD_ERROR=$(tail -n 20 "$build_validation" | tr '\n' ' ' | head -c 4096)
    [ -n "$BUILD_ERROR" ] || BUILD_ERROR='Xray rejected the selected configuration'
    discard_build_candidate
    return 1
  fi
  build_runtime_tmp=$build_metadata/runtime.json.tmp
  if ! jq -s '
        .[0] as $source |
        .[1] as $geodata |
        .[2].log as $log |
        .[3].inbounds as $managed |
        $source + {
          env:(($source.env // {}) + ($geodata.env // {})),
          geodata:$geodata.geodata,
          log:$log,
          inbounds:(($source.inbounds // []) + $managed),
          outbounds:(($source.outbounds // []) + ($geodata.outbounds // []))
        }
      ' \
        "$BUILD_CANDIDATE_DIR/10-subscription.json" "$BUILD_CANDIDATE_DIR/70-container-geodata-tail.json" "$BUILD_CANDIDATE_DIR/80-container-log.json" "$BUILD_CANDIDATE_DIR/90-container-inbounds.json" > "$build_runtime_tmp" ||
     ! jq -e 'type == "object"' "$build_runtime_tmp" >/dev/null 2>&1 ||
     ! mv "$build_runtime_tmp" "$build_metadata/runtime.json"; then
    BUILD_ERROR='Could not generate merged Xray runtime configuration'
    discard_build_candidate
    return 1
  fi
  chmod 600 "$build_metadata/runtime.json" 2>/dev/null || true
  BUILD_SELECTED_INDEX=$build_selected
  BUILD_SELECTED_FINGERPRINT=$build_selected_fingerprint
  if [ "${BUILD_DEFER_INSTALL:-0}" != 1 ]; then
    install_build_candidates "$build_id"
    case $? in 0|2|3) ;; *) return 1 ;; esac
  fi
  BUILD_ERROR=
}

# Хеш проверяет busybox httpd своим crypt, поэтому и генерировать его лучше тем
# же busybox: если mkpasswd умеет sha512, значит умеет и httpd. md5crypt
# остаётся запасным вариантом — он поддерживается всегда, но слаб, поэтому
# используется, только когда sha512 недоступен. Печатает две строки: хеш и
# название алгоритма.
password_hash() {
  password_hash_value=
  password_hash_algorithm=md5crypt
  if command -v mkpasswd >/dev/null 2>&1; then
    password_hash_value=$(printf '%s\n' "$1" | mkpasswd -m sha512 -P 0 2>/dev/null || true)
    case "$password_hash_value" in
      '$6$'*) password_hash_algorithm=sha512crypt ;;
      *) password_hash_value= ;;
    esac
  fi
  if [ -z "$password_hash_value" ]; then
    password_hash_value=$(printf '%s\n' "$1" | openssl passwd -1 -stdin 2>/dev/null) || return 1
    case "$password_hash_value" in '$1$'*) ;; *) return 1 ;; esac
  fi
  printf '%s\n%s\n' "$password_hash_value" "$password_hash_algorithm"
}
