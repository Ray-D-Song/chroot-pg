#!/usr/bin/env bash
set -euo pipefail

PREFIX=/opt/chroot-pg
DATA_DIR=/var/lib/chroot-pg/data
CREDENTIALS=/etc/chroot-pg/credentials
SERVICE_NAME=chroot-pg
RUN_USER=chroot-pg
PORT=5432
LISTEN_ADDRESSES='*'
PASSWORD_CLI=''

usage() {
  cat <<EOF
Usage: sudo ./install.sh [options]
  --prefix PATH             Rootfs install directory (default: $PREFIX)
  --data-dir PATH           Persistent database directory (default: $DATA_DIR)
  --port PORT               PostgreSQL port (default: $PORT)
  --listen-addresses VALUE  PostgreSQL listen_addresses (default: *)
  --service-name NAME       systemd service name (default: $SERVICE_NAME)
  --credentials-file PATH   Root-only credentials file (default: $CREDENTIALS)
  --password VALUE          postgres password for a new cluster (or set CHROOT_PG_PASSWORD)
EOF
}

validate_password() {
  local pw="$1"
  [[ -n "$pw" ]] || { echo 'password must not be empty' >&2; exit 2; }
  (( ${#pw} >= 8 )) || { echo 'password must be at least 8 characters' >&2; exit 2; }
  [[ "${pw//$'\n'}" == "$pw" ]] || { echo 'password must not contain newline' >&2; exit 2; }
  (( $(printf '%s' "$pw" | tr -cd '\0' | wc -c) == 0 )) \
    || { echo 'password must not contain null bytes' >&2; exit 2; }
  [[ ! "$pw" =~ [[:cntrl:]] ]] || { echo 'password must not contain control characters' >&2; exit 2; }
}

password_was_provided() {
  [[ -n "$PASSWORD_CLI" || -n "${CHROOT_PG_PASSWORD:-}" ]]
}

warn_if_password_ignored() {
  if password_was_provided; then
    echo 'Warning: existing data directory detected; --password and CHROOT_PG_PASSWORD were ignored.' >&2
  fi
}

resolve_password_for_new_install() {
  if [[ -n "$PASSWORD_CLI" ]]; then
    password="$PASSWORD_CLI"
    echo "Using password from --password. It will be stored in $CREDENTIALS (root only)."
  elif [[ -n "${CHROOT_PG_PASSWORD:-}" ]]; then
    password="$CHROOT_PG_PASSWORD"
    echo "Using password from CHROOT_PG_PASSWORD. It will be stored in $CREDENTIALS (root only)."
  else
    password="$(openssl rand -base64 36 | tr -d '\n')"
    echo "Generated PostgreSQL password. It is stored in $CREDENTIALS (root only)."
  fi
  validate_password "$password"
}

read_credentials_password() {
  password="$(awk -F= '$1 == "POSTGRES_PASSWORD" { print substr($0, index($0, "=") + 1) }' "$CREDENTIALS")"
  [[ -n "$password" ]] || { echo "credentials file has no POSTGRES_PASSWORD: $CREDENTIALS" >&2; exit 1; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix|--data-dir|--port|--listen-addresses|--service-name|--credentials-file|--password)
      key="$1"; shift; [[ $# -gt 0 ]] || { echo "missing value for $key" >&2; exit 2; }
      case "$key" in
        --prefix) PREFIX="$1" ;;
        --data-dir) DATA_DIR="$1" ;;
        --port) PORT="$1" ;;
        --listen-addresses) LISTEN_ADDRESSES="$1" ;;
        --service-name) SERVICE_NAME="$1" ;;
        --credentials-file) CREDENTIALS="$1" ;;
        --password) PASSWORD_CLI="$1" ;;
      esac
      shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo 'run install.sh with sudo or as root' >&2; exit 1; }
