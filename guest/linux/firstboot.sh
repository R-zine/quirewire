#!/bin/bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: first boot finalization requires root" >&2
  exit 1
fi
install -d -m 0755 /var/lib/printbridge /var/log/printbridge
exec > >(tee -a /var/log/printbridge/firstboot.log) 2>&1

systemctl is-active --quiet cups.service
systemctl is-active --quiet ssh.service
/usr/sbin/cupsctl --share-printers --no-remote-admin --no-remote-any
/usr/sbin/cupsd -t
systemctl restart cups.service
sleep 2
systemctl is-active --quiet cups.service

{
  echo 'schema=printbridge.m4.base-complete.v1'
  echo "completed_at=$(date --iso-8601=seconds)"
  echo "cups_version=$(dpkg-query -W -f='${Version}' cups)"
  echo "architecture=$(dpkg --print-architecture)"
} > /var/lib/printbridge/base-complete
systemctl disable printbridge-firstboot.service
sync
systemctl poweroff
