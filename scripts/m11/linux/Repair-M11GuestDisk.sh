#!/bin/bash
set -euo pipefail

if [[ $# -ne 6 || $(id -u) -ne 0 ]]; then
  echo 'usage (as root): Repair-M11GuestDisk.sh SOURCE_RAW OUTPUT_RAW REPOSITORY_ROOT BRSCAN_DEB AIRSANE_SOURCE AIRSANE_PATCH' >&2
  exit 2
fi
source_raw=$(readlink -f "$1")
output_directory=$(readlink -f "$(dirname "$2")")
output_raw="$output_directory/$(basename "$2")"
repository=$(readlink -f "$3")
brscan_deb=$(readlink -f "$4")
airsane_source=$(readlink -f "$5")
airsane_patch=$(readlink -f "$6")
manifest="$repository/guest/manifests/scanner-dcpl2600d.env"
provisioner="$repository/guest/linux/provision-scanner.sh"
[[ -d "$output_directory" && -f "$source_raw" && ! -e "$output_raw" ]]
[[ -f "$manifest" && -x "$provisioner" && -f "$brscan_deb" && \
  -f "$airsane_source" && -f "$airsane_patch" ]]

temporary=$(mktemp -d /var/tmp/quirewire-m11-guest-repair.XXXXXX)
working="$temporary/working.raw"
mountpoint="$temporary/root"
mkdir "$mountpoint"
loop=
root_partition=
dev_bound=no
proc_bound=no
sys_bound=no
policy_created=no
resolv_replaced=no
created_partition_nodes=()

cleanup() {
  set +e
  if [[ "$resolv_replaced" == yes && -e "$temporary/resolv.conf.saved" ]]; then
    rm -f "$mountpoint/etc/resolv.conf"
    cp -a "$temporary/resolv.conf.saved" "$mountpoint/etc/resolv.conf"
  fi
  if [[ "$policy_created" == yes ]]; then
    rm -f "$mountpoint/usr/sbin/policy-rc.d"
  fi
  [[ "$sys_bound" == yes ]] && umount "$mountpoint/sys"
  [[ "$proc_bound" == yes ]] && umount "$mountpoint/proc"
  [[ "$dev_bound" == yes ]] && umount "$mountpoint/dev"
  mountpoint -q "$mountpoint" && umount "$mountpoint"
  [[ -n "$loop" ]] && losetup -d "$loop"
  if [[ ${#created_partition_nodes[@]} -gt 0 ]]; then
    rm -f "${created_partition_nodes[@]}"
  fi
  rm -f "$working"
  rmdir "$mountpoint" "$temporary" 2>/dev/null || true
}
trap cleanup EXIT

cp "$source_raw" "$working"
loop=$(losetup --find --show --partscan "$working")
while read -r partition kind device_number; do
  [[ "$kind" == part && ! -b "$partition" ]] || continue
  major=${device_number%:*}
  minor=${device_number#*:}
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]
  mknod "$partition" b "$major" "$minor"
  created_partition_nodes+=("$partition")
done < <(lsblk -lnpo NAME,TYPE,MAJ:MIN "$loop")
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

input="$mountpoint/var/tmp/quirewire-m11-input"
install -d -m 0700 "$input"
install -m 0755 "$provisioner" "$mountpoint/usr/local/lib/quirewire/provision-scanner.sh"
install -m 0600 "$manifest" "$input/scanner.env"
install -m 0600 "$brscan_deb" "$input/$(basename "$brscan_deb")"
install -m 0600 "$airsane_source" "$input/$(basename "$airsane_source")"
install -m 0600 "$airsane_patch" "$input/$(basename "$airsane_patch")"

if [[ ! -e "$mountpoint/usr/sbin/policy-rc.d" ]]; then
  printf '#!/bin/sh\nexit 101\n' > "$mountpoint/usr/sbin/policy-rc.d"
  chmod 0755 "$mountpoint/usr/sbin/policy-rc.d"
  policy_created=yes
fi
mount --bind /dev "$mountpoint/dev"
dev_bound=yes
mount -t proc proc "$mountpoint/proc"
proc_bound=yes
mount -t sysfs sysfs "$mountpoint/sys"
sys_bound=yes

cp -a "$mountpoint/etc/resolv.conf" "$temporary/resolv.conf.saved"
rm -f "$mountpoint/etc/resolv.conf"
cp -L /etc/resolv.conf "$mountpoint/etc/resolv.conf"
resolv_replaced=yes

chroot "$mountpoint" /usr/local/lib/quirewire/provision-scanner.sh \
  --manifest /var/tmp/quirewire-m11-input/scanner.env \
  --brscan-deb "/var/tmp/quirewire-m11-input/$(basename "$brscan_deb")" \
  --airsane-source "/var/tmp/quirewire-m11-input/$(basename "$airsane_source")" \
  --airsane-patch "/var/tmp/quirewire-m11-input/$(basename "$airsane_patch")" \
  --offline

test -x "$mountpoint/usr/local/bin/airsaned"
grep -Fxq 'schema=quirewire.m11.scanner-selection.v1' \
  "$mountpoint/var/lib/quirewire/scanner-selection.env"
grep -Fxq "airsane_patch_sha256=$(sha256sum "$airsane_patch" | cut -d' ' -f1)" \
  "$mountpoint/var/lib/quirewire/scanner-selection.env"
grep -Fxq 'MDNS_ANNOUNCE=false' "$mountpoint/etc/default/airsane"
grep -Fxq 'allow 10.0.0.0/8' "$mountpoint/etc/airsane/access.conf"
grep -Fxq 'allow 172.16.0.0/12' "$mountpoint/etc/airsane/access.conf"
grep -Fxq 'allow 192.168.0.0/16' "$mountpoint/etc/airsane/access.conf"
test -L "$mountpoint/etc/systemd/system/airsaned.service" -o \
  -L "$mountpoint/etc/systemd/system/multi-user.target.wants/airsaned.service"

rm -f "$mountpoint/etc/resolv.conf"
cp -a "$temporary/resolv.conf.saved" "$mountpoint/etc/resolv.conf"
resolv_replaced=no
rm -rf --one-file-system "$input"
if [[ "$policy_created" == yes ]]; then
  rm -f "$mountpoint/usr/sbin/policy-rc.d"
  policy_created=no
fi
sync

umount "$mountpoint/sys"; sys_bound=no
umount "$mountpoint/proc"; proc_bound=no
umount "$mountpoint/dev"; dev_bound=no
umount "$mountpoint"
losetup -d "$loop"; loop=
if [[ ${#created_partition_nodes[@]} -gt 0 ]]; then
  rm -f "${created_partition_nodes[@]}"
  created_partition_nodes=()
fi
cp "$working" "$output_raw"
echo "M11 scanner-enabled guest disk clone created: $output_raw"
