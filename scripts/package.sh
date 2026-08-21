#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/versions.env"
VERSION="${1:?usage: package.sh <bundle-version>}"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/build}"
ROOTFS="$BUILD_DIR/rootfs"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
NAME="chroot-pg-$VERSION-linux-amd64"
STAGE="$BUILD_DIR/$NAME"

[[ -x "$ROOTFS/usr/lib/postgresql/17/bin/postgres" ]] || { echo 'build rootfs first' >&2; exit 1; }
rm -rf "$STAGE"
mkdir -p "$STAGE/systemd" "$STAGE/bin"
cp -a "$ROOTFS" "$STAGE/rootfs"
cp "$ROOT_DIR/install.sh" "$ROOT_DIR/uninstall.sh" "$ROOT_DIR/status.sh" "$STAGE/"
cp "$ROOT_DIR/bin/chroot-pg-run" "$STAGE/bin/"
cp "$ROOT_DIR/bin/chroot-pg-backup" "$STAGE/bin/"
cp "$ROOT_DIR/systemd/chroot-pg.service.in" "$STAGE/systemd/"
cp "$ROOT_DIR/README.md" "$STAGE/"
chmod 0755 "$STAGE"/*.sh "$STAGE/bin/chroot-pg-run" "$STAGE/bin/chroot-pg-backup"
cat > "$STAGE/manifest.json" <<EOF
{"bundle_version":"$VERSION","architecture":"amd64","rootfs":"debian-$DEBIAN_SUITE","postgres_package_version":"$POSTGRES_PACKAGE_VERSION"}
EOF
mkdir -p "$DIST_DIR"
tar --numeric-owner -C "$BUILD_DIR" -czf "$DIST_DIR/$NAME.tar.gz" "$NAME"
(cd "$DIST_DIR" && sha256sum "$NAME.tar.gz" > SHA256SUMS)
echo "$DIST_DIR/$NAME.tar.gz"
