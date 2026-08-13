#!/usr/bin/env bash
set -euo pipefail

ROOTFS="${1:?usage: verify-rootfs.sh <rootfs>}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/versions.env"

[[ -x "$ROOTFS/usr/lib/postgresql/17/bin/postgres" ]]
[[ -x "$ROOTFS/usr/lib/postgresql/17/bin/psql" ]]
[[ -x "$ROOTFS/usr/lib/postgresql/17/bin/pg_isready" ]]
actual="$(chroot "$ROOTFS" dpkg-query -W -f='${Version}' postgresql-17)"
[[ "$actual" == "$POSTGRES_PACKAGE_VERSION" ]] || { echo "expected $POSTGRES_PACKAGE_VERSION, got $actual" >&2; exit 1; }
chroot "$ROOTFS" /usr/lib/postgresql/17/bin/postgres --version | grep -Eq 'PostgreSQL\)? 17\.'
echo 'rootfs verification passed'
