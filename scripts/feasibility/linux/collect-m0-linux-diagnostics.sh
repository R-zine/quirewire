#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage:
  bash collect-m0-linux-diagnostics.sh [--queue QUEUE] [--usb-id VID:PID]
      [--ipp-uri URI] [--output-dir DIRECTORY]

Read-only collection for the existing Linux/CUPS/USB printer used by M0.
Run once as the normal user and, if CUPS logs are unreadable, once with sudo.
The output can contain host names, IP addresses, USB serials, and job data.
USAGE
}

queue=''
usb_id=''
ipp_uri=''
output_dir=''

while (($# > 0)); do
  case "$1" in
    --queue)
      (($# >= 2)) || { echo 'ERROR: --queue needs a value.' >&2; exit 64; }
      queue=$2
      shift 2
      ;;
    --usb-id)
      (($# >= 2)) || { echo 'ERROR: --usb-id needs VID:PID.' >&2; exit 64; }
      usb_id=$2
      shift 2
      ;;
    --ipp-uri)
      (($# >= 2)) || { echo 'ERROR: --ipp-uri needs a value.' >&2; exit 64; }
      ipp_uri=$2
      shift 2
      ;;
    --output-dir)
      (($# >= 2)) || { echo 'ERROR: --output-dir needs a value.' >&2; exit 64; }
      output_dir=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -n $queue && ! $queue =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo 'ERROR: queue may contain only letters, digits, dot, underscore, and hyphen.' >&2
  exit 64
fi
if [[ -n $usb_id && ! $usb_id =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}$ ]]; then
  echo 'ERROR: --usb-id must use four hexadecimal VID digits, a colon, and four PID digits.' >&2
  exit 64
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ -z $output_dir ]]; then
  output_dir="$script_dir/../../../artifacts/m0/linux"
fi
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd -P)
umask 077
stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
report="$output_dir/${stamp}-linux-diagnostics.txt"

exec > >(tee -a -- "$report") 2>&1

section() {
  printf '\n===== %s =====\n' "$1"
}

run() {
  printf '$'
  printf ' %q' "$@"
  printf '\n'
  "$@"
  status=$?
  if ((status != 0)); then
    printf '[exit %d]\n' "$status"
  fi
  return 0
}

run_shell_readonly() {
  description=$1
  command_text=$2
  printf '$ %s\n' "$description"
  bash -o pipefail -c "$command_text"
  status=$?
  if ((status != 0)); then
    printf '[exit %d]\n' "$status"
  fi
  return 0
}

section 'scope and timestamp'
printf 'Schema: quirewire.m0.linux-diagnostics.v1\n'
printf 'Collected UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'Queue requested: %s\n' "${queue:-<not specified>}"
printf 'USB VID:PID requested: %s\n' "${usb_id:-<not specified>}"
printf 'IPP URI requested: %s\n' "${ipp_uri:-<not specified>}"
printf 'This is read-only software evidence and cannot prove that paper printed.\n'

section 'operating system and architecture'
run uname -a
run uname -m
if [[ -r /etc/os-release ]]; then run cat /etc/os-release; fi
if command -v dpkg >/dev/null 2>&1; then run dpkg --print-architecture; run dpkg --print-foreign-architectures; fi
if command -v rpm >/dev/null 2>&1; then run rpm --eval '%{_arch}'; fi

section 'network identity and listeners'
run hostname
if command -v hostnamectl >/dev/null 2>&1; then run hostnamectl; fi
if command -v ip >/dev/null 2>&1; then run ip -brief address; fi
if command -v ss >/dev/null 2>&1; then run ss -ltnp; fi

section 'CUPS versions and service state'
for command_name in cups-config cupsd cupsctl lpstat lpoptions lpadmin lpinfo lp ipptool; do
  if command -v "$command_name" >/dev/null 2>&1; then
    printf '%s: %s\n' "$command_name" "$(command -v "$command_name")"
  else
    printf '%s: NOT FOUND\n' "$command_name"
  fi
done
if command -v cups-config >/dev/null 2>&1; then run cups-config --version; fi
if command -v cupsd >/dev/null 2>&1; then run cupsd -v; fi
if command -v systemctl >/dev/null 2>&1; then run systemctl --no-pager --full status cups.service; fi
if command -v cupsctl >/dev/null 2>&1; then run cupsctl; fi

section 'CUPS queues, devices, drivers, and jobs'
if command -v lpstat >/dev/null 2>&1; then
  run lpstat -t
  run lpstat -v
  run lpstat -W all -o
fi
if command -v lpinfo >/dev/null 2>&1; then
  run lpinfo -v
fi

if [[ -n $queue ]]; then
  if command -v lpstat >/dev/null 2>&1; then
    run lpstat -p "$queue" -l
    run lpstat -v "$queue"
    run lpstat -W all -o "$queue"
  fi
  if command -v lpoptions >/dev/null 2>&1; then
    run lpoptions -p "$queue"
    run lpoptions -p "$queue" -l
  fi
fi

section 'installed print packages and queue driver metadata'
if command -v dpkg-query >/dev/null 2>&1; then
  run_shell_readonly "dpkg-query (CUPS/Brother/print packages)" \
    "dpkg-query -W -f='\${binary:Package}\t\${Version}\t\${Architecture}\n' 2>/dev/null | grep -Ei 'cups|brother|brlaser|dcp|l2600|printer-driver|ghostscript' || true"
fi
if command -v rpm >/dev/null 2>&1; then
  run_shell_readonly "rpm (CUPS/Brother/print packages)" \
    "rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n' | grep -Ei 'cups|brother|brlaser|dcp|l2600|printer|ghostscript' || true"
fi
if [[ -n $queue && -r /etc/cups/printers.conf ]]; then
  run_shell_readonly "selected queue block from /etc/cups/printers.conf" \
    "awk -v q='$queue' '\$0 == \"<Printer \" q \">\" {inside=1} inside {print} inside && \$0 == \"</Printer>\" {exit}' /etc/cups/printers.conf"
else
  printf '/etc/cups/printers.conf queue block unavailable (specify --queue and run read-only collection with sufficient permission).\n'
fi
if [[ -n $queue && -r /etc/cups/ppd/$queue.ppd ]]; then
  run_shell_readonly "selected PPD identity and filters" \
    "grep -E '^\\*(NickName|ModelName|Manufacturer|cupsFilter|cupsFilter2|LanguageVersion|FileVersion):' '/etc/cups/ppd/$queue.ppd' || true"
else
  printf 'Selected PPD metadata unavailable; a driverless queue may legitimately have no PPD.\n'
fi

section 'USB inventory'
if command -v lsusb >/dev/null 2>&1; then
  run lsusb
  if [[ -n $usb_id ]]; then
    run lsusb -v -d "$usb_id"
  fi
else
  printf 'lsusb: NOT FOUND (install the distribution usbutils package for VID:PID evidence).\n'
fi
if command -v udevadm >/dev/null 2>&1; then
  run_shell_readonly 'udev USB printer properties' \
    "for d in /sys/bus/usb/devices/*; do [ -r \"\$d/idVendor\" ] || continue; [ -r \"\$d/idProduct\" ] || continue; printf '%s ' \"\$d\"; tr -d '\\n' < \"\$d/idVendor\"; printf ':'; cat \"\$d/idProduct\"; done"
fi

section 'CUPS IPP printer attributes'
if [[ -z $ipp_uri && -n $queue ]]; then
  ipp_uri="ipp://localhost/printers/$queue"
fi
if [[ -n $ipp_uri ]] && command -v ipptool >/dev/null 2>&1; then
  datadir=''
  if command -v cups-config >/dev/null 2>&1; then datadir=$(cups-config --datadir 2>/dev/null || true); fi
  test_file=''
  for candidate in "$datadir/ipptool/get-printer-attributes.test" /usr/share/cups/ipptool/get-printer-attributes.test; do
    if [[ -f $candidate ]]; then test_file=$candidate; break; fi
  done
  if [[ -n $test_file ]]; then
    run ipptool -tv "$ipp_uri" "$test_file"
  else
    printf 'get-printer-attributes.test was not found under the CUPS data directory.\n'
  fi
else
  printf 'IPP attributes skipped: queue/URI missing or ipptool unavailable.\n'
fi

section 'effective CUPS configuration'
for config in /etc/cups/cupsd.conf /etc/cups/cups-files.conf; do
  if [[ -r $config ]]; then
    run_shell_readonly "active directives in $config" "grep -Ev '^[[:space:]]*(#|$)' '$config'"
  else
    printf '%s is not readable in this execution context.\n' "$config"
  fi
done

section 'recent CUPS logs'
if command -v journalctl >/dev/null 2>&1; then
  run journalctl --no-pager --since '-4 hours' -u cups.service
fi
if [[ -r /var/log/cups/error_log ]]; then
  run tail -n 400 /var/log/cups/error_log
else
  printf '/var/log/cups/error_log is not readable. Re-run this read-only collector with sudo if needed.\n'
fi

section 'review notice'
printf 'Report: %s\n' "$report"
printf 'Review for host names, addresses, USB serials, document names, and user names before sharing.\n'
printf 'Physical output must be recorded separately with Record-M0Acceptance.ps1.\n'