[[ "$(uname -m)" == "x86_64" ]] || { echo 'chroot-pg supports Linux amd64 only' >&2; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || { echo 'port must be 1..65535' >&2; exit 2; }
[[ "$LISTEN_ADDRESSES" =~ ^[a-zA-Z0-9.,:*_-]+$ ]] || { echo 'invalid listen addresses' >&2; exit 2; }
[[ "$SERVICE_NAME" =~ ^[a-zA-Z0-9_.@-]+$ ]] || { echo 'invalid service name' >&2; exit 2; }
[[ "$PREFIX" == /* && "$PREFIX" != / && "$DATA_DIR" == /* && "$DATA_DIR" != / ]] || { echo 'prefix and data-dir must be non-root absolute paths' >&2; exit 2; }
[[ "$CREDENTIALS" == /* && "$CREDENTIALS" != / ]] || { echo 'credentials-file must be a non-root absolute path' >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOTFS="$SCRIPT_DIR/rootfs"
[[ -x "$SOURCE_ROOTFS/usr/lib/postgresql/17/bin/postgres" ]] || { echo "rootfs is missing from $SOURCE_ROOTFS" >&2; exit 1; }

if ! id "$RUN_USER" >/dev/null 2>&1; then
  useradd --system --home-dir /nonexistent --shell /sbin/nologin "$RUN_USER"
fi
RUN_UID="$(id -u "$RUN_USER")"
RUN_GID="$(id -g "$RUN_USER")"

ensure_chroot_identity() {
  local rootfs="$1"
  if ! awk -F: -v gid="$RUN_GID" '$3 == gid { found=1 } END { exit !found }' "$rootfs/etc/group"; then
    printf '%s:x:%s:\n' "$RUN_USER" "$RUN_GID" >> "$rootfs/etc/group"
  fi
  if ! awk -F: -v uid="$RUN_UID" '$3 == uid { found=1 } END { exit !found }' "$rootfs/etc/passwd"; then
    printf '%s:x:%s:%s:chroot-pg runtime:/nonexistent:/usr/sbin/nologin\n' \
      "$RUN_USER" "$RUN_UID" "$RUN_GID" >> "$rootfs/etc/passwd"
  fi
}

if systemctl is-active --quiet "$SERVICE_NAME"; then systemctl stop "$SERVICE_NAME"; fi
mkdir -p "$PREFIX" "$DATA_DIR" "$(dirname "$CREDENTIALS")"
chmod 0750 "$(dirname "$CREDENTIALS")"
chown "$RUN_UID:$RUN_GID" "$DATA_DIR"

new_rootfs="$PREFIX/rootfs.new"
rm -rf "$new_rootfs"
cp -a "$SOURCE_ROOTFS" "$new_rootfs"
if [[ -d "$PREFIX/rootfs" ]]; then rm -rf "$PREFIX/rootfs"; fi
mv "$new_rootfs" "$PREFIX/rootfs"
install -D -m 0755 "$SCRIPT_DIR/bin/chroot-pg-run" "$PREFIX/bin/chroot-pg-run"
install -D -m 0755 "$SCRIPT_DIR/bin/chroot-pg-backup" "$PREFIX/bin/chroot-pg-backup"
ensure_chroot_identity "$PREFIX/rootfs"
# PostgreSQL creates its local socket and lock files below /var/run/postgresql
# (a link to /run on Debian). This directory must match the host runtime UID.
install -d -o "$RUN_UID" -g "$RUN_GID" -m 0755 "$PREFIX/rootfs/run/postgresql"

PGDATA_HOST="$DATA_DIR/data"
MANAGED_BEGIN='# BEGIN chroot-pg managed settings'
MANAGED_END='# END chroot-pg managed settings'
# Settings the installer owns. Everything outside the delimiters is left alone,
# so reinstalls refresh our block instead of stacking duplicates.
write_managed_block() {
  local target="$1" tmp
  [[ -f "$target" ]] || { echo "missing configuration file: $target" >&2; exit 1; }
  tmp="$(mktemp)"
  awk -v head="$MANAGED_BEGIN" -v tail="$MANAGED_END" '
    $0 == head { inside = 1; next }
    $0 == tail { inside = 0; next }
    inside == 0 { print }
  ' "$target" > "$tmp"
  { printf '%s\n' "$MANAGED_BEGIN"; cat; printf '%s\n' "$MANAGED_END"; } >> "$tmp"
  cat "$tmp" > "$target"
  rm -f "$tmp"
  chown "$RUN_UID:$RUN_GID" "$target"
  chmod 0600 "$target"
}

apply_managed_settings() {
  write_managed_block "$PGDATA_HOST/postgresql.conf" <<EOF
listen_addresses = '$LISTEN_ADDRESSES'
port = $PORT
password_encryption = 'scram-sha-256'
wal_level = replica
archive_mode = on
archive_command = 'test -f /var/lib/postgresql/wal-archive/%f || cp %p /var/lib/postgresql/wal-archive/%f'
archive_timeout = 300s
summarize_wal = on
wal_summary_keep_time = 30d
max_wal_senders = 4
max_replication_slots = 2
EOF
  write_managed_block "$PGDATA_HOST/pg_hba.conf" <<'EOF'
host all all 0.0.0.0/0 scram-sha-256
host all all ::0/0 scram-sha-256
host replication all 0.0.0.0/0 scram-sha-256
host replication all ::0/0 scram-sha-256
EOF
}

# Earlier installs wrote these settings beside PGDATA instead of inside it,
# where PostgreSQL never reads them. Drop the leftovers, but only when they
# hold nothing except those ignored lines.
discard_stray_conf() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  grep -qvE "^[[:space:]]*$|^listen_addresses = |^port = [0-9]+$|^password_encryption = 'scram-sha-256'$|^host all all (0\.0\.0\.0/0|::0/0) scram-sha-256$" "$file" \
    || rm -f "$file"
}

if [[ ! -f "$PGDATA_HOST/PG_VERSION" ]]; then
  resolve_password_for_new_install
  if ! chroot "$PREFIX/rootfs" /usr/bin/locale -a 2>/dev/null | grep -Eiq '^C\.(UTF-8|utf8)$'; then
    echo "rootfs is missing the required C.UTF-8 locale; rebuild the chroot-pg package" >&2
    exit 1
  fi
  umask 077
  cat > "$CREDENTIALS" <<EOF
POSTGRES_USER=postgres
POSTGRES_PASSWORD=$password
POSTGRES_PORT=$PORT
EOF
  # PostgreSQL refuses to initialise a cluster directly on a mount point. Bind
  # the persistent directory to its parent, then keep the cluster in `data/`.
  install -d -m 0755 "$PGDATA_HOST" "$PREFIX/rootfs/var/lib/postgresql" "$PREFIX/rootfs/dev/shm"
  chown "$RUN_UID:$RUN_GID" "$PGDATA_HOST"
  mount --bind "$DATA_DIR" "$PREFIX/rootfs/var/lib/postgresql"
  mount --bind /dev/shm "$PREFIX/rootfs/dev/shm"
  # Keep the temporary password file outside PGDATA: initdb requires its target
  # directory to be empty, including hidden files.
  password_file="$DATA_DIR/.init-password"
  cleanup_mounts() {
    umount "$PREFIX/rootfs/dev/shm" 2>/dev/null || true
    umount "$PREFIX/rootfs/var/lib/postgresql" 2>/dev/null || true
  }
  rollback_initialization() {
    cleanup_mounts
    rm -f "$password_file"
  }
  trap rollback_initialization EXIT
  printf '%s\n' "$password" > "$password_file"
  chown "$RUN_UID:$RUN_GID" "$password_file"; chmod 0600 "$password_file"
  chroot --userspec="$RUN_UID:$RUN_GID" "$PREFIX/rootfs" /usr/bin/env \
    LANG=C.UTF-8 LC_ALL=C.UTF-8 /usr/lib/postgresql/17/bin/initdb \
    -D /var/lib/postgresql/data --username=postgres --pwfile=/var/lib/postgresql/.init-password \
    --auth-host=scram-sha-256 --auth-local=peer --locale=C.UTF-8 --no-instructions
  rm -f "$password_file"
  cleanup_mounts
  trap - EXIT
else
  [[ -f "$CREDENTIALS" ]] || { echo "existing data directory requires credentials file: $CREDENTIALS" >&2; exit 1; }
  read_credentials_password
  warn_if_password_ignored
fi

apply_managed_settings
install -d -o "$RUN_UID" -g "$RUN_GID" -m 0700 "$DATA_DIR/wal-archive"
discard_stray_conf "$DATA_DIR/postgresql.conf"
discard_stray_conf "$DATA_DIR/pg_hba.conf"

sed -e "s|@PREFIX@|$PREFIX|g" -e "s|@DATA_DIR@|$DATA_DIR|g" \
  -e "s|@RUN_UID@|$RUN_UID|g" -e "s|@RUN_GID@|$RUN_GID|g" \
  -e "s|@PORT@|$PORT|g" -e "s|@LISTEN_ADDRESSES@|$LISTEN_ADDRESSES|g" \
  "$SCRIPT_DIR/systemd/chroot-pg.service.in" > "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"
echo "Installed $SERVICE_NAME. Check: systemctl status $SERVICE_NAME"
