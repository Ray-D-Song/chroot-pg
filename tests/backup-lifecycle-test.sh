#!/usr/bin/env bash
set -euo pipefail
# Root in a disposable user/mount namespace is sufficient; no host mounts change.
if [[ "${BACKUP_TEST_NAMESPACE:-}" != "$(readlink /proc/self/ns/mnt)" ]]; then
  namespace_args=(--mount --propagation private)
  if [[ $EUID != 0 ]]; then namespace_args+=(--user --map-root-user); fi
  exec unshare "${namespace_args[@]}" bash -c 'export BACKUP_TEST_NAMESPACE="$(readlink /proc/self/ns/mnt)"; exec /bin/bash "$@"' -- "$0" "$@"
fi
helper="$(readlink -f "$1")"
engine="$2"
fixture="$(mktemp -d)"
trap 'status=$?; if (( status != 0 )); then cat "$fixture/log" >&2; fi; rm -rf "$fixture"' EXIT
root="$fixture/root";backup="$fixture/backups";data="$fixture/data"
mkdir -p "$root/usr/bin" "$root/etc" "$backup/full" "$data" "$fixture/bin" "$root/run" "$root/var/lib/mysql"
touch "$root/usr/bin/xtrabackup" "$root/etc/hosts";chmod +x "$root/usr/bin/xtrabackup"
printf 'MYSQL_PASSWORD=test\nPOSTGRES_PASSWORD=test\n' > "$fixture/credentials"
cat > "$fixture/bin/id" <<'SH'
#!/usr/bin/env bash
if [[ "${2:-}" == chroot-pg ]]; then echo 0;else /usr/bin/id "$@";fi
SH
cat > "$fixture/bin/chroot" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${BACKUP_TEST_MARKER:-}" ]]; then touch "$BACKUP_TEST_MARKER"; fi
if [[ "${BACKUP_TEST_HOLD:-0}" == 1 ]]; then exec sleep 30; fi
exit "${BACKUP_TEST_EXIT:-0}"
SH
chmod +x "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
args=(--rootfs "$root" --data-dir "$data" --credentials-file "$fixture/credentials" --backup-dir "$backup")
if [[ "$engine" == mysql ]];then
 point="$root/mnt/chroot-mysql-backup";datapoint="$root/var/lib/mysql";args+=(decompress)
else
 point="$root/mnt/chroot-pg-backup";datapoint="$root/var/lib/postgresql";args+=(--set-id test --target "$backup/full" verify)
fi
assert_clean(){ ! mountpoint -q "$point";! mountpoint -q "$datapoint"; }
bash "$helper" "${args[@]}" > "$fixture/result" 2> "$fixture/log"
assert_clean
grep -q '"path"' "$fixture/result"
if [[ "$engine" == postgres ]]; then
  bash "$helper" --rootfs "$root" --data-dir "$data" --credentials-file "$fixture/credentials" --backup-dir "$backup" --set-id test --output "$backup/sets/test/incremental/inc-1" --base-manifest "$backup/full/backup_manifest" backup-incremental > /dev/null 2> "$fixture/log"
  [[ "$(stat -c %a "$backup/sets/test/incremental")" == 750 ]]
  assert_clean
fi
# Failure must propagate, and neither mount may escape its namespace.
if BACKUP_TEST_EXIT=7 bash "$helper" "${args[@]}" > /dev/null 2> "$fixture/log";then echo 'tool failure was hidden' >&2;exit 1;fi
assert_clean
for signal in TERM KILL;do
 export BACKUP_TEST_MARKER="$fixture/ready";rm -f "$BACKUP_TEST_MARKER"
 BACKUP_TEST_HOLD=1 setsid bash "$helper" "${args[@]}" > /dev/null 2> "$fixture/log" & pid=$!
 for i in {1..100};do [[ -f "$BACKUP_TEST_MARKER" ]] && break;sleep .02;done
 [[ -f "$BACKUP_TEST_MARKER" ]] || { cat "$fixture/log";exit 1; }
 assert_clean
 # The rootfs lock must reject another invocation even though mounts are private.
 if bash "$helper" "${args[@]}" > /dev/null 2> "$fixture/second";then echo 'concurrent tool accepted' >&2;exit 1;fi
 grep -q 'another backup tool' "$fixture/second"
 kill -"$signal" -- -"$pid"
 wait "$pid" 2>/dev/null || true
 assert_clean
 unset BACKUP_TEST_MARKER
 # A subsequent invocation succeeds after either kind of interruption.
 bash "$helper" "${args[@]}" > /dev/null 2> "$fixture/log"
 assert_clean
done
# Reclaim known legacy mounts but preserve unknown mounts.
mkdir -p "$point" "$datapoint" "$fixture/unknown"
mount --bind "$backup" "$point"
mount --bind "$backup" "$point"
bash "$helper" "${args[@]}" > /dev/null 2> "$fixture/log"
assert_clean
mount --bind "$fixture/unknown" "$point"
if bash "$helper" "${args[@]}" > /dev/null 2> "$fixture/log";then echo 'unknown mount accepted' >&2;exit 1;fi
mountpoint -q "$point"
umount "$point"
echo "$engine helper mount lifecycle passed"
