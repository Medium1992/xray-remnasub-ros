#!/bin/sh
set -eu
umask 077

MAX_ASSETS=32
MAX_ASSET_BYTES=134217728
MAX_FILE_BLOCKS=262146
MEMORY_ROOT=${GEODATA_MEMORY_ROOT:-/dev/shm/xray-remnasub/geodata}
PERSISTENT_ROOT=${GEODATA_PERSISTENT_ROOT:-/etc/xray/remnasub/geodata}
LOCK_ROOT=${GEODATA_LOCK_ROOT:-/dev/shm/xray-remnasub/geodata-locks}
WORK_ROOT=${GEODATA_WORK_ROOT:-/dev/shm/xray-remnasub}
LOCK_OWNER_GRACE_ATTEMPTS=50
LOCK_MAX_ATTEMPTS=${GEODATA_LOCK_MAX_ATTEMPTS:-600}
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
CRON_FILTER=$SCRIPT_DIR/geodata-cron.jq
TEMP_PATHS=
HELD_LOCKS=
ROLLBACK_ACTIVE=0
ROLLBACK_BACKUP=
ROLLBACK_RECORDS=
PENDING_LEASE_MARKER=

cleanup() {
  cleanup_rollback_failed=0
  case "$PENDING_LEASE_MARKER" in
    "$LOCK_ROOT"/*.leases/*) rm -f "$PENDING_LEASE_MARKER" 2>/dev/null || true ;;
  esac
  if [ "$ROLLBACK_ACTIVE" = 1 ] && [ -n "$ROLLBACK_BACKUP" ] && [ -s "$ROLLBACK_RECORDS" ]; then
    if rollback_published "$ROLLBACK_BACKUP" "$ROLLBACK_RECORDS"; then
      ROLLBACK_ACTIVE=0
    else
      cleanup_rollback_failed=1
      printf 'Could not roll back geodata assets; recovery data was kept in %s\n' "$ROLLBACK_BACKUP" >&2
    fi
  fi
  for cleanup_path in $TEMP_PATHS; do
    if [ "$cleanup_rollback_failed" = 1 ] && [ "$cleanup_path" = "$ROLLBACK_BACKUP" ]; then
      continue
    fi
    case "$cleanup_path" in
      "$MEMORY_ROOT"/*|"$PERSISTENT_ROOT"/*|"$LOCK_ROOT"/*|"$WORK_ROOT"/geodata-prepare.*) rm -rf "$cleanup_path" 2>/dev/null || true ;;
    esac
  done
  for cleanup_lock in $HELD_LOCKS; do
    rm -f "$cleanup_lock/pid" 2>/dev/null || true
    rmdir "$cleanup_lock" 2>/dev/null || true
  done
}

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

lock_owner_is_valid() {
  lock_owner_value=$1
  case "$lock_owner_value" in
    *:*)
      lock_owner_pid=${lock_owner_value%%:*}
      lock_owner_start=${lock_owner_value#*:}
      case "$lock_owner_pid" in ''|*[!0-9]*) return 1 ;; esac
      case "$lock_owner_start" in ''|*[!0-9]*) return 1 ;; esac
      ;;
    ''|*[!0-9]*) return 1 ;;
  esac
}

lock_owner_is_live() {
  lock_owner_is_valid "$1" || return 1
  case "$1" in
    *:*) lease_identity_is_live "$1" ;;
    *) pid_is_live "$1" ;;
  esac
}

lock_acquire() {
  lock_path=$1
  lock_attempt=0
  lock_ownerless_attempts=0
  while ! mkdir "$lock_path" 2>/dev/null; do
    lock_owner=$(cat "$lock_path/pid" 2>/dev/null || true)
    if lock_owner_is_valid "$lock_owner"; then
      lock_ownerless_attempts=0
      if ! lock_owner_is_live "$lock_owner"; then
        rm -f "$lock_path/pid" 2>/dev/null || true
        rmdir "$lock_path" 2>/dev/null || true
      fi
    else
      lock_ownerless_attempts=$((lock_ownerless_attempts + 1))
      if [ "$lock_ownerless_attempts" -ge "$LOCK_OWNER_GRACE_ATTEMPTS" ]; then
        lock_owner=$(cat "$lock_path/pid" 2>/dev/null || true)
        if ! lock_owner_is_live "$lock_owner"; then
          rm -f "$lock_path/pid" 2>/dev/null || true
          rmdir "$lock_path" 2>/dev/null || true
          lock_ownerless_attempts=0
        fi
      fi
    fi
    lock_attempt=$((lock_attempt + 1))
    [ "$lock_attempt" -lt "$LOCK_MAX_ATTEMPTS" ] || return 1
    sleep 0.1
  done
  lock_identity=$(lease_identity "$$") || { rmdir "$lock_path" 2>/dev/null || true; return 1; }
  printf '%s\n' "$lock_identity" > "$lock_path/pid" || { rmdir "$lock_path" 2>/dev/null || true; return 1; }
  HELD_LOCKS="$lock_path $HELD_LOCKS"
}

lock_release() {
  release_lock=$1
  rm -f "$release_lock/pid"
  rmdir "$release_lock" 2>/dev/null || true
  next_locks=
  for held_lock in $HELD_LOCKS; do
    [ "$held_lock" = "$release_lock" ] || next_locks="$next_locks $held_lock"
  done
  HELD_LOCKS=$next_locks
}

asset_location() {
  asset_location_dir=$1
  ASSET_LOCATION_KEY=${asset_location_dir##*/}
  asset_location_parent=${asset_location_dir%/*}
  case "$asset_location_parent" in
    "$MEMORY_ROOT") ASSET_LOCATION_STORAGE=memory ;;
    "$PERSISTENT_ROOT") ASSET_LOCATION_STORAGE=persistent ;;
    *) return 1 ;;
  esac
  case "$ASSET_LOCATION_KEY" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#ASSET_LOCATION_KEY}" -eq 64 ]
}

pid_is_live() {
  case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null
}

lease_identity() {
  identity_pid=$1
  pid_is_live "$identity_pid" || return 1
  identity_start=$(awk '{print $22}' "/proc/$identity_pid/stat" 2>/dev/null || true)
  case "$identity_start" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s:%s\n' "$identity_pid" "$identity_start"
}

lease_identity_is_live() {
  identity_value=$1
  case "$identity_value" in
    *:*) identity_pid=${identity_value%%:*} ;;
    *) return 1 ;;
  esac
  current_identity=$(lease_identity "$identity_pid") || return 1
  [ "$current_identity" = "$identity_value" ]
}

prune_leases() {
  lease_directory=$1
  ACTIVE_LEASES=0
  [ -d "$lease_directory" ] || return 0
  for lease_temp in "$lease_directory"/.*.tmp.*; do
    [ -e "$lease_temp" ] || continue
    rm -f "$lease_temp" 2>/dev/null || true
  done
  for lease_file in "$lease_directory"/*; do
    [ -f "$lease_file" ] && [ ! -L "$lease_file" ] || { rm -f "$lease_file" 2>/dev/null || true; continue; }
    lease_value=$(cat "$lease_file" 2>/dev/null || true)
    if lease_identity_is_live "$lease_value"; then
      ACTIVE_LEASES=$((ACTIVE_LEASES + 1))
    else
      rm -f "$lease_file" 2>/dev/null || true
    fi
  done
  [ "$ACTIVE_LEASES" -gt 0 ] || rmdir "$lease_directory" 2>/dev/null || true
}

lease_acquire() {
  lease_dir=$1
  lease_owner=$2
  asset_location "$lease_dir" || fail 'Invalid geodata asset directory'
  requested_identity=$(lease_identity "$lease_owner") || fail 'Invalid geodata lease owner'
  [ -d "$lease_dir" ] && [ ! -L "$lease_dir" ] || fail 'Geodata asset directory is not ready'
  mkdir -p "$LOCK_ROOT" || fail 'Could not create geodata lock directory'
  lease_slot=$ASSET_LOCATION_STORAGE-$ASSET_LOCATION_KEY
  lease_lock=$LOCK_ROOT/$lease_slot.lock
  lease_directory=$LOCK_ROOT/$lease_slot.leases
  lock_acquire "$lease_lock" || fail 'Could not lock geodata assets'
  prune_leases "$lease_directory"
  mkdir -p "$lease_directory" && chmod 700 "$lease_directory" || fail 'Could not prepare geodata lease'
  lease_name=$(printf '%s' "$requested_identity" | tr ':' '-')
  lease_marker=$lease_directory/$lease_name
  lease_temp=$lease_directory/.$lease_name.tmp.$$
  TEMP_PATHS="$lease_temp $TEMP_PATHS"
  PENDING_LEASE_MARKER=$lease_marker
  printf '%s\n' "$requested_identity" > "$lease_temp" && chmod 600 "$lease_temp" && mv "$lease_temp" "$lease_marker" || fail 'Could not acquire geodata lease'
  lock_release "$lease_lock"
  PENDING_LEASE_MARKER=
}

lease_release() {
  lease_dir=$1
  lease_owner=$2
  asset_location "$lease_dir" || fail 'Invalid geodata asset directory'
  requested_identity=$(lease_identity "$lease_owner") || fail 'Invalid geodata lease owner'
  mkdir -p "$LOCK_ROOT" || fail 'Could not create geodata lock directory'
  lease_slot=$ASSET_LOCATION_STORAGE-$ASSET_LOCATION_KEY
  lease_lock=$LOCK_ROOT/$lease_slot.lock
  lease_directory=$LOCK_ROOT/$lease_slot.leases
  lock_acquire "$lease_lock" || fail 'Could not lock geodata assets'
  lease_name=$(printf '%s' "$requested_identity" | tr ':' '-')
  lease_marker=$lease_directory/$lease_name
  rm -f "$lease_marker" || fail 'Could not release geodata lease'
  prune_leases "$lease_directory"
  lock_release "$lease_lock"
}

atomic_json() {
  json_source=$1
  json_target=$2
  json_parent=${json_target%/*}
  [ "$json_parent" != "$json_target" ] || json_parent=.
  mkdir -p "$json_parent"
  json_temp=$json_target.tmp.$$
  cp "$json_source" "$json_temp" && chmod 600 "$json_temp" && mv "$json_temp" "$json_target"
}

# Формат и файл те же, что у event_log. В stdout не пишем под CGI: там это
# тело HTTP-ответа.
progress() {
  progress_log=${EVENT_LOG:-/dev/shm/xray-remnasub/events.log}
  progress_line=$(printf '[%s] [INFO] [geodata] %s' "$(date '+%Y-%m-%d %H:%M:%S')" "$*")
  printf '%s\n' "$progress_line" >> "$progress_log" 2>/dev/null || true
  [ -n "${GATEWAY_INTERFACE:-}" ] || [ -n "${REQUEST_METHOD:-}" ] || printf '%s\n' "$progress_line"
}

# Копирует файл из другого набора, если там тот же URL. Совпадение адреса
# обязательно: иначе подставится geosite другого провайдера.
reuse_asset() {
  reuse_file=$1 reuse_url=$2 reuse_target=$3
  for reuse_dir in "$ASSET_ROOT"/*; do
    [ -d "$reuse_dir" ] || continue
    [ "$reuse_dir" != "$ASSET_DIR" ] || continue
    [ -f "$reuse_dir/$reuse_file" ] && [ -s "$reuse_dir/$reuse_file" ] || continue
    [ -f "$reuse_dir/.metadata.json" ] || continue
    jq -e --arg file "$reuse_file" --arg url "$reuse_url" \
      'any(.assets[]?; .file == $file and .url == $url)' "$reuse_dir/.metadata.json" >/dev/null 2>&1 || continue
    cp "$reuse_dir/$reuse_file" "$reuse_target" 2>/dev/null || continue
    return 0
  done
  return 1
}

sha256_file() {
  openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
}

file_mtime() {
  if command -v stat >/dev/null 2>&1; then
    stat -c %Y "$1"
  elif command -v date >/dev/null 2>&1; then
    date -r "$1" +%s
  else
    busybox stat -c %Y "$1"
  fi
}

cron_parts() {
  CRON_TIMEZONE=
  CRON_EXPRESSION=$1
  case "$CRON_EXPRESSION" in
    TZ=*' '*|CRON_TZ=*' '*)
      cron_prefix=${CRON_EXPRESSION%% *}
      CRON_TIMEZONE=${cron_prefix#*=}
      CRON_EXPRESSION=${CRON_EXPRESSION#* }
      case "$CRON_TIMEZONE" in ''|*[!A-Za-z0-9_+./-]*|*..*) return 1 ;; esac
      ;;
  esac
}

cron_due() {
  due_spec=$1
  due_since=$2
  due_now=$3
  cron_parts "$due_spec" || return 2
  if [ -n "$CRON_TIMEZONE" ]; then
    due_result=$(TZ="$CRON_TIMEZONE" jq -cer -n --arg spec "$CRON_EXPRESSION" --argjson since "$due_since" --argjson now "$due_now" -f "$CRON_FILTER") || return 2
  else
    due_result=$(jq -cer -n --arg spec "$CRON_EXPRESSION" --argjson since "$due_since" --argjson now "$due_now" -f "$CRON_FILTER") || return 2
  fi
  printf '%s' "$due_result" | jq -e '.due == true' >/dev/null 2>&1
}

download_raw() {
  raw_url=$1
  raw_target=$2
  raw_blocks=$3
  raw_timeout=$4
  rm -f "$raw_target"
  if ! (ulimit -f "$raw_blocks"; exec timeout "$raw_timeout" wget -q -T 15 -t 3 -O "$raw_target" "$raw_url"); then
    rm -f "$raw_target"
    return 1
  fi
  [ -s "$raw_target" ] || { rm -f "$raw_target"; return 1; }
}

checksum_value() {
  checksum_file=$1
  checksum_name=$2
  awk -v expected="$checksum_name" '
    {
      digest=tolower($1)
      name=$2
      sub(/^\*/, "", name)
      if (length(digest) == 64 && digest !~ /[^0-9a-f]/ && name == expected) {
        print digest
        exit
      }
    }
  ' "$checksum_file"
}

