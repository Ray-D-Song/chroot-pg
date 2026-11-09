#!/usr/bin/env bash
# Sourced by install/uninstall. Keep this file identical in all chroot bundles.
# No policy or filesystem-wide permission changes are made.
layout_keys=(PREFIX DATA_DIR CONF_DIR CERTS_DIR WWW_DIR LOG_DIR CREDENTIALS)

layout_fail() { echo "Install layout: $*" >&2; return 1; }

# Keep the record with persistent configuration so a later --purge-data can
# still validate paths after ordinary uninstall has removed the runtime.
layout_record_path() {
  local parent
  if [[ "$layout_component" == nginx ]]; then parent="$(dirname "$CONF_DIR")";
  else parent="$(dirname "$CREDENTIALS")"; fi
  printf '%s/.install-layout-%s' "$parent" "$SERVICE_NAME"
}

layout_check_path() {
  local path="$1" part
  [[ "$path" =~ ^/[a-zA-Z0-9_./-]+$ && "$path" == "$(realpath -m -- "$path")" ]] \
    || { layout_fail "unsafe or non-canonical path: $path"; return 1; }
  case "$path" in /|/home|/root|/opt|/var|/var/lib|/var/log|/etc|/usr|/run|/tmp|/srv)
    layout_fail "refusing broad directory: $path"; return 1 ;;
  esac
  part="$path"
  while [[ "$part" != / ]]; do
    [[ ! -L "$part" ]] || { layout_fail "symlink in managed path: $part"; return 1; }
    part="$(dirname "$part")"
  done
}

layout_check_paths() {
  case "$layout_component" in
    mysql|pg) layout_keys=(PREFIX DATA_DIR CREDENTIALS) ;;
    redis) layout_keys=(PREFIX DATA_DIR CONF_DIR CREDENTIALS) ;;
    nginx) layout_keys=(PREFIX CONF_DIR CERTS_DIR WWW_DIR LOG_DIR) ;;
    rabbitmq) layout_keys=(PREFIX DATA_DIR CONF_DIR LOG_DIR CREDENTIALS) ;;
    *) layout_fail "unknown component: $layout_component"; return 1 ;;
  esac
  local key path other other_path
  [[ "$SERVICE_NAME" =~ ^[a-zA-Z0-9_.@-]+$ ]] || { layout_fail 'invalid service name'; return 1; }
  for key in "${layout_keys[@]}"; do
    path="${!key-}"
    [[ -n "$path" ]] || continue
    layout_check_path "$path" || return 1
    for other in "${layout_keys[@]}"; do
      [[ "$other" != "$key" ]] || continue
      other_path="${!other-}"
      [[ -n "$other_path" ]] || continue
      if [[ "$path" == "$other_path" || "$path" == "$other_path/"* ]]; then
        layout_fail "overlapping managed paths: $key=$path and $other=$other_path"; return 1
      fi
    done
  done
}

