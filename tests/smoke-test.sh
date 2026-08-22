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
BACKUP_DIR="/var/lib/chroot-pg-backup-test-$TEST_ID"
BACKUP_SET_ID="smoke-set"
PG_BIN='/usr/lib/postgresql/17/bin'
PACKAGE_DIR=''

cleanup() {
  if [[ -n "$PACKAGE_DIR" && -x "$PACKAGE_DIR/uninstall.sh" ]]; then
    "$PACKAGE_DIR/uninstall.sh" --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" --credentials-file "$CREDENTIALS" --purge-data || true
  fi
  umount "$PREFIX/rootfs/dev/shm" 2>/dev/null || true
  umount "$PREFIX/rootfs/var/lib/postgresql" 2>/dev/null || true
  rm -rf "$PREFIX" "$DATA_DIR" "$BACKUP_DIR" "$(dirname "$CREDENTIALS")"
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { echo 'smoke test requires root' >&2; exit 1; }
tar -xzf "$BUNDLE" -C "$WORK_DIR"
PACKAGE_DIR="$(find "$WORK_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -n "$PACKAGE_DIR" ]] || { echo 'bundle root directory missing' >&2; exit 1; }
env LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 "$PACKAGE_DIR/install.sh" \
  --prefix "$PREFIX" --data-dir "$DATA_DIR" --service-name "$SERVICE" \
  --credentials-file "$CREDENTIALS" --port "$PORT" --listen-addresses 127.0.0.1
systemctl is-active --quiet "$SERVICE"
[[ -x "$PREFIX/bin/chroot-pg-backup" ]] || { echo 'backup wrapper missing from installation' >&2; exit 1; }
"$PREFIX/bin/chroot-pg-backup" --help >/dev/null
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

pg_exec() {
  PGPASSWORD="$POSTGRES_PASSWORD" chroot "$PREFIX/rootfs" "$PG_BIN/psql" \
    -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
}

pg_query() {
  pg_exec -tAc "$1" | sed -e 's/^ *//' -e 's/ *$//' | tr -d '\r'
}

wait_for_wal_archive() {
  for _ in $(seq 1 60); do
    compgen -G "$DATA_DIR/wal-archive/[0-9A-Fa-f]*" >/dev/null && return 0
    sleep 1
  done
  echo 'WAL archive file was not created in time' >&2
  return 1
}

switch_wal_and_wait_for_archive() {
  local before current
  before="$(pg_query 'select archived_count from pg_stat_archiver')"
  pg_exec -tAc 'select pg_switch_wal()' >/dev/null
  for _ in $(seq 1 60); do
    current="$(pg_query 'select archived_count from pg_stat_archiver')"
    if [[ "$current" =~ ^[0-9]+$ && "$before" =~ ^[0-9]+$ ]] && (( current > before )); then
      return 0
    fi
    sleep 1
  done
  echo 'WAL archiver did not complete after pg_switch_wal' >&2
  return 1
}

