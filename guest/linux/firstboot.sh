#!/bin/bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: first boot finalization requires root" >&2
  exit 1
fi
install -d -m 0755 /var/lib/quirewire /var/log/quirewire
exec > >(tee -a /var/log/quirewire/firstboot.log) 2>&1

systemctl is-active --quiet cups.service
systemctl is-active --quiet ssh.service
/usr/sbin/cupsctl --share-printers --no-remote-admin --no-remote-any
/usr/local/lib/quirewire/configure-lan-cups.sh
/usr/sbin/cupsd -t
systemctl restart cups.service
sleep 2
systemctl is-active --quiet cups.service

{
  echo 'schema=quirewire.m4.base-complete.v1'
  echo "completed_at=$(date --iso-8601=seconds)"
  echo "cups_version=$(dpkg-query -W -f='${Version}' cups)"
  echo "architecture=$(dpkg --print-architecture)"
} > /var/lib/quirewire/base-complete
systemctl disable quirewire-firstboot.service
sync
systemctl poweroff
