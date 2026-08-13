#!/usr/bin/env bash
set -euo pipefail

BUNDLE="${1:?usage: smoke-test.sh <bundle.tar.gz>}"
TEST_ID="${2:-${GITHUB_RUN_ID:-local}-${RANDOM}}"
WORK_DIR="$(mktemp -d /tmp/chroot-pg-test.XXXXXX)"
PREFIX="/opt/chroot-pg-test-$TEST_ID"
DATA_DIR="/var/lib/chroot-pg-test-$TEST_ID"
SERVICE="chroot-pg-test-$TEST_ID"
PORT="$(( 20000 + RANDOM % 20000 ))"
CREDENTIALS="/etc/chroot-pg-test-$TEST_ID/credentials"
PG_BIN='/usr/lib/postgresql/17/bin'
PACKAGE_DIR=''

cleanup() {
  if [[ -n "$PACKAGE_DIR" && -x "$PACKAGE_DIR/uninstall.sh" ]]; then
    "$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --purge-data || true
  fi
  umount "$PREFIX/rootfs/dev/shm" 2>/dev/null || true
  umount "$PREFIX/rootfs/var/lib/postgresql/data" 2>/dev/null || true
  rm -rf "$PREFIX" "$DATA_DIR" "$(dirname "$CREDENTIALS")"
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { echo 'smoke test requires root' >&2; exit 1; }
tar -xzf "$BUNDLE" -C "$WORK_DIR"
PACKAGE_DIR="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -n "$PACKAGE_DIR" ]] || { echo 'bundle root directory missing' >&2; exit 1; }
"$PACKAGE_DIR/install.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --port "$PORT" --listen-addresses 127.0.0.1
systemctl is-active --quiet "$SERVICE"

source "$CREDENTIALS"
for _ in $(seq 1 30); do
  if PGPASSWORD="$POSTGRES_PASSWORD" chroot "$PREFIX/rootfs" "$PG_BIN/pg_isready" -h 127.0.0.1 -p "$PORT" -U postgres; then break; fi
  sleep 1
done
PGPASSWORD="$POSTGRES_PASSWORD" chroot "$PREFIX/rootfs" "$PG_BIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c 'create table ci_smoke(id integer primary key, note text)' -c "insert into ci_smoke values (1, 'ok')" -c 'select * from ci_smoke'
systemctl restart "$SERVICE"
PGPASSWORD="$POSTGRES_PASSWORD" chroot "$PREFIX/rootfs" "$PG_BIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc 'select note from ci_smoke where id = 1' | grep -Fx ok
"$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS"
[[ -f "$DATA_DIR/PG_VERSION" ]] || { echo 'uninstall unexpectedly removed database data' >&2; exit 1; }
"$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --purge-data
[[ ! -e "$DATA_DIR" ]] || { echo 'purge-data did not remove test data' >&2; exit 1; }
echo 'chroot-pg smoke test passed'
