#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/versions.env"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
ROOTFS="$BUILD_DIR/rootfs"

[[ "$(uname -m)" == "x86_64" ]] || { echo 'only amd64 hosts are supported' >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo 'run build-rootfs.sh with sudo' >&2; exit 1; }
command -v debootstrap >/dev/null || { echo 'debootstrap is required' >&2; exit 1; }

rm -rf "$ROOTFS"
mkdir -p "$ROOTFS"
debootstrap --arch=amd64 --variant=minbase "$DEBIAN_SUITE" "$ROOTFS" "$DEBIAN_MIRROR"

install -d -m 0755 "$ROOTFS/usr/share/keyrings"
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor > "$ROOTFS/usr/share/keyrings/postgresql-pgdg.gpg"
cat > "$ROOTFS/etc/apt/sources.list.d/pgdg.list" <<EOF
deb [signed-by=/usr/share/keyrings/postgresql-pgdg.gpg] https://apt.postgresql.org/pub/repos/apt $DEBIAN_SUITE-pgdg main
EOF

cat > "$ROOTFS/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
chmod 0755 "$ROOTFS/usr/sbin/policy-rc.d"

chroot "$ROOTFS" /bin/bash -ec '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates locales postgresql-17="'"$POSTGRES_PACKAGE_VERSION"'" postgresql-client-17="'"$POSTGRES_PACKAGE_VERSION"'"
  locale-gen C.UTF-8
  rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* /var/tmp/*
  rm -rf /var/lib/postgresql/17/main /etc/postgresql/17/main
  rm -f /usr/sbin/policy-rc.d /etc/machine-id
'

actual_version="$(chroot "$ROOTFS" dpkg-query -W -f='${Version}' postgresql-17)"
[[ "$actual_version" == "$POSTGRES_PACKAGE_VERSION" ]] || { echo "PostgreSQL version mismatch: $actual_version" >&2; exit 1; }
cat > "$ROOTFS/etc/chroot-pg-build.env" <<EOF
POSTGRES_MAJOR=$POSTGRES_MAJOR
POSTGRES_PACKAGE_VERSION=$actual_version
EOF
mkdir -p "$ROOTFS/var/lib/postgresql/data" "$ROOTFS/dev/shm"
chmod 0755 "$ROOTFS/var/lib/postgresql" "$ROOTFS/var/lib/postgresql/data"
echo "rootfs ready: $ROOTFS"

