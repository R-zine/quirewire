#!/bin/bash
set -euo pipefail

queue=QuireWire_DCP_L2600D
mode=${1:---health}
case "$mode" in
  --health|--diagnostics) ;;
  *) echo "ERROR: expected --health or --diagnostics" >&2; exit 2 ;;
esac

state=not-configured
accepting=no
if lpstat -p "$queue" >/dev/null 2>&1; then
  state=$(lpstat -p "$queue" | awk '{print $4}' | tr -d '.')
  lpstat -a "$queue" 2>/dev/null | grep -q 'accepting requests' && accepting=yes
fi
usb=absent
lsusb -d 04f9:0567 >/dev/null 2>&1 && usb=present
cups_state=$(systemctl is-active cups.service 2>/dev/null || true)
ipp=fail
if [[ "$state" != not-configured ]] && ipptool -tv "ipp://localhost/printers/$queue" \
  /usr/share/cups/ipptool/get-printer-attributes.test >/dev/null 2>&1; then
  ipp=pass
fi
driver_mode=none
if [[ -r /var/lib/quirewire/driver-selection.env ]]; then
  driver_mode=$(sed -n 's/^driver_mode=//p' /var/lib/quirewire/driver-selection.env)
fi

printf 'schema=quirewire.m4.health.v1\n'
printf 'cups=%s\n' "$cups_state"
printf 'queue=%s\n' "$state"
printf 'accepting=%s\n' "$accepting"
printf 'ipp=%s\n' "$ipp"
printf 'usb=%s\n' "$usb"
printf 'driver_mode=%s\n' "$driver_mode"
printf 'physical_output=not_inferred\n'

if [[ "$mode" == --diagnostics ]]; then
  printf 'debian_version=%s\n' "$(cat /etc/debian_version)"
  printf 'architecture=%s\n' "$(dpkg --print-architecture)"
  printf 'cups_version=%s\n' "$(dpkg-query -W -f='${Version}' cups)"
  printf 'disk_root=%s\n' "$(df -P / | awk 'NR==2{print $5}')"
  printf 'jobs_begin\n'
  lpstat -W all -o "$queue" 2>/dev/null | tail -n 20 || true
  printf 'jobs_end\n'
  printf 'cups_log_begin\n'
  journalctl -u cups.service -n 30 --no-pager 2>/dev/null \
    | sed -E 's/(serial=)[^&[:space:]]+/\1REDACTED/Ig' || true
  printf 'cups_log_end\n'
fi

[[ "$cups_state" == active && "$state" == idle && "$accepting" == yes && "$ipp" == pass ]]
