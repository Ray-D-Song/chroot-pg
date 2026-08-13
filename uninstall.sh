#!/usr/bin/env bash
set -euo pipefail

PREFIX=/opt/chroot-pg
DATA_DIR=/var/lib/chroot-pg/data
CREDENTIALS=/etc/chroot-pg/credentials
SERVICE_NAME=chroot-pg
PURGE_DATA=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix|--data-dir|--service-name|--credentials-file)
      key="$1"; shift; [[ $# -gt 0 ]] || exit 2
      case "$key" in --prefix) PREFIX="$1" ;; --data-dir) DATA_DIR="$1" ;; --service-name) SERVICE_NAME="$1" ;; --credentials-file) CREDENTIALS="$1" ;; esac
      shift ;;
    --purge-data) PURGE_DATA=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo 'run uninstall.sh with sudo or as root' >&2; exit 1; }
[[ "$PREFIX" == /opt/* && "$PREFIX" != /opt ]] || { echo 'refusing unsafe prefix' >&2; exit 2; }
[[ "$DATA_DIR" == /var/lib/* && "$DATA_DIR" != /var/lib ]] || { echo 'refusing unsafe data directory' >&2; exit 2; }
[[ "$CREDENTIALS" == /etc/* && "$CREDENTIALS" != /etc ]] || { echo 'refusing unsafe credentials file' >&2; exit 2; }

systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
rm -f "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload
rm -rf "$PREFIX"
if [[ "$PURGE_DATA" == true ]]; then
  rm -rf "$DATA_DIR"
  rm -f "$CREDENTIALS"
  echo "Removed service, rootfs, credentials, and data directory."
else
  echo "Removed service and rootfs. Data and credentials were retained for a future reinstall."
fi
