#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/install-layout.sh"
fixture="$(mktemp -d)"
trap 'rm -rf -- "$fixture"' EXIT

expect_rejected() {
  if "$@" >"$fixture/rejection" 2>&1; then
    echo "Expected rejection: $*" >&2
    exit 1
  fi
}

SERVICE_NAME=chroot-layout-test
layout_component=redis
PREFIX=/home/jarmaster/run/components/test
DATA_DIR=/home/jarmaster/run/data/test
CONF_DIR=/home/jarmaster/run/conf/test/conf
CREDENTIALS=/home/jarmaster/run/conf/test/credentials
layout_check_paths
saved_prefix="$PREFIX"
PREFIX=/home
expect_rejected layout_check_paths
PREFIX="$saved_prefix"
DATA_DIR="$PREFIX/data"
expect_rejected layout_check_paths
DATA_DIR=/home/jarmaster/run/data/test
CREDENTIALS="$DATA_DIR/password"
expect_rejected layout_check_paths
CREDENTIALS=/home/jarmaster/run/conf/test/credentials
PREFIX='/home/jarmaster/../elsewhere'
expect_rejected layout_check_paths
PREFIX="$saved_prefix"
ln -s /home/jarmaster "$fixture/link"
expect_rejected layout_check_path "$fixture/link/component"

# These functions simulate systemctl output; no service is stopped or started.
test_properties='LoadState=not-found'
systemctl() { printf '%s\n' "$test_properties"; }
layout_check_service
test_properties="LoadState=loaded
ExecStart={ path=$PREFIX/bin/chroot-layout-test-run ; argv[]=$PREFIX/bin/chroot-layout-test-run ; }
ProtectHome=no"
layout_check_service
test_properties="$test_properties
ReadOnlyPaths=/home"
expect_rejected layout_check_service
test_properties="LoadState=loaded
ExecStart={ path=/opt/other/bin/run ; argv[]=$PREFIX/bin/run ; }"
expect_rejected layout_check_service
test_properties="LoadState=loaded
ExecStart={ path=$PREFIX/bin/chroot-layout-test-run ; }
ProtectHome=yes"
expect_rejected layout_check_service

# Record verification is independent of the real uid; mock only stat's owner
# result so this parser test also runs for non-root developers.
stat() {
  if [[ "$1" == -c && "$2" == %u ]]; then printf '0\n'; else command stat "$@"; fi
}
PREFIX="$fixture/runtime"
DATA_DIR="$fixture/data"
CONF_DIR="$fixture/conf/settings"
CREDENTIALS="$fixture/conf/credentials"
mkdir -p "$PREFIX" "$DATA_DIR" "$CONF_DIR"
printf 'keep me\n' > "$DATA_DIR/sentinel"
layout_write_record
layout_verify_record
rmdir "$PREFIX"
layout_verify_record
mkdir "$PREFIX"
saved_data="$DATA_DIR"
DATA_DIR="$fixture/different-data"
expect_rejected layout_verify_record
DATA_DIR="$saved_data"
printf 'VERSION=1\n' >> "$(layout_record_path)"
expect_rejected layout_verify_record
layout_write_record
chmod 0644 "$(layout_record_path)"
expect_rejected layout_verify_record
chmod 0600 "$(layout_record_path)"
rm "$(layout_record_path)"
ln -s "$fixture/not-a-record" "$(layout_record_path)"
expect_rejected layout_verify_record
rm "$(layout_record_path)"
layout_write_record
[[ -f "$DATA_DIR/sentinel" ]] || { echo 'persistent data changed' >&2; exit 1; }

# Test persistent label rules without touching the machine's SELinux policy.
rules=''
rule_added=''
semanage() {
  if [[ "$2" == -l ]]; then printf '%s\n' "$rules"; else rule_added="$*"; fi
}
pattern="$(sed 's/[.]/\\&/g' <<< "$PREFIX")(/.*)?"
rules="$pattern all files system_u:object_r:usr_t:s0"
layout_rule "$PREFIX" usr_t
[[ -z "$rule_added" ]]
rules="$pattern all files system_u:object_r:user_home_t:s0"
expect_rejected layout_rule "$PREFIX" usr_t
rules=''
layout_rule "$PREFIX" usr_t
[[ "$rule_added" == *'-a -t usr_t'* ]]

# Relabel only replaced runtime files, never recursively walk historical data.
restore_calls=''
restorecon() { restore_calls="$restore_calls|$*"; }
matchpathcon() { return 0; }
mkdir -p "$PREFIX/bin"
layout_selinux=1
layout_apply
layout_apply
[[ "$restore_calls" == *"-RF $PREFIX"* ]]
[[ "$restore_calls" != *"-RF $DATA_DIR"* ]]
count="${restore_calls//[^|]/}"
[[ "${#count}" == 7 ]] # One runtime relabel; three persistent paths each time.
restorecon() { return 1; }
expect_rejected layout_apply
printf 'install layout tests passed\n'

