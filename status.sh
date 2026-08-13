#!/usr/bin/env bash
set -euo pipefail
systemctl status "${1:-chroot-pg}"

