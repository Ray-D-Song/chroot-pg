#!/usr/bin/env bash
set -euo pipefail

PREFIX=/opt/chroot-pg
DATA_DIR=/var/lib/chroot-pg/data
CREDENTIALS=/etc/chroot-pg/credentials
SERVICE_NAME=chroot-pg
RUN_USER=chroot-pg
PORT=5432
LISTEN_ADDRESSES='*'

usage() {
  cat <<EOF
Usage: sudo ./install.sh [options]
  --prefix PATH             Rootfs install directory (default: $PREFIX)
  --data-dir PATH           Persistent database directory (default: $DATA_DIR)
  --port PORT               PostgreSQL port (default: $PORT)
  --listen-addresses VALUE  PostgreSQL listen_addresses (default: *)
  --service-name NAME       systemd service name (default: $SERVICE_NAME)
  --credentials-file PATH   Root-only credentials file (default: $CREDENTIALS)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix|--data-dir|--port|--listen-addresses|--service-name|--credentials-file)
      key="$1"; shift; [[ $# -gt 0 ]] || { echo "missing value for $key" >&2; exit 2; }
      case "$key" in
        --prefix) PREFIX="$1" ;;
        --data-dir) DATA_DIR="$1" ;;
        --port) PORT="$1" ;;
        --listen-addresses) LISTEN_ADDRESSES="$1" ;;
        --service-name) SERVICE_NAME="$1" ;;
        --credentials-file) CREDENTIALS="$1" ;;
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

if [[ ! -f "$DATA_DIR/PG_VERSION" ]]; then
  password="$(openssl rand -base64 36 | tr -d '\n')"
  umask 077
  cat > "$CREDENTIALS" <<EOF
POSTGRES_USER=postgres
POSTGRES_PASSWORD=$password
POSTGRES_PORT=$PORT
EOF
  install -d -m 0755 "$PREFIX/rootfs/var/lib/postgresql/data" "$PREFIX/rootfs/dev/shm"
  mount --bind "$DATA_DIR" "$PREFIX/rootfs/var/lib/postgresql/data"
  mount --bind /dev/shm "$PREFIX/rootfs/dev/shm"
  cleanup_mounts() { umount "$PREFIX/rootfs/dev/shm" || true; umount "$PREFIX/rootfs/var/lib/postgresql/data" || true; }
  trap cleanup_mounts EXIT
  password_file="$DATA_DIR/.init-password"
  printf '%s\n' "$password" > "$password_file"
  chown "$RUN_UID:$RUN_GID" "$password_file"; chmod 0600 "$password_file"
  chroot --userspec="$RUN_UID:$RUN_GID" "$PREFIX/rootfs" /usr/lib/postgresql/17/bin/initdb \
    -D /var/lib/postgresql/data --username=postgres --pwfile=/var/lib/postgresql/data/.init-password \
    --auth-host=scram-sha-256 --auth-local=peer --no-instructions
  rm -f "$password_file"
  cat >> "$DATA_DIR/postgresql.conf" <<EOF
listen_addresses = '$LISTEN_ADDRESSES'
port = $PORT
password_encryption = 'scram-sha-256'
EOF
  cat >> "$DATA_DIR/pg_hba.conf" <<'EOF'
host all all 0.0.0.0/0 scram-sha-256
host all all ::0/0 scram-sha-256
EOF
  cleanup_mounts; trap - EXIT
  echo "Generated PostgreSQL password. It is stored in $CREDENTIALS (root only)."
else
  [[ -f "$CREDENTIALS" ]] || { echo "existing data directory requires credentials file: $CREDENTIALS" >&2; exit 1; }
fi

sed -e "s|@PREFIX@|$PREFIX|g" -e "s|@DATA_DIR@|$DATA_DIR|g" \
  -e "s|@RUN_UID@|$RUN_UID|g" -e "s|@RUN_GID@|$RUN_GID|g" \
  -e "s|@PORT@|$PORT|g" -e "s|@LISTEN_ADDRESSES@|$LISTEN_ADDRESSES|g" \
  "$SCRIPT_DIR/systemd/chroot-pg.service.in" > "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl start "$SERVICE_NAME"
echo "Installed $SERVICE_NAME. Check: systemctl status $SERVICE_NAME"
