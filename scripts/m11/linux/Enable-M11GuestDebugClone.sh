#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 || $(id -u) -ne 0 ]]; then
  echo 'usage (as root): Enable-M11GuestDebugClone.sh RAW_CLONE' >&2
  exit 2
fi
raw_clone=$(readlink -f "$1")
[[ -f "$raw_clone" ]] || {
  echo 'ERROR: the exact raw diagnostic clone does not exist' >&2
  exit 1
}

temporary=$(mktemp -d /var/tmp/quirewire-m11-debug-clone.XXXXXX)
mountpoint="$temporary/root"
mkdir "$mountpoint"
loop=
created_partition_nodes=()
cleanup() {
  set +e
  mountpoint -q "$mountpoint" && umount "$mountpoint"
  [[ -n "$loop" ]] && losetup -d "$loop"
  if [[ ${#created_partition_nodes[@]} -gt 0 ]]; then
    rm -f "${created_partition_nodes[@]}"
  fi
  rmdir "$mountpoint" "$temporary" 2>/dev/null || true
}
trap cleanup EXIT

loop=$(losetup --find --show --partscan "$raw_clone")
while read -r partition kind device_number; do
  [[ "$kind" == part && ! -b "$partition" ]] || continue
  major=${device_number%:*}
  minor=${device_number#*:}
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]
  mknod "$partition" b "$major" "$minor"
  created_partition_nodes+=("$partition")
done < <(lsblk -lnpo NAME,TYPE,MAJ:MIN "$loop")

root_partition=
for partition in "${loop}"p*; do
  [[ -b "$partition" ]] || continue
  if mount "$partition" "$mountpoint" 2>/dev/null; then
    if [[ -f "$mountpoint/etc/quirewire/guest.env" ]]; then
      root_partition=$partition
      break
    fi
    umount "$mountpoint"
  fi
done
[[ -n "$root_partition" ]] || {
  echo 'ERROR: the clone has no exact QuireWire guest root partition' >&2
  exit 1
}
grep -Fxq 'QUIREWIRE_GUEST_SCHEMA=quirewire.m4.guest.v1' \
  "$mountpoint/etc/quirewire/guest.env"
grep -Fxq 'QUEUE_NAME=QuireWire_DCP_L2600D' \
  "$mountpoint/etc/quirewire/guest.env"
[[ ! -e "$mountpoint/var/lib/quirewire/m11-debug-clone" ]]

unit="$mountpoint/usr/lib/systemd/system/airsaned.service"
[[ $(grep -Fc 'ExecStart=/usr/local/bin/airsaned ' "$unit") -eq 1 ]]
[[ $(grep -Fc -- '--debug=true' "$unit") -eq 0 ]]
sed -i 's#^ExecStart=/usr/local/bin/airsaned #ExecStart=/usr/local/bin/airsaned --debug=true #' "$unit"

saned_uid=$(chroot "$mountpoint" id -u saned)
saned_gid=$(chroot "$mountpoint" id -g saned)
install -o "$saned_uid" -g "$saned_gid" -m 0644 /dev/null \
  "$mountpoint/var/log/quirewire/airsaned-debug.log"
install -d -m 0755 "$mountpoint/etc/systemd/system/airsaned.service.d"
cat > "$mountpoint/etc/systemd/system/airsaned.service.d/quirewire-diagnostic.conf" <<'EOF'
[Service]
StandardOutput=append:/var/log/quirewire/airsaned-debug.log
StandardError=append:/var/log/quirewire/airsaned-debug.log
EOF
chmod 0644 "$mountpoint/etc/systemd/system/airsaned.service.d/quirewire-diagnostic.conf"
printf '%s\n' 'schema=quirewire.m11.debug-clone.v1' \
  > "$mountpoint/var/lib/quirewire/m11-debug-clone"
chmod 0644 "$mountpoint/var/lib/quirewire/m11-debug-clone"
sync
echo 'AirSane debug logging enabled only in the exact disposable raw clone.'