# Скачивание нужно только для отсутствующего файла, поэтому сравнения с уже
# лежащей копией здесь нет: если файл на месте, сюда не заходят вовсе.
download_default() {
  default_url=$1
  default_file=$2
  default_target=$3
  default_attempt=0
  while [ "$default_attempt" -lt 3 ]; do
    default_attempt=$((default_attempt + 1))
    default_sum=$default_target.sha256sum
    if download_raw "$default_url.sha256sum" "$default_sum" 16 30; then
      default_expected=$(checksum_value "$default_sum" "${default_file##*/}")
      rm -f "$default_sum"
      if [ -n "$default_expected" ] &&
         download_raw "$default_url" "$default_target" "$MAX_FILE_BLOCKS" 120 &&
         [ "$(wc -c < "$default_target")" -le "$MAX_ASSET_BYTES" ] &&
         [ "$(sha256_file "$default_target")" = "$default_expected" ]; then
        return 0
      fi
    fi
    rm -f "$default_target" "$default_target.sha256sum"
  done
  return 1
}

download_custom() {
  custom_url=$1
  custom_target=$2
  download_raw "$custom_url" "$custom_target" "$MAX_FILE_BLOCKS" 120 || return 1
  custom_size=$(wc -c < "$custom_target")
  [ "$custom_size" -le "$MAX_ASSET_BYTES" ] || { rm -f "$custom_target"; return 1; }
}

