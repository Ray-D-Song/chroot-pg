#!/usr/bin/env bash
set -euo pipefail

BUNDLE="${1:?usage: backup-hosts-test.sh <bundle.tar.gz>}"
WORK_DIR="$(mktemp -d /tmp/chroot-pg-hosts-test.XXXXXX)"
PREFIX="/opt/chroot-pg-hosts-test-$$"
DATA_DIR="/var/lib/chroot-pg-hosts-test-$$"
BACKUP_DIR="/var/backups/chroot-pg-hosts-test-$$"
CREDENTIALS="/etc/chroot-pg-hosts-test-$$/credentials"
TEST_HOST='pg-headless-test'
TEST_IP='203.0.113.1'
PACKAGE_DIR=''
ROOTFS=''
HOSTS_MOUNT=''

cleanup() {
  if [[ -n "$HOSTS_MOUNT" && -n "$ROOTFS" ]]; then
    umount "$HOSTS_MOUNT" 2>/dev/null || true
  fi
  rm -f "$CREDENTIALS"
  rm -rf "$(dirname "$CREDENTIALS")" "$PREFIX" "$DATA_DIR" "$BACKUP_DIR" "$WORK_DIR"
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

mkdir -p "$DATA_DIR/data" "$BACKUP_DIR" "$(dirname "$CREDENTIALS")"
cat > "$CREDENTIALS" <<EOF
POSTGRES_USER=postgres
POSTGRES_PASSWORD=test-pass-8chars
POSTGRES_PORT=5432
EOF
chmod 0600 "$CREDENTIALS"

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

tmp_hosts="$(mktemp)"
cp /etc/hosts "$tmp_hosts"
printf '%s %s\n' "$TEST_IP" "$TEST_HOST" >> "$tmp_hosts"

HOSTS_MOUNT="$ROOTFS/etc/hosts"
mount --bind "$tmp_hosts" "$HOSTS_MOUNT"

result="$(chroot --userspec="$run_uid:$run_gid" "$ROOTFS" /usr/bin/getent hosts "$TEST_HOST")"
[[ "$result" == *"$TEST_IP"* ]] || {
  echo "expected $TEST_IP in getent output, got: $result" >&2
  exit 1
}

if "$PREFIX/bin/chroot-pg-backup" --help 2>&1 | grep -q -- '--remote'; then
  :
else
  echo 'chroot-pg-backup help does not mention --remote' >&2
  exit 1
fi

echo 'backup-hosts-test passed'
