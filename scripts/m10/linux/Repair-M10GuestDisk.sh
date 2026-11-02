#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 || $(id -u) -ne 0 ]]; then
  echo 'usage (as root): Repair-M10GuestDisk.sh SOURCE_RAW OUTPUT_RAW REPOSITORY_ROOT' >&2
  exit 2
fi
source_raw=$(readlink -f "$1")
output_directory=$(readlink -f "$(dirname "$2")")
output_raw="$output_directory/$(basename "$2")"
repository=$(readlink -f "$3")
[[ -d "$output_directory" && -f "$source_raw" && ! -e "$output_raw" ]]
[[ -f "$repository/guest/linux/configure-lan-cups.sh" ]]

temporary=$(mktemp -d /var/tmp/quirewire-m10-guest-repair.XXXXXX)
working="$temporary/working.raw"
mountpoint="$temporary/root"
mkdir "$mountpoint"
loop=''
root_partition=''
dev_bound=no
proc_bound=no
sys_bound=no

cleanup() {
  set +e
  [[ "$sys_bound" == yes ]] && umount "$mountpoint/sys"
  [[ "$proc_bound" == yes ]] && umount "$mountpoint/proc"
  [[ "$dev_bound" == yes ]] && umount "$mountpoint/dev"
  mountpoint -q "$mountpoint" && umount "$mountpoint"
  [[ -n "$loop" ]] && losetup -d "$loop"
  rm -f "$working"
  rmdir "$mountpoint" "$temporary" 2>/dev/null || true
}
trap cleanup EXIT

cp "$source_raw" "$working"
loop=$(losetup --find --show --partscan "$working")
for partition in "${loop}"p*; do
  [[ -b "$partition" ]] || continue
  if mount -o ro "$partition" "$mountpoint" 2>/dev/null; then
    if [[ -f "$mountpoint/etc/quirewire/guest.env" ]]; then
      root_partition=$partition
      umount "$mountpoint"
      break
    fi
    umount "$mountpoint"
  fi
done
[[ -n "$root_partition" ]] || {
  echo 'ERROR: the clone has no exact QuireWire guest root partition' >&2
  exit 1
}

mount "$root_partition" "$mountpoint"
grep -Fxq 'QUIREWIRE_GUEST_SCHEMA=quirewire.m4.guest.v1' \
  "$mountpoint/etc/quirewire/guest.env"
grep -Fxq 'QUEUE_NAME=QuireWire_DCP_L2600D' \
  "$mountpoint/etc/quirewire/guest.env"

install -m 0755 "$repository/guest/linux/configure-lan-cups.sh" \
  "$mountpoint/usr/local/lib/quirewire/configure-lan-cups.sh"
install -m 0755 "$repository/guest/linux/provision-base.sh" \
  "$mountpoint/usr/local/lib/quirewire/provision-base.sh"
install -m 0755 "$repository/guest/linux/firstboot.sh" \
  "$mountpoint/usr/local/lib/quirewire/firstboot.sh"

mount --bind /dev "$mountpoint/dev"
dev_bound=yes
mount -t proc proc "$mountpoint/proc"
proc_bound=yes
mount -t sysfs sysfs "$mountpoint/sys"
sys_bound=yes
chroot "$mountpoint" /usr/local/lib/quirewire/configure-lan-cups.sh
grep -Fqx '# BEGIN QUIREWIRE M10 QUEUE-ONLY LAN ACCESS' \
  "$mountpoint/etc/cups/cupsd.conf"
sync

umount "$mountpoint/sys"; sys_bound=no
umount "$mountpoint/proc"; proc_bound=no
umount "$mountpoint/dev"; dev_bound=no
umount "$mountpoint"
losetup -d "$loop"; loop=''
cp "$working" "$output_raw"
echo "M10 guest disk repair clone created: $output_raw"