path_is_safe() {
  safe_root=$1
  safe_relative=$2
  safe_current=$safe_root
  old_ifs=$IFS
  IFS=/
  set -- $safe_relative
  IFS=$old_ifs
  for safe_part do
    safe_current=$safe_current/$safe_part
    [ ! -L "$safe_current" ] || return 1
  done
}

publish_staged() {
  publish_manifest=$1
  publish_backup=$2
  publish_records=$3
  : > "$publish_records"
  while IFS="$(printf '\t')" read -r publish_relative publish_stage; do
    [ -n "$publish_relative" ] || continue
    publish_target=$ASSET_DIR/$publish_relative
    publish_parent=${publish_target%/*}
    publish_backup_file=$publish_backup/$publish_relative
    publish_backup_parent=${publish_backup_file%/*}
    path_is_safe "$ASSET_DIR" "$publish_relative" || return 1
    mkdir -p "$publish_parent" "$publish_backup_parent" || return 1
    path_is_safe "$ASSET_DIR" "$publish_relative" || return 1
    publish_had=0
    if [ -e "$publish_target" ]; then
      publish_had=1
    fi
    printf '%s\t%s\n' "$publish_relative" "$publish_had" >> "$publish_records" || return 1
    if [ "$publish_had" = 1 ] && ! mv "$publish_target" "$publish_backup_file"; then
      return 1
    fi
    if ! mv "$publish_stage" "$publish_target" || ! chmod 600 "$publish_target"; then
      return 1
    fi
  done < "$publish_manifest"
}

rollback_published() {
  rollback_backup=$1
  rollback_records=$2
  rollback_reverse=$rollback_records.reverse
  rollback_failed=0
  awk '{line[NR]=$0} END {for (i=NR;i>0;i--) print line[i]}' "$rollback_records" > "$rollback_reverse" || return 1
  while IFS="$(printf '\t')" read -r rollback_relative rollback_had; do
    [ -n "$rollback_relative" ] || continue
    rollback_target=$ASSET_DIR/$rollback_relative
    rollback_backup_file=$rollback_backup/$rollback_relative
    case "$rollback_had" in
      0)
        rm -f "$rollback_target" || rollback_failed=1
        ;;
      1)
        if [ -e "$rollback_backup_file" ] || [ -L "$rollback_backup_file" ]; then
          rollback_parent=${rollback_target%/*}
          mkdir -p "$rollback_parent" || rollback_failed=1
          if ! rm -f "$rollback_target" || ! mv "$rollback_backup_file" "$rollback_target"; then
            rollback_failed=1
          fi
        elif [ ! -e "$rollback_target" ] && [ ! -L "$rollback_target" ]; then
          rollback_failed=1
        fi
        ;;
      *) rollback_failed=1 ;;
    esac
  done < "$rollback_reverse"
  rm -f "$rollback_reverse" || rollback_failed=1
  [ "$rollback_failed" = 0 ]
}

prepare() {
  SELECTED_JSON=$1
  OVERLAY_JSON=$2
  METADATA_JSON=$3
  STORAGE=$4

  [ -s "$SELECTED_JSON" ] || fail 'Selected Xray configuration is missing'
  jq -e 'type == "object"' "$SELECTED_JSON" >/dev/null 2>&1 || fail 'Selected Xray configuration must be an object'
  [ -s "$CRON_FILTER" ] || fail 'Geodata cron helper is missing'
  case "$STORAGE" in
    memory) ASSET_ROOT=$MEMORY_ROOT ;;
    persistent) ASSET_ROOT=$PERSISTENT_ROOT ;;
    *) fail 'Geodata storage must be memory or persistent' ;;
  esac

  mkdir -p "$WORK_ROOT" "$LOCK_ROOT"
  work_dir=$WORK_ROOT/geodata-prepare.$$
  mkdir "$work_dir" || fail 'Could not create geodata work directory'
  TEMP_PATHS="$work_dir $TEMP_PATHS"
  manifest_json=$work_dir/manifest.json
  assets_json=$work_dir/assets.json
  warnings_jsonl=$work_dir/warnings.jsonl
  publish_manifest=$work_dir/publish.tsv
  : > "$warnings_jsonl"
  : > "$publish_manifest"

  jq -e --argjson max_assets "$MAX_ASSETS" '
    def ascii_space:
      . == 9 or . == 10 or . == 11 or . == 12 or . == 13 or . == 32;
    def safe_path_char:
      (. >= 48 and . <= 57) or (. >= 65 and . <= 90) or (. >= 97 and . <= 122) or
      . == 45 or . == 46 or . == 95;
    def safe_path_segment:
      type == "string" and length > 0 and (explode | all(.[]; safe_path_char));
    def safe_path:
      type == "string" and length > 0 and length <= 512 and
      (startswith("/") | not) and (contains("\\") | not) and
      (split("/") | all(.[]; . != "" and . != "." and . != ".." and safe_path_segment));
    def safe_url:
      type == "string" and length > 0 and length <= 2048 and
      startswith("https://") and
      ((explode | any(.[]; ascii_space)) | not) and
      (.[8:] | split("/")[0] | split("?")[0] | split("#")[0] | length > 0);
    . as $config |
    # Ссылки на геобазы могут стоять не только в routing.rules, но и в
    # dns.servers.domains и expectIPs, поэтому ищем по всей конфигурации.
    (del(.geodata) | [.. | strings] | any(
       startswith("geoip:") or startswith("geosite:") or
       startswith("ext:") or startswith("ext-ip:"))) as $needs_geodata |
    if $needs_geodata | not then
      # Ссылок на геобазы нет — своя секция подписки тоже не нужна.
      {generated:false,geodata:null,added_outbounds:[]}
    elif has("geodata") and .geodata != null then
      {generated:false,geodata:.geodata,added_outbounds:[]}
    else
      ([.outbounds[]?.tag? | select(type == "string")]) as $used |
      (any(.outbounds[]?; .tag? == "direct" and (((.protocol? // "") | ascii_downcase) == "freedom"))) as $direct |
      ([.outbounds[]? | select(((.protocol? // "") | ascii_downcase) == "freedom" and (.tag? | type) == "string" and (.tag | length) > 0) | .tag][0]) as $freedom |
      (if $direct then "direct"
       elif $freedom != null then $freedom
       else first(range(0; 1000) as $index |
         (if $index == 0 then "xray-remnasub-geodata-direct" else "xray-remnasub-geodata-direct-\($index)" end) as $tag |
         select(($used | index($tag)) == null) | $tag)
       end) as $outbound |
      {generated:true,
       geodata:{cron:"0 4 * * *",assets:[
         {url:"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat",file:"geoip.dat"},
         {url:"https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat",file:"geosite.dat"}
       ],outbound:$outbound},
       added_outbounds:(if ($used | index($outbound)) == null then [{tag:$outbound,protocol:"freedom"}] else [] end)}
    end |
    if .geodata != null and (.geodata | type) != "object" then error("geodata must be an object or null") else . end |
    (.geodata.assets // []) as $assets |
    if ($assets | type) != "array" then error("geodata.assets must be an array") else . end |
    if ($assets | length) > $max_assets then error("too many geodata assets") else . end |
    if all($assets[]; type == "object" and (.url | safe_url) and (.file | safe_path)) | not
      then error("invalid geodata asset URL or file") else . end |
    if ([$assets[].file] | length) != ([$assets[].file] | unique | length)
      then error("duplicate geodata asset file") else . end |
    .assets = $assets |
    if .geodata != null and ((.geodata.cron // "") | type) != "string"
      then error("geodata cron must be a string") else . end |
    if .geodata != null and ((.geodata.outbound // "") | type) != "string"
      then error("geodata outbound must be a string") else . end |
    (.geodata.outbound // "") as $geodata_outbound |
    if (.generated | not) and ($assets | length) > 0 and ((.geodata.cron // "") | length) > 0 and ($geodata_outbound | length) > 0 and
       (any($config.outbounds[]?; .tag? == $geodata_outbound) | not)
      then error("geodata outbound does not exist") else . end
  ' "$SELECTED_JSON" > "$manifest_json" || fail 'Geodata configuration is invalid'

  jq -cS '.assets | sort_by(.file, .url)' "$manifest_json" > "$assets_json"
  ASSET_KEY=$(openssl dgst -sha256 "$assets_json" 2>/dev/null | awk '{print $NF}')
  case "$ASSET_KEY" in ''|*[!0-9a-f]* ) fail 'Could not fingerprint geodata assets' ;; esac
  [ "${#ASSET_KEY}" -eq 64 ] || fail 'Could not fingerprint geodata assets'
  ASSET_DIR=$ASSET_ROOT/$ASSET_KEY

  global_lock=$LOCK_ROOT/global.lock
  if ! lock_acquire "$global_lock"; then
    if [ "${PREPARE_REQUIRE_FREE:-0}" = 1 ]; then
      printf 'Geodata storage is currently busy\n' >&2
      exit 75
    fi
    fail 'Could not lock geodata storage'
  fi
  mkdir -p "$ASSET_ROOT" "$ASSET_DIR" || fail 'Could not create geodata storage'
  chmod 700 "$ASSET_ROOT" "$ASSET_DIR" 2>/dev/null || true
  lock_release "$global_lock"

  asset_slot=$STORAGE-$ASSET_KEY
  asset_lock=$LOCK_ROOT/$asset_slot.lock
  if ! lock_acquire "$asset_lock"; then
    if [ "${PREPARE_REQUIRE_FREE:-0}" = 1 ]; then
      printf 'Geodata assets are currently busy\n' >&2
      exit 75
    fi
    fail 'Could not lock geodata assets'
  fi
  lease_directory=$LOCK_ROOT/$asset_slot.leases
  prune_leases "$lease_directory"
  if [ "$ACTIVE_LEASES" -gt 0 ] && [ "${PREPARE_REQUIRE_FREE:-0}" = 1 ]; then
    printf 'Geodata assets are currently in use\n' >&2
    exit 75
  fi
  ASSET_LEASED=0
  [ "$ACTIVE_LEASES" -eq 0 ] || ASSET_LEASED=1
  if [ "$ASSET_LEASED" = 0 ]; then
    for recovery_backup in "$ASSET_DIR"/.backup.*; do
      [ -d "$recovery_backup" ] || continue
      recovery_records=$recovery_backup/.records.tsv
      if [ -f "$recovery_backup/.committed" ]; then
        :
      elif [ -s "$recovery_records" ]; then
        rollback_published "$recovery_backup" "$recovery_records" || fail "Could not recover an interrupted geodata transaction: $recovery_backup"
      fi
      rm -rf "$recovery_backup" || fail "Could not clear a recovered geodata transaction: $recovery_backup"
    done
    for recovery_stage in "$ASSET_DIR"/.staging.*; do
      [ -d "$recovery_stage" ] || continue
      rm -rf "$recovery_stage" || fail "Could not clear an interrupted geodata download: $recovery_stage"
    done
    stage_dir=$ASSET_DIR/.staging.$$
    backup_dir=$ASSET_DIR/.backup.$$
  else
    stage_dir=$work_dir/staging
    backup_dir=$work_dir/backup
  fi
  mkdir "$stage_dir" "$backup_dir" || fail 'Could not stage geodata assets'
  records_file=$backup_dir/.records.tsv
  TEMP_PATHS="$stage_dir $backup_dir $TEMP_PATHS"

  # Cron проверяется, но не исполняется: расписание принадлежит Xray. Контейнер
  # только создаёт недостающие файлы — без них infra/conf/geodata.go роняет
  # разбор конфигурации на StatAsset.
  effective_cron=$(jq -r 'if .geodata == null then "" else .geodata.cron // "" end' "$manifest_json")
  jq -e 'if .geodata == null then true else ((.geodata.cron // "") | type == "string") end' "$manifest_json" >/dev/null || fail 'Geodata cron must be a string'
  now_epoch=${GEODATA_NOW:-$(date +%s)}
  case "$now_epoch" in ''|*[!0-9]*) fail 'Current time is invalid' ;; esac
  if [ -n "$effective_cron" ]; then
    cron_due "$effective_cron" "$now_epoch" "$now_epoch" >/dev/null 2>&1 || cron_validation=$?
    if [ "${cron_validation:-0}" -gt 1 ]; then fail 'Geodata cron is invalid'; fi
  fi

  generated=$(jq -r '.generated' "$manifest_json")
  if [ "$(jq -r '.geodata == null' "$manifest_json")" = true ]; then
    progress 'configuration does not reference geoip or geosite; no assets needed'
  fi
  while IFS="$(printf '\t')" read -r asset_file asset_url; do
    asset_target=$ASSET_DIR/$asset_file
    path_is_safe "$ASSET_DIR" "$asset_file" || fail "Unsafe geodata asset target: $asset_file"
    if [ -f "$asset_target" ] && [ ! -L "$asset_target" ]; then
      # Файл на месте — дальше он под ответственностью Xray.
      [ -s "$asset_target" ] && continue
    elif [ -e "$asset_target" ] || [ -L "$asset_target" ]; then
      fail "Geodata asset is not a regular file: $asset_file"
    fi
    [ "$ASSET_LEASED" = 0 ] || fail "Geodata asset is missing while this asset set is in use: $asset_file"
    asset_stage=$stage_dir/$asset_file
    mkdir -p "${asset_stage%/*}"
    # У каждого набора свой файл: обновляет их Xray независимо, общий inode
    # был бы опасен.
    if reuse_asset "$asset_file" "$asset_url" "$asset_stage"; then
      progress "$asset_file reused from an existing asset set"
      printf '%s\t%s\n' "$asset_file" "$asset_stage" >> "$publish_manifest"
      continue
    fi
    progress "downloading $asset_file"
    is_default=0
    case "$asset_file:$asset_url" in
      geoip.dat:https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat|geosite.dat:https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat) is_default=1 ;;
    esac
    if [ "$is_default" = 1 ]; then
      download_default "$asset_url" "$asset_file" "$asset_stage" || fail "Could not download required geodata asset: $asset_file"
    else
      download_custom "$asset_url" "$asset_stage" || fail "Could not download required geodata asset: $asset_file"
    fi
    progress "$asset_file downloaded, $(wc -c < "$asset_stage" 2>/dev/null || printf 0) bytes"
    printf '%s\t%s\n' "$asset_file" "$asset_stage" >> "$publish_manifest"
  done <<EOF
$(jq -r '.assets[] | [.file,.url] | @tsv' "$manifest_json")
EOF

  # Список адресов рядом с файлами: имя каталога — хеш набора, по нему нельзя
  # понять, какой URL дал файл.
  assets_record_tmp=$work_dir/assets-record.json
  if cp "$assets_json" "$assets_record_tmp" 2>/dev/null; then
    chmod 600 "$assets_record_tmp" 2>/dev/null || true
    jq -n --slurpfile assets "$assets_record_tmp" '{assets:$assets[0]}' > "$assets_record_tmp.wrapped" 2>/dev/null &&
      mv "$assets_record_tmp.wrapped" "$ASSET_DIR/.metadata.json" 2>/dev/null || true
  fi

  overlay_temp=$work_dir/overlay.json
  jq -n --arg asset_dir "$ASSET_DIR" --slurpfile manifest "$manifest_json" '
    {env:{"xray.location.asset":$asset_dir}} +
    (if $manifest[0].geodata == null then {} else {geodata:$manifest[0].geodata} end) +
    (if ($manifest[0].added_outbounds | length) > 0 then {outbounds:$manifest[0].added_outbounds} else {} end)
  ' > "$overlay_temp"

  if [ -s "$publish_manifest" ]; then
    ROLLBACK_ACTIVE=1
    ROLLBACK_BACKUP=$backup_dir
    ROLLBACK_RECORDS=$records_file
    if ! publish_staged "$publish_manifest" "$backup_dir" "$records_file"; then
      if [ ! -s "$records_file" ] || rollback_published "$backup_dir" "$records_file"; then
        ROLLBACK_ACTIVE=0
        fail 'Could not publish geodata assets'
      fi
      fail "Could not publish or roll back geodata assets; recovery data was kept in $backup_dir"
    fi
  fi
  if [ -s "$records_file" ]; then
    validation_dir=$work_dir/validation
    validation_log=$work_dir/validation.log
    mkdir "$validation_dir"
    cp "$SELECTED_JSON" "$validation_dir/10-subscription.json"
    cp "$overlay_temp" "$validation_dir/70-container-geodata-tail.json"
    printf '%s\n' '{"log":{"loglevel":"none"}}' > "$validation_dir/80-container-log.json"
    if ! XRAY_LOCATION_ASSET="$ASSET_DIR" xray run -test -confdir "$validation_dir" > "$validation_log" 2>&1; then
      validation_error=$(tail -n 10 "$validation_log" 2>/dev/null | tr '\r\n' '  ' | head -c 2048)
      if rollback_published "$backup_dir" "$records_file"; then
        ROLLBACK_ACTIVE=0
        fail "Prepared geodata failed Xray validation: ${validation_error:-unknown error}"
      fi
      fail "Prepared geodata failed Xray validation and rollback; recovery data was kept in $backup_dir: ${validation_error:-unknown error}"
    fi
  fi
  assets_metadata=$work_dir/assets-metadata.jsonl
  : > "$assets_metadata"
  while IFS= read -r asset_file; do
    [ -n "$asset_file" ] || continue
    asset_target=$ASSET_DIR/$asset_file
    [ -f "$asset_target" ] && [ -s "$asset_target" ] || fail "Prepared geodata asset is missing: $asset_file"
    # GetAssetLocation ищет файл в xray.location.asset, затем в системных
    # путях, и туда же пишет обновления. Посторонняя копия — повод предупредить.
    for asset_shadow in /usr/local/share/xray /usr/share/xray /opt/share/xray; do
      [ -e "$asset_shadow/$asset_file" ] || continue
      jq -cn --arg file "$asset_file" --arg message "A copy in $asset_shadow shadows the selected geodata storage" \
        '{file:$file,message:$message}' >> "$warnings_jsonl"
    done
    asset_size=$(wc -c < "$asset_target")
    asset_mtime=$(file_mtime "$asset_target")
    jq -cn --arg file "$asset_file" --argjson size "$asset_size" --argjson mtime "$asset_mtime" '{file:$file,size:$size,mtime:$mtime}' >> "$assets_metadata"
  done <<EOF
$(jq -r '.[].file' "$assets_json")
EOF

  warnings=$(jq -s . "$warnings_jsonl")
  assets=$(jq -s . "$assets_metadata")
  metadata_temp=$work_dir/metadata.json
  jq -n \
    --arg storage "$STORAGE" \
    --arg asset_key "$ASSET_KEY" \
    --arg asset_dir "$ASSET_DIR" \
    --arg cron "$effective_cron" \
    --argjson generated "$generated" \
    --argjson prepared_at "$now_epoch" \
    --argjson assets "$assets" \
    --argjson warnings "$warnings" \
    '{version:1,storage:$storage,asset_key:$asset_key,asset_dir:$asset_dir,env:{"xray.location.asset":$asset_dir},generated_defaults:$generated,cron:$cron,prepared_at:$prepared_at,assets:$assets,warnings:$warnings}' > "$metadata_temp"
  atomic_json "$overlay_temp" "$OVERLAY_JSON" || fail 'Could not write geodata overlay'
  atomic_json "$metadata_temp" "$METADATA_JSON" || fail 'Could not write geodata metadata'
  : > "$backup_dir/.committed" || fail 'Could not commit geodata transaction'
  ROLLBACK_ACTIVE=0
  rm -rf "$backup_dir" "$stage_dir" 2>/dev/null || true
  TEMP_PATHS=$(printf '%s' "$TEMP_PATHS" | awk -v stage="$stage_dir" -v backup="$backup_dir" '{for(i=1;i<=NF;i++) if($i!=stage && $i!=backup) printf "%s ",$i}')
  lock_release "$asset_lock"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

case "${1:-}" in
  prepare|prepare-probe)
    [ "$#" -eq 5 ] || fail "Usage: geodata.sh $1 SELECTED_JSON OVERLAY_JSON METADATA_JSON memory|persistent"
    prepare "$2" "$3" "$4" "$5"
    ;;
  prepare-start)
    [ "$#" -eq 5 ] || fail 'Usage: geodata.sh prepare-start SELECTED_JSON OVERLAY_JSON METADATA_JSON memory|persistent'
    PREPARE_REQUIRE_FREE=1
    LOCK_MAX_ATTEMPTS=${GEODATA_LOCK_MAX_ATTEMPTS:-60}
    prepare "$2" "$3" "$4" "$5"
    ;;
  lease-acquire)
    [ "$#" -eq 3 ] || fail 'Usage: geodata.sh lease-acquire ASSET_DIR OWNER_PID'
    lease_acquire "$2" "$3"
    ;;
  lease-release)
    [ "$#" -eq 3 ] || fail 'Usage: geodata.sh lease-release ASSET_DIR OWNER_PID'
    lease_release "$2" "$3"
    ;;
  *) fail 'Usage: geodata.sh prepare|prepare-probe|prepare-start SELECTED_JSON OVERLAY_JSON METADATA_JSON memory|persistent, or geodata.sh lease-acquire|lease-release ASSET_DIR OWNER_PID' ;;
esac