layout_check_parent() {
  local path="$1" owner mode
  while [[ ! -e "$path" ]]; do path="$(dirname "$path")"; done
  while :; do
    owner="$(stat -c %u -- "$path")"
    mode="$(stat -c %a -- "$path")"
    [[ "$owner" == 0 && $((8#$mode & 0022)) == 0 && ! -L "$path" ]] \
      || { layout_fail "root-owned, non-writable dedicated parent required: $path"; return 1; }
    [[ "$path" != / ]] || break
    path="$(dirname "$path")"
  done
}

layout_check_service() {
  local properties executable protect
  properties="$(systemctl show "$SERVICE_NAME.service" --property=LoadState,ExecStart,ProtectHome,InaccessiblePaths,ReadOnlyPaths)" || return 1
  [[ "$properties" != *'LoadState=not-found'* ]] || return 0
  [[ "$properties" == *'LoadState=loaded'* ]] || { layout_fail "cannot inspect service $SERVICE_NAME"; return 1; }
  executable="$(sed -n 's/.*path=\([^ ;}]*\).*/\1/p' <<< "$properties")"
  [[ "$executable" == "$PREFIX/bin/"* ]] \
    || { layout_fail "service $SERVICE_NAME already belongs to another prefix: $executable"; return 1; }
  local home_paths=0 path_key
  for path_key in "${layout_keys[@]}"; do
    if [[ "${!path_key-}" == /home/* ]]; then home_paths=1; fi
  done
  if [[ "$home_paths" == 1 ]]; then
    protect="$(sed -n 's/^ProtectHome=//p' <<< "$properties")"
    [[ -z "$protect" || "$protect" == no || "$protect" == false ]] \
      || { layout_fail "ProtectHome=$protect prevents this installation"; return 1; }
    local restriction restricted key path
    while IFS='=' read -r restriction restricted; do
      [[ "$restriction" == InaccessiblePaths || "$restriction" == ReadOnlyPaths ]] || continue
      for path in $restricted; do
        path="${path#-}"; path="${path#+}"
        for key in "${layout_keys[@]}"; do
          [[ -n "${!key-}" ]] || continue
          [[ "$path" != / && "${!key}" != "$path" && "${!key}" != "$path/"* && "$path" != "${!key}/"* ]] \
            || { layout_fail "$restriction=$path restricts $key"; return 1; }
        done
      done
    done <<< "$properties"
  fi
}

layout_rule() {
  local path="$1" type="$2" pattern current line last
  # Paths are restricted to ASCII path characters by layout_check_path.
  pattern="$(sed 's/[.]/\\&/g' <<< "$path")"
  pattern="$pattern(/.*)?"
  current="$(semanage fcontext -l -C)" || return 1
  while IFS= read -r line; do
    [[ "${line%% *}" == "$pattern" ]] || continue
    last="${line##* }"
    [[ "$last" == *":$type:"* ]] && return 0
    layout_fail "conflicting SELinux rule: $line"; return 1
  done <<< "$current"
  semanage fcontext -a -t "$type" "$pattern"
}

layout_selinux_enabled() {
  if command -v getenforce >/dev/null 2>&1; then
    local mode
    mode="$(getenforce)" || return 2
    case "$mode" in Enforcing|Permissive) return 0 ;; Disabled) return 1 ;; *) return 2 ;; esac
  fi
  [[ ! -e /sys/fs/selinux/enforce ]] || return 2
  return 1
}

layout_prepare() {
  layout_check_paths || return 1
  layout_check_path "$PREFIX/bin" || return 1
  layout_check_mounts || return 1
  layout_home=0
  local key path probe options fs command status
  for key in "${layout_keys[@]}"; do
    path="${!key-}"
    [[ -n "$path" ]] || continue
    if [[ "$path" == /home/* ]]; then layout_home=1; fi
    # Component-owned data leaves are allowed; executable parents must be root-owned.
    layout_check_parent "$(dirname "$path")" || return 1
  done
  if [[ -e "$PREFIX" ]]; then layout_check_parent "$PREFIX" || return 1; fi
  layout_check_service || return 1
  if [[ -e "$(layout_record_path)" || -L "$(layout_record_path)" ]]; then layout_verify_record || return 1; fi
  probe="$PREFIX"
  while [[ ! -e "$probe" ]]; do probe="$(dirname "$probe")"; done
  fs="$(findmnt -n -o FSTYPE --target "$probe")" || return 1
  options="$(findmnt -n -o OPTIONS --target "$probe")" || return 1
  case "$fs" in nfs|nfs4|cifs) layout_fail "local executable filesystem required: $fs"; return 1 ;; esac
  case ",$options," in *,noexec,*|*,ro,*|*,context=*) layout_fail "unsupported executable mount options: $options"; return 1 ;; esac
  layout_selinux=0
  [[ "$layout_home" == 1 ]] || return 0
  if layout_selinux_enabled; then
    layout_selinux=1
  else
    status=$?
    [[ "$status" == 1 ]] || { layout_fail 'cannot determine SELinux state'; return 1; }
  fi
  [[ "$layout_selinux" == 1 ]] || return 0
  for command in semanage restorecon matchpathcon; do
    command -v "$command" >/dev/null 2>&1 \
      || { layout_fail "SELinux requires $command; install policycoreutils and policycoreutils-python-utils (policycoreutils-python on CentOS 7)"; return 1; }
  done
  layout_rule "$PREFIX" usr_t || return 1
  layout_rule "$PREFIX/bin" bin_t || return 1
  if [[ "$layout_component" != nginx ]]; then
    layout_rule "$(dirname "$CREDENTIALS")" etc_t || return 1
  fi
  for key in "${layout_keys[@]}"; do
    path="${!key-}"
    [[ -n "$path" && "$key" != PREFIX ]] || continue
    local reference label
    case "$key" in
      DATA_DIR|WWW_DIR) reference="/var/lib/chroot-$layout_component" ;;
      LOG_DIR) reference="/var/log/chroot-$layout_component" ;;
      *) reference="/etc/chroot-$layout_component" ;;
    esac
    label="$(matchpathcon -n "$reference")" || return 1
    label="${label#*:}"; label="${label#*:}"; label="${label%%:*}"
    layout_rule "$path" "$label" || return 1
  done
}

# Run after rootfs replacement, before initdb/mysqld or systemd can execute it.
layout_apply() {
  [[ "${layout_selinux:-0}" == 1 ]] || return 0
  if [[ "${layout_runtime_labeled:-0}" == 0 ]]; then
    restorecon -RF "$PREFIX" || return 1
    layout_runtime_labeled=1
  fi
  if [[ "$layout_component" != nginx ]]; then
    restorecon -F "$(dirname "$CREDENTIALS")" || return 1
  fi
  local key path
  for key in "${layout_keys[@]}"; do
    path="${!key-}"
    [[ -n "$path" && "$key" != PREFIX ]] || continue
    [[ ! -e "$path" ]] || { restorecon -F "$path" && matchpathcon -V "$path"; } || return 1
  done
  matchpathcon -V "$PREFIX/bin/chroot-$layout_component-run"
}

layout_write_record() {
  local record key
  record="$(layout_record_path)"
  [[ ! -L "$record" ]] || { layout_fail "symlink installation record: $record"; return 1; }
  local temporary
  temporary="$(mktemp "$record.XXXXXX")" || return 1
  chmod 0600 "$temporary"
  {
    printf 'VERSION=1\nCOMPONENT=%s\nSERVICE_NAME=%s\n' "$layout_component" "$SERVICE_NAME"
    for key in "${layout_keys[@]}"; do printf '%s=%s\n' "$key" "${!key-}"; done
  } > "$temporary"
  mv -f -- "$temporary" "$record"
}

layout_verify_record() {
  local record key value mode
  record="$(layout_record_path)"
  [[ -f "$record" && ! -L "$record" && "$(stat -c %u "$record")" == 0 ]] \
    || { layout_fail 'missing or untrusted installation record'; return 1; }
  mode="$(stat -c %a "$record")"
  [[ $((8#$mode & 0077)) == 0 ]] || { layout_fail 'installation record is not root-only'; return 1; }
  local -A seen=()
  while IFS='=' read -r key value; do
    [[ -n "$key" && -z "${seen[$key]-}" ]] || { layout_fail 'invalid installation record'; return 1; }
    seen[$key]=1
    case "$key" in
      VERSION) [[ "$value" == 1 ]] || return 1 ;;
      COMPONENT) [[ "$value" == "$layout_component" ]] || return 1 ;;
      SERVICE_NAME) [[ "$value" == "$SERVICE_NAME" ]] || return 1 ;;
      PREFIX|DATA_DIR|CONF_DIR|CERTS_DIR|WWW_DIR|LOG_DIR|CREDENTIALS)
        [[ "$value" == "${!key-}" ]] || { layout_fail "recorded path differs: $key"; return 1; } ;;
      *) layout_fail "unknown record key: $key"; return 1 ;;
    esac
  done < "$record"
  for key in VERSION COMPONENT SERVICE_NAME "${layout_keys[@]}"; do
    [[ "${seen[$key]-}" == 1 ]] || { layout_fail "missing record key: $key"; return 1; }
  done
}

layout_finish() {
  layout_write_record
}

layout_validate_uninstall() {
  layout_check_paths || return 1
  layout_check_parent "$PREFIX" || return 1
  layout_check_parent "$(dirname "$(layout_record_path)")" || return 1
  layout_verify_record || return 1
  layout_check_service || return 1
  layout_check_mounts
}

layout_check_mounts() {
  # Refuse recursive deletion while anything is still mounted below the prefix.
  local mountpoint mounts
  mounts="$(findmnt -rn -o TARGET)" || return 1
  while IFS= read -r mountpoint; do
    [[ "$mountpoint" != "$PREFIX" && "$mountpoint" != "$PREFIX/"* ]] \
      || { layout_fail "mounted content remains below prefix: $mountpoint"; return 1; }
  done <<< "$mounts"
}

