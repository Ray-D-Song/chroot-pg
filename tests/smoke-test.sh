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
  umount "$PREFIX/rootfs/var/lib/postgresql" 2>/dev/null || true
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
[[ "$(grep -c '^# BEGIN chroot-pg managed settings$' "$DATA_DIR/data/pg_hba.conf")" == 1 ]] || { echo 'managed pg_hba block is missing or duplicated' >&2; exit 1; }
[[ ! -e "$DATA_DIR/pg_hba.conf" && ! -e "$DATA_DIR/postgresql.conf" ]] || { echo 'configuration was written outside PGDATA' >&2; exit 1; }

source "$CREDENTIALS"
wait_for_postgres() {
  local prefix="${1:-$PREFIX}" port="${2:-$PORT}" password="${3:-$POSTGRES_PASSWORD}"
  for _ in $(seq 1 30); do
    if PGPASSWORD="$password" chroot "$prefix/rootfs" "$PG_BIN/pg_isready" -h 127.0.0.1 -p "$port" -U postgres; then
      return 0
    fi
    sleep 1
  done
  echo "PostgreSQL did not become ready on port $port" >&2
  return 1
}

wait_for_postgres
# The rules must live in the running cluster's pg_hba.conf, not merely on disk
# somewhere: a loopback-only smoke test would otherwise pass without them.
PGPASSWORD="$POSTGRES_PASSWORD" chroot "$PREFIX/rootfs" "$PG_BIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc \
  "select count(*) from pg_hba_file_rules where type = 'host' and auth_method = 'scram-sha-256' and netmask in ('0.0.0.0', '::') and error is null" \
  | grep -Fx 2
PGPASSWORD="$POSTGRES_PASSWORD" chroot "$PREFIX/rootfs" "$PG_BIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c 'create table ci_smoke(id integer primary key, note text)' -c "insert into ci_smoke values (1, 'ok')" -c 'select * from ci_smoke'
systemctl restart "$SERVICE"
wait_for_postgres
PGPASSWORD="$POSTGRES_PASSWORD" chroot "$PREFIX/rootfs" "$PG_BIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc 'select note from ci_smoke where id = 1' | grep -Fx ok
"$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS"
[[ -f "$DATA_DIR/data/PG_VERSION" ]] || { echo 'uninstall unexpectedly removed database data' >&2; exit 1; }
"$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --purge-data
[[ ! -e "$DATA_DIR" ]] || { echo 'purge-data did not remove test data' >&2; exit 1; }

# Custom password via environment variable on a fresh install.
CUSTOM_TEST_ID="${TEST_ID}-custom"
CUSTOM_PREFIX="/opt/chroot-pg-test-$CUSTOM_TEST_ID"
CUSTOM_DATA_DIR="/var/lib/chroot-pg-test-$CUSTOM_TEST_ID"
CUSTOM_SERVICE="chroot-pg-test-$CUSTOM_TEST_ID"
CUSTOM_PORT="$(( 20000 + RANDOM % 20000 ))"
CUSTOM_CREDENTIALS="/etc/chroot-pg-test-$CUSTOM_TEST_ID/credentials"
CUSTOM_PASSWORD='ci-fixed-pass-8chars'
OTHER_PASSWORD='other-pass-8chars'

custom_cleanup() {
  if [[ -x "$PACKAGE_DIR/uninstall.sh" ]]; then
    "$PACKAGE_DIR/uninstall.sh" --prefix "$CUSTOM_PREFIX" --data-dir "$CUSTOM_DATA_DIR" \
      --service-name "$CUSTOM_SERVICE" --credentials-file "$CUSTOM_CREDENTIALS" --purge-data || true
  fi
  umount "$CUSTOM_PREFIX/rootfs/dev/shm" 2>/dev/null || true
  umount "$CUSTOM_PREFIX/rootfs/var/lib/postgresql" 2>/dev/null || true
  rm -rf "$CUSTOM_PREFIX" "$CUSTOM_DATA_DIR" "$(dirname "$CUSTOM_CREDENTIALS")"
}
trap custom_cleanup EXIT

CHROOT_PG_PASSWORD="$CUSTOM_PASSWORD" "$PACKAGE_DIR/install.sh" \
  --prefix "$CUSTOM_PREFIX" --data-dir "$CUSTOM_DATA_DIR" --service-name "$CUSTOM_SERVICE" \
  --credentials-file "$CUSTOM_CREDENTIALS" --port "$CUSTOM_PORT" --listen-addresses 127.0.0.1
systemctl is-active --quiet "$CUSTOM_SERVICE"
source "$CUSTOM_CREDENTIALS"
[[ "$POSTGRES_PASSWORD" == "$CUSTOM_PASSWORD" ]] || { echo 'custom password was not stored in credentials' >&2; exit 1; }
wait_for_postgres "$CUSTOM_PREFIX" "$CUSTOM_PORT" "$POSTGRES_PASSWORD"
PGPASSWORD="$POSTGRES_PASSWORD" chroot "$CUSTOM_PREFIX/rootfs" "$PG_BIN/psql" -h 127.0.0.1 -p "$CUSTOM_PORT" -U postgres -d postgres -tAc 'select 1' | grep -Fx 1

# Reinstall with a different password must keep the original credentials password.
systemctl stop "$CUSTOM_SERVICE"
reinstall_output="$(CHROOT_PG_PASSWORD="$OTHER_PASSWORD" "$PACKAGE_DIR/install.sh" \
  --prefix "$CUSTOM_PREFIX" --data-dir "$CUSTOM_DATA_DIR" --service-name "$CUSTOM_SERVICE" \
  --credentials-file "$CUSTOM_CREDENTIALS" --port "$CUSTOM_PORT" --listen-addresses 127.0.0.1 \
  --password "$OTHER_PASSWORD" 2>&1)"
grep -q 'ignored' <<<"$reinstall_output" || { echo 'reinstall did not warn about ignored password' >&2; exit 1; }
systemctl is-active --quiet "$CUSTOM_SERVICE"
source "$CUSTOM_CREDENTIALS"
[[ "$POSTGRES_PASSWORD" == "$CUSTOM_PASSWORD" ]] || { echo 'reinstall changed the stored password' >&2; exit 1; }
wait_for_postgres "$CUSTOM_PREFIX" "$CUSTOM_PORT" "$POSTGRES_PASSWORD"
PGPASSWORD="$POSTGRES_PASSWORD" chroot "$CUSTOM_PREFIX/rootfs" "$PG_BIN/psql" -h 127.0.0.1 -p "$CUSTOM_PORT" -U postgres -d postgres -tAc 'select 1' | grep -Fx 1

custom_cleanup
trap - EXIT

echo 'chroot-pg smoke test passed'
