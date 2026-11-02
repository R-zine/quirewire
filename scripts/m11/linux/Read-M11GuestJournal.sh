#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 || $(id -u) -ne 0 ]]; then
  echo 'usage (as root): Read-M11GuestJournal.sh RAW_DISK SYSTEMD_UNIT' >&2
  exit 2
fi
raw_disk=$(readlink -f "$1")
unit=$2
[[ -f "$raw_disk" && "$unit" =~ ^[A-Za-z0-9@_.-]+\.service$ ]] || {
  echo 'ERROR: expected one raw disk and one exact systemd service unit' >&2
  exit 1
}

temporary=$(mktemp -d /var/tmp/quirewire-m11-journal.XXXXXX)
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

loop=$(losetup --find --show --read-only --partscan "$raw_disk")
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
  if mount -o ro "$partition" "$mountpoint" 2>/dev/null; then
    if [[ -f "$mountpoint/etc/quirewire/guest.env" ]]; then
      root_partition=$partition
      break
    fi
    umount "$mountpoint"
  fi
done
[[ -n "$root_partition" ]] || {
  echo 'ERROR: the disk has no exact QuireWire guest root partition' >&2
  exit 1
}
grep -Fxq 'QUIREWIRE_GUEST_SCHEMA=quirewire.m4.guest.v1' \
  "$mountpoint/etc/quirewire/guest.env"
grep -Fxq 'QUEUE_NAME=QuireWire_DCP_L2600D' \
  "$mountpoint/etc/quirewire/guest.env"
[[ -d "$mountpoint/var/log/journal" ]]

chroot "$mountpoint" /usr/bin/journalctl \
  --directory=/var/log/journal --unit="$unit" --lines=200 \
  --no-pager --output=short-iso