sync_wal_archive() {
  install -d -o chroot-pg -g chroot-pg -m 0750 "$BACKUP_DIR/wal"
  for wal_file in "$DATA_DIR/wal-archive"/*; do
    [[ -f "$wal_file" ]] || continue
    case "$(basename "$wal_file")" in
      [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]*|*.history)
        install -o chroot-pg -g chroot-pg -m 0600 "$wal_file" "$BACKUP_DIR/wal/$(basename "$wal_file")" ;;
    esac
  done
}

wait_for_wal_summary() {
  local count
  for _ in $(seq 1 60); do
    count="$(pg_exec -tAc 'select count(*) from pg_available_wal_summaries()' | tr -d '[:space:]')"
    if [[ "$count" =~ ^[1-9][0-9]*$ ]]; then return 0; fi
    sleep 1
  done
  echo 'WAL summary was not generated in time' >&2
  return 1
}

backup_args=(
  --rootfs "$PREFIX/rootfs"
  --data-dir "$DATA_DIR"
  --credentials-file "$CREDENTIALS"
  --backup-dir "$BACKUP_DIR"
  --port "$PORT"
  --set-id "$BACKUP_SET_ID"
)

wait_for_postgres
# The rules must live in the running cluster's pg_hba.conf, not merely on disk
# somewhere: a loopback-only smoke test would otherwise pass without them.
PGPASSWORD="$POSTGRES_PASSWORD" chroot "$PREFIX/rootfs" "$PG_BIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc \
  "select count(*) from pg_hba_file_rules where type = 'host' and auth_method = 'scram-sha-256' and netmask in ('0.0.0.0', '::') and error is null" \
  | grep -Fx 4
PGPASSWORD="$POSTGRES_PASSWORD" chroot "$PREFIX/rootfs" "$PG_BIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc \
  "select current_setting('wal_level') || '|' || current_setting('archive_mode') || '|' || current_setting('summarize_wal')" \
  | grep -Fx 'replica|on|on'
PGPASSWORD="$POSTGRES_PASSWORD" chroot "$PREFIX/rootfs" "$PG_BIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc \
  "select current_setting('archive_command') <> ''" | grep -Fx t
PGPASSWORD="$POSTGRES_PASSWORD" chroot "$PREFIX/rootfs" "$PG_BIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c 'create table ci_smoke(id integer primary key, note text)' -c "insert into ci_smoke values (1, 'ok')" -c 'select * from ci_smoke'
# PostgreSQL permits superusers to use the replication protocol even when the
# rolreplication flag is false. Verify the actual protocol path used by
# pg_basebackup instead of relying only on catalog metadata.
PGPASSWORD="$POSTGRES_PASSWORD" chroot "$PREFIX/rootfs" "$PG_BIN/pg_basebackup" \
  -h 127.0.0.1 -p "$PORT" -U postgres -D /tmp/chroot-pg-replication-check \
  -Fp -X none --no-manifest >/dev/null
rm -rf "$PREFIX/rootfs/tmp/chroot-pg-replication-check"
PGPASSWORD="$POSTGRES_PASSWORD" chroot "$PREFIX/rootfs" "$PG_BIN/psql" -h 127.0.0.1 -p "$PORT" -U postgres -d postgres -tAc 'select pg_switch_wal()'
wait_for_wal_archive

echo '==> verify PostgreSQL full, incremental, verify, combine, and PITR'
pg_exec -c "create table ci_backup(id integer primary key, note text not null)" \
  -c "insert into ci_backup values (1, 'baseline')"
pg_exec -tAc 'select pg_switch_wal()' >/dev/null
wait_for_wal_archive

FULL_DIR="$BACKUP_DIR/sets/$BACKUP_SET_ID/full"
INCREMENTAL_DIR="$BACKUP_DIR/sets/$BACKUP_SET_ID/incremental/inc-1"
COMBINED_DIR="$BACKUP_DIR/sets/$BACKUP_SET_ID/combined"
BROKEN_WAL_DIR="$BACKUP_DIR/broken-wal"

"$PREFIX/bin/chroot-pg-backup" "${backup_args[@]}" --output "$FULL_DIR" \
  backup-full >"$WORK_DIR/full-result.json"
[[ -s "$FULL_DIR/backup_manifest" ]] || { echo 'full backup manifest is missing' >&2; exit 1; }
pg_exec -tAc 'select pg_switch_wal()' >/dev/null
wait_for_wal_archive
sync_wal_archive
"$PREFIX/bin/chroot-pg-backup" "${backup_args[@]}" --target "$FULL_DIR" \
  verify >"$WORK_DIR/full-verify-result.json"

if "$PREFIX/bin/chroot-pg-backup" "${backup_args[@]}" \
  --base-manifest "$BACKUP_DIR/missing/backup_manifest" \
  --output "$BACKUP_DIR/sets/$BACKUP_SET_ID/incremental/missing" \
  backup-incremental >"$WORK_DIR/missing-base-result.json" 2>"$WORK_DIR/missing-base-error.log"; then
  echo 'incremental backup unexpectedly accepted a missing base manifest' >&2
  exit 1
fi

pg_exec -c "insert into ci_backup values (2, 'incremental')"
pg_exec -tAc 'select pg_switch_wal()' >/dev/null
wait_for_wal_archive
wait_for_wal_summary
"$PREFIX/bin/chroot-pg-backup" "${backup_args[@]}" --output "$INCREMENTAL_DIR" \
  --base-manifest "$FULL_DIR/backup_manifest" backup-incremental >"$WORK_DIR/incremental-result.json"
[[ -s "$INCREMENTAL_DIR/backup_manifest" ]] || { echo 'incremental backup manifest is missing' >&2; exit 1; }
pg_exec -tAc 'select pg_switch_wal()' >/dev/null
wait_for_wal_archive
sync_wal_archive
"$PREFIX/bin/chroot-pg-backup" "${backup_args[@]}" --target "$INCREMENTAL_DIR" \
  verify >"$WORK_DIR/incremental-verify-result.json"

cp "$FULL_DIR/backup_manifest" "$WORK_DIR/full-backup-manifest"
printf '{}\n' >"$FULL_DIR/backup_manifest"
if "$PREFIX/bin/chroot-pg-backup" "${backup_args[@]}" --target "$FULL_DIR" \
  verify >"$WORK_DIR/corrupt-manifest-result.json" 2>"$WORK_DIR/corrupt-manifest-error.log"; then
  echo 'pg_verifybackup unexpectedly accepted a corrupt manifest' >&2
  exit 1
fi
mv "$WORK_DIR/full-backup-manifest" "$FULL_DIR/backup_manifest"
chown chroot-pg:chroot-pg "$FULL_DIR/backup_manifest"
chmod 0600 "$FULL_DIR/backup_manifest"

install -d -o chroot-pg -g chroot-pg -m 0750 "$BROKEN_WAL_DIR"
if "$PREFIX/bin/chroot-pg-backup" "${backup_args[@]}" --target "$FULL_DIR" \
  --wal-dir "$BROKEN_WAL_DIR" verify >"$WORK_DIR/missing-wal-result.json" 2>"$WORK_DIR/missing-wal-error.log"; then
  echo 'pg_verifybackup unexpectedly accepted a missing WAL directory' >&2
  exit 1
fi

"$PREFIX/bin/chroot-pg-backup" "${backup_args[@]}" --output "$COMBINED_DIR" \
  --input "$FULL_DIR" --input "$INCREMENTAL_DIR" combine >"$WORK_DIR/combine-result.json"
[[ -s "$COMBINED_DIR/backup_manifest" ]] || { echo 'combined backup manifest is missing' >&2; exit 1; }
"$PREFIX/bin/chroot-pg-backup" "${backup_args[@]}" --target "$COMBINED_DIR" \
  verify >"$WORK_DIR/combined-verify-result.json"

pg_exec -c "insert into ci_backup values (3, 'pitr-before')"
PITR_TARGET="$(pg_query 'select clock_timestamp()::text')"
sleep 2
pg_exec -c "insert into ci_backup values (4, 'pitr-after')"
switch_wal_and_wait_for_archive
sync_wal_archive

systemctl stop "$SERVICE"
mv "$DATA_DIR/data" "$DATA_DIR/data.before-pitr"
cp -a "$COMBINED_DIR" "$DATA_DIR/data"
chown -R chroot-pg:chroot-pg "$DATA_DIR/data"
cat >"$DATA_DIR/data/postgresql.auto.conf" <<EOF
restore_command = 'cp /var/lib/postgresql/wal-archive/%f %p'
recovery_target_time = '$PITR_TARGET'
recovery_target_inclusive = true
recovery_target_action = 'promote'
EOF
touch "$DATA_DIR/data/recovery.signal"
chown chroot-pg:chroot-pg "$DATA_DIR/data/postgresql.auto.conf" "$DATA_DIR/data/recovery.signal"
chmod 0600 "$DATA_DIR/data/postgresql.auto.conf" "$DATA_DIR/data/recovery.signal"
systemctl start "$SERVICE"
wait_for_postgres
pg_exec -tAc 'select pg_is_in_recovery()' | grep -Fx f
PITR_ROWS="$(pg_query "select string_agg(note, ',' order by id) from ci_backup")"
[[ "$PITR_ROWS" == 'baseline,incremental,pitr-before' ]] || { echo "unexpected PITR rows: $PITR_ROWS" >&2; exit 1; }
[[ ! -e "$DATA_DIR/data/recovery.signal" ]] || { echo 'recovery.signal was not cleaned after promotion' >&2; exit 1; }

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
