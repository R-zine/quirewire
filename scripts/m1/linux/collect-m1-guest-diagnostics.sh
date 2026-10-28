#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'EOF'
Usage: collect-m1-guest-diagnostics.sh [--queue NAME] [--usb-id VID:PID]

Read-only M1 Debian guest diagnostics. USB serials in CUPS device URIs are
redacted. A completed job is not evidence that a page physically printed.
EOF
}

queue='DCPL2600D'
usb_id='04f9:0567'
while (($#)); do
  case "$1" in
    --queue)
      [[ $# -ge 2 ]] || { echo 'Missing value for --queue.' >&2; exit 2; }
      queue=$2
      shift 2
      ;;
    --usb-id)
      [[ $# -ge 2 ]] || { echo 'Missing value for --usb-id.' >&2; exit 2; }
      usb_id=$2
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ $queue =~ ^[A-Za-z0-9_.-]+$ ]] || { echo 'Queue contains unsupported characters.' >&2; exit 2; }
[[ $usb_id =~ ^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{4}$ ]] || { echo 'USB ID must be VID:PID.' >&2; exit 2; }

section() { printf '\n== %s ==\n' "$1"; }
redact_serial() {
  sed -E 's/([?&]serial=)[^&[:space:]]+/\1REDACTED/g; s/(SerialNumber=)[^[:space:]]+/\1REDACTED/g'
}
run_optional() {
  local label=$1
  shift
  printf '%s: ' "$label"
  if command -v "$1" >/dev/null 2>&1; then
    "$@" 2>&1 || printf '[command exited %s]\n' "$?"
  else
    printf '[command unavailable]\n'
  fi
}

section 'scope'
printf 'Collected UTC: %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
printf 'Mode: read-only; physical output is never inferred\n'

section 'operating system and resources'
if [[ -r /etc/os-release ]]; then
  grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release || true
fi
uname -srmo
run_optional 'Memory' free -h
run_optional 'Root filesystem' df -h /
run_optional 'Uptime' uptime

section 'packages'
if command -v dpkg-query >/dev/null 2>&1; then
  dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' \
    cups cups-client cups-daemon cups-ipp-utils libc6:i386 \
    dcpl2600dpdrv:i386 brotherlegacyusb 2>&1 || true
else
  printf 'dpkg-query unavailable\n'
fi

section 'services and listeners'
run_optional 'CUPS active' systemctl is-active cups
run_optional 'CUPS enabled' systemctl is-enabled cups
if command -v ss >/dev/null 2>&1; then
  ss -lnt 2>&1 | awk 'NR == 1 || $4 ~ /:631$/'
else
  printf 'ss unavailable\n'
fi

section 'target USB (serial deliberately omitted)'
if command -v lsusb >/dev/null 2>&1; then
  if lsusb -d "$usb_id" >/dev/null 2>&1; then
    printf 'USB %s: attached\n' "${usb_id,,}"
  else
    printf 'USB %s: missing\n' "${usb_id,,}"
  fi
else
  printf 'lsusb unavailable\n'
fi

section 'CUPS queue and jobs'
if command -v lpstat >/dev/null 2>&1; then
  lpstat -p "$queue" -l 2>&1 || true
  lpstat -v "$queue" 2>&1 | redact_serial || true
  lpstat -W all -o "$queue" 2>&1 || true
else
  printf 'lpstat unavailable\n'
fi

section 'CUPS server settings'
cupsctl_path=$(command -v cupsctl 2>/dev/null || true)
if [[ -z $cupsctl_path && -x /usr/sbin/cupsctl ]]; then
  cupsctl_path=/usr/sbin/cupsctl
fi
if [[ -n $cupsctl_path ]]; then
  run_optional 'cupsctl' "$cupsctl_path"
else
  printf 'cupsctl: [command unavailable]\n'
fi

section 'IPP attributes'
if command -v ipptool >/dev/null 2>&1 && [[ -r /usr/share/cups/ipptool/get-printer-attributes.test ]]; then
  ipptool -tv "ipp://localhost:631/printers/$queue" \
    /usr/share/cups/ipptool/get-printer-attributes.test 2>&1 |
    grep -E '^(\s*(printer-state|printer-state-reasons|printer-uri-supported|document-format-supported|sides-supported|color-supported)|PASS|FAIL)' |
    redact_serial || true
else
  printf 'ipptool or get-printer-attributes.test unavailable\n'
fi

section 'reminder'
printf 'Diagnostics complete. Owner confirmation is required for every physical sheet.\n'
