#!/usr/bin/env bash
set -euo pipefail

BUNDLE="${1:?usage: backup-hosts-test.sh <bundle.tar.gz>}"
WORK_DIR="$(mktemp -d /tmp/chroot-pg-hosts-test.XXXXXX)"
PREFIX="/opt/chroot-pg-hosts-test-$$"
TEST_HOST='pg-headless-test'
TEST_IP='203.0.113.1'
PACKAGE_DIR=''
ROOTFS=''
HOSTS_MOUNT=''
TMP_HOSTS=''

cleanup() {
  if [[ -n "$HOSTS_MOUNT" ]]; then
    umount "$HOSTS_MOUNT" 2>/dev/null || true
  fi
  [[ -n "$TMP_HOSTS" ]] && rm -f "$TMP_HOSTS"
  rm -rf "$PREFIX" "$WORK_DIR"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { echo 'backup-hosts-test requires root' >&2; exit 1; }

tar -xzf "$BUNDLE" -C "$WORK_DIR"
PACKAGE_DIR="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -n "$PACKAGE_DIR" ]] || { echo 'bundle root directory missing' >&2; exit 1; }

if ! id chroot-pg >/dev/null 2>&1; then
  useradd --system --home-dir /nonexistent --shell /sbin/nologin chroot-pg
fi
run_uid="$(id -u chroot-pg)"
run_gid="$(id -g chroot-pg)"

mkdir -p "$PREFIX"
cp -a "$PACKAGE_DIR/rootfs" "$PREFIX/rootfs"
ROOTFS="$PREFIX/rootfs"
install -D -m 0755 "$PACKAGE_DIR/bin/chroot-pg-backup" "$PREFIX/bin/chroot-pg-backup"

if ! awk -F: -v gid="$run_gid" '$3 == gid { found=1 } END { exit !found }' "$ROOTFS/etc/group"; then
  printf 'chroot-pg:x:%s:\n' "$run_gid" >> "$ROOTFS/etc/group"
fi
if ! awk -F: -v uid="$run_uid" '$3 == uid { found=1 } END { exit !found }' "$ROOTFS/etc/passwd"; then
  printf 'chroot-pg:x:%s:%s:chroot-pg runtime:/nonexistent:/usr/sbin/nologin\n' \
    "$run_uid" "$run_gid" >> "$ROOTFS/etc/passwd"
fi

TMP_HOSTS="$(mktemp)"
cp /etc/hosts "$TMP_HOSTS"
printf '%s %s\n' "$TEST_IP" "$TEST_HOST" >> "$TMP_HOSTS"

HOSTS_MOUNT="$ROOTFS/etc/hosts"
mount --bind "$TMP_HOSTS" "$HOSTS_MOUNT"

hosts_content="$(chroot --userspec="$run_uid:$run_gid" "$ROOTFS" cat /etc/hosts)"
[[ "$hosts_content" == *"$TEST_IP"* && "$hosts_content" == *"$TEST_HOST"* ]] || {
  echo "expected $TEST_IP and $TEST_HOST in chroot /etc/hosts" >&2
  exit 1
}

if ! "$PREFIX/bin/chroot-pg-backup" --help 2>&1 | grep -q -- '--remote'; then
  echo 'chroot-pg-backup help does not mention --remote' >&2
  exit 1
fi

echo 'backup-hosts-test passed'
