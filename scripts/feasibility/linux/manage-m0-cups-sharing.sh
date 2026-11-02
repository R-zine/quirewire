#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage:
  bash manage-m0-cups-sharing.sh --queue QUEUE --action status|plan
  sudo bash manage-m0-cups-sharing.sh --queue QUEUE --action apply [--state-file FILE]
  sudo bash manage-m0-cups-sharing.sh --queue QUEUE --action restore [--state-file FILE]

The apply action enables CUPS sharing for one existing queue on the local subnet.
It never creates/deletes a queue, never uses --remote-any, and records the exact
prior global/queue sharing values before changing them. Restore only replays those
two saved values; it does not replace whole CUPS configuration files.
USAGE
}

queue=''
action=''
state_file=''

while (($# > 0)); do
  case "$1" in
    --queue)
      (($# >= 2)) || { echo 'ERROR: --queue needs a value.' >&2; exit 64; }
      queue=$2
      shift 2
      ;;
    --action)
      (($# >= 2)) || { echo 'ERROR: --action needs a value.' >&2; exit 64; }
      action=$2
      shift 2
      ;;
    --state-file)
      (($# >= 2)) || { echo 'ERROR: --state-file needs a value.' >&2; exit 64; }
      state_file=$2
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

if [[ -z $queue || ! $queue =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo 'ERROR: --queue is required and may contain only letters, digits, dot, underscore, and hyphen.' >&2
  exit 64
fi
if [[ $action != status && $action != plan && $action != apply && $action != restore ]]; then
  echo 'ERROR: --action must be status, plan, apply, or restore.' >&2
  exit 64
fi

for required in cupsctl lpadmin lpstat awk; do
  if ! command -v "$required" >/dev/null 2>&1; then
    echo "ERROR: required CUPS command not found: $required" >&2
    exit 69
  fi
done
if ! lpstat -p "$queue" >/dev/null 2>&1; then
  echo "ERROR: CUPS queue '$queue' does not exist. This script will not create it." >&2
  exit 66
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ -z $state_file ]]; then
  state_dir="$script_dir/../../../artifacts/m0/linux/ownership"
  state_file="$state_dir/cups-sharing-$queue.state"
fi
state_parent=$(dirname -- "$state_file")
umask 077

normalize_boolean() {
  case "${1,,}" in
    1|yes|true|on) printf '1\n' ;;
    0|no|false|off) printf '0\n' ;;
    *) return 1 ;;
  esac
}

get_cupsctl_value() {
  key=$1
  raw=$(cupsctl 2>/dev/null | awk -F= -v wanted="$key" '$1 == wanted {print $2; found=1; exit} END {if (!found) exit 1}') || return 1
  normalize_boolean "$raw"
}

get_queue_share() {
  config=/etc/cups/printers.conf
  [[ -r $config ]] || return 1
  raw=$(awk -v q="$queue" '
    $0 == "<Printer " q ">" || $0 == "<DefaultPrinter " q ">" {inside=1; next}
    inside && $1 == "Shared" {print $2; found=1; exit}
    inside && ($0 == "</Printer>" || $0 == "</DefaultPrinter>") {exit}
    END {if (!found) exit 1}
  ' "$config") || return 1
  normalize_boolean "$raw"
}

list_shared_queues() {
  config=/etc/cups/printers.conf
  [[ -r $config ]] || return 1
  awk '
    /^<(Default)?Printer [^>]+>$/ {
      name=$0
      sub(/^<(Default)?Printer /, "", name)
      sub(/>$/, "", name)
      inside=1
      next
    }
    inside && $1 == "Shared" && tolower($2) == "yes" {print name}
    inside && ($0 == "</Printer>" || $0 == "</DefaultPrinter>") {inside=0; name=""}
  ' "$config"
}

show_status() {
  global_share=$(get_cupsctl_value '_share_printers' || printf 'UNKNOWN')
  remote_any=$(get_cupsctl_value '_remote_any' || printf 'UNKNOWN')
  queue_share=$(get_queue_share || printf 'UNKNOWN')
  printf 'Queue: %s\n' "$queue"
  printf 'Global CUPS sharing (_share_printers): %s\n' "$global_share"
  printf 'Remote-any exposure (_remote_any): %s\n' "$remote_any"
  printf 'Selected queue sharing: %s\n' "$queue_share"
  printf 'State file: %s\n' "$state_file"
}

restore_values() {
  previous_global=$1
  previous_queue=$2
  if [[ $previous_queue == 1 ]]; then
    lpadmin -p "$queue" -o printer-is-shared=true
  else
    lpadmin -p "$queue" -o printer-is-shared=false
  fi
  if [[ $previous_global == 1 ]]; then
    cupsctl --share-printers
  else
    cupsctl --no-share-printers
  fi
}

wait_for_scheduler() {
  attempts=0
  while ((attempts < 15)); do
    if lpstat -r >/dev/null 2>&1; then
      return 0
    fi
    attempts=$((attempts + 1))
    sleep 1
  done
  return 1
}

read_state_value() {
  wanted=$1
  awk -F= -v wanted="$wanted" '$1 == wanted {sub(/^[^=]*=/, ""); print; found=1; exit} END {if (!found) exit 1}' "$state_file"
}

case "$action" in
  status)
    show_status
    ;;

  plan)
    show_status
    cat <<EOF

Apply would run only:
  cupsctl --share-printers
  lpadmin -p '$queue' -o printer-is-shared=true

It will refuse to proceed if CUPS is already configured with --remote-any or if
the original settings cannot be read for a safe restore. No firewall is changed.
EOF
    ;;

  apply)
    if ((EUID != 0)); then
      echo 'ERROR: apply must run with sudo so original CUPS state can be recorded and restored.' >&2
      exit 77
    fi
    if ! mkdir -p -- "$state_parent"; then
      echo "ERROR: cannot create ownership-state directory: $state_parent" >&2
      exit 73
    fi
    if [[ -e $state_file || -L $state_file ]]; then
      echo "ERROR: state file already exists: $state_file" >&2
      echo 'Use status, or restore the earlier M0-owned change before a new apply.' >&2
      exit 73
    fi

    previous_global=$(get_cupsctl_value '_share_printers') || {
      echo 'ERROR: cannot determine current global sharing state; refusing to change CUPS.' >&2
      exit 65
    }
    previous_remote_any=$(get_cupsctl_value '_remote_any') || {
      echo 'ERROR: cannot determine current remote-any state; refusing to change CUPS.' >&2
      exit 65
    }
    previous_queue=$(get_queue_share) || {
      echo 'ERROR: cannot determine current queue sharing state; refusing to change CUPS.' >&2
      exit 65
    }
    if [[ $previous_remote_any != 0 ]]; then
      echo 'ERROR: CUPS currently allows remote-any access. This script will not preserve or widen that exposure.' >&2
      echo 'Restrict CUPS to the trusted local subnet, verify it, and then retry.' >&2
      exit 78
    fi
    if [[ $previous_global == 0 ]]; then
      other_shared=$(list_shared_queues | awk -v selected="$queue" '$0 != selected {print}' || true)
      if [[ -n $other_shared ]]; then
        echo 'ERROR: global sharing is off, but another queue is marked Shared Yes.' >&2
        echo 'Enabling global sharing could expose that unrelated queue, so this script refuses.' >&2
        printf '%s\n' "$other_shared" >&2
        exit 78
      fi
    fi

    state_contents=$(cat <<EOF
schema=quirewire.m0.cups-sharing-state.v1
queue=$queue
global_share=$previous_global
queue_share=$previous_queue
remote_any_observed=$previous_remote_any
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
)
    if ! (set -o noclobber; printf '%s\n' "$state_contents" > "$state_file") 2>/dev/null; then
      echo "ERROR: could not create ownership state without overwriting: $state_file" >&2
      exit 73
    fi

    if ! lpadmin -p "$queue" -o printer-is-shared=true; then
      echo 'ERROR: queue sharing failed; the global setting was not changed.' >&2
      exit 1
    fi
    if ! cupsctl --share-printers; then
      echo 'ERROR: cupsctl failed; restoring the original queue setting.' >&2
      if [[ $previous_queue == 1 ]]; then
        lpadmin -p "$queue" -o printer-is-shared=true || true
      else
        lpadmin -p "$queue" -o printer-is-shared=false || true
      fi
      exit 1
    fi
    if ! wait_for_scheduler; then
      echo 'ERROR: CUPS did not become ready after enabling sharing; attempting to restore the original settings.' >&2
      restore_values "$previous_global" "$previous_queue" || true
      exit 1
    fi

    current_global=$(get_cupsctl_value '_share_printers' || printf 'UNKNOWN')
    current_remote_any=$(get_cupsctl_value '_remote_any' || printf 'UNKNOWN')
    current_queue=$(get_queue_share || printf 'UNKNOWN')
    if [[ $current_global != 1 || $current_remote_any != 0 || $current_queue != 1 ]]; then
      echo 'ERROR: post-change verification failed; restoring the two original sharing values.' >&2
      restore_values "$previous_global" "$previous_queue" || true
      exit 1
    fi

    echo "Enabled local-subnet CUPS sharing only for existing queue '$queue'."
    echo "Ownership/restore state: $state_file"
    echo 'No queue, driver, firewall, or remote-admin setting was created or removed.'
    ;;

  restore)
    if ((EUID != 0)); then
      echo 'ERROR: restore must run with sudo.' >&2
      exit 77
    fi
    if [[ ! -f $state_file || -L $state_file ]]; then
      echo "ERROR: regular non-symlink ownership state file not found: $state_file" >&2
      exit 66
    fi

    schema=$(read_state_value schema || true)
    saved_queue=$(read_state_value queue || true)
    previous_global=$(read_state_value global_share || true)
    previous_queue=$(read_state_value queue_share || true)
    observed_remote_any=$(read_state_value remote_any_observed || true)
    if [[ $schema != quirewire.m0.cups-sharing-state.v1 || $saved_queue != "$queue" ||
          ! $previous_global =~ ^[01]$ || ! $previous_queue =~ ^[01]$ || $observed_remote_any != 0 ]]; then
      echo 'ERROR: ownership state is invalid or does not match the requested queue. Refusing restore.' >&2
      exit 65
    fi

    current_remote_any=$(get_cupsctl_value '_remote_any' || printf 'UNKNOWN')
    current_global_before=$(get_cupsctl_value '_share_printers' || printf 'UNKNOWN')
    current_queue_before=$(get_queue_share || printf 'UNKNOWN')
    if [[ $current_remote_any != 0 || $current_global_before != 1 || $current_queue_before != 1 ]]; then
      echo 'ERROR: live CUPS sharing no longer matches the state created by M0 apply; refusing automatic restore.' >&2
      exit 65
    fi
    if [[ $previous_global == 0 ]]; then
      other_shared=$(list_shared_queues | awk -v selected="$queue" '$0 != selected {print}' || true)
      if [[ -n $other_shared ]]; then
        echo 'ERROR: another queue is now shared. Disabling global sharing could affect it; refusing restore.' >&2
        printf '%s\n' "$other_shared" >&2
        exit 78
      fi
    fi

    restore_values "$previous_global" "$previous_queue"
    current_global=$(get_cupsctl_value '_share_printers' || printf 'UNKNOWN')
    current_queue=$(get_queue_share || printf 'UNKNOWN')
    if [[ $current_global != "$previous_global" || $current_queue != "$previous_queue" ]]; then
      echo 'ERROR: CUPS accepted the restore commands but verification did not match the saved state.' >&2
      exit 1
    fi
    echo "Restored original sharing values for queue '$queue'."
    echo 'The state file was retained as an audit record; no queue or driver was removed.'
    ;;
esac

