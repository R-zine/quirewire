#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage:
  bash submit-m0-linux-baseline.sh --queue QUEUE [--file FILE] [--output-dir DIR]
  bash submit-m0-linux-baseline.sh --queue QUEUE [--file FILE] [--output-dir DIR] --submit

Without --submit this is a read-only plan. With --submit it sends exactly one file
to one existing CUPS queue. It never creates, removes, pauses, or changes a queue.
A successful CUPS submission is not a physical PASS; inspect the printed sheet.
USAGE
}

queue=''
print_file=''
output_dir=''
submit=0

while (($# > 0)); do
  case "$1" in
    --queue)
      (($# >= 2)) || { echo 'ERROR: --queue needs a value.' >&2; exit 64; }
      queue=$2
      shift 2
      ;;
    --file)
      (($# >= 2)) || { echo 'ERROR: --file needs a value.' >&2; exit 64; }
      print_file=$2
      shift 2
      ;;
    --output-dir)
      (($# >= 2)) || { echo 'ERROR: --output-dir needs a value.' >&2; exit 64; }
      output_dir=$2
      shift 2
      ;;
    --submit)
      submit=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      exit 64
      ;;
  esac
done

if [[ -z $queue || ! $queue =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo 'ERROR: --queue is required and may contain only letters, digits, dot, underscore, and hyphen.' >&2
  exit 64
fi
for required in lp lpstat; do
  command -v "$required" >/dev/null 2>&1 || { echo "ERROR: required command not found: $required" >&2; exit 69; }
done
lpstat -p "$queue" >/dev/null 2>&1 || { echo "ERROR: queue '$queue' does not exist." >&2; exit 66; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if [[ -z $print_file ]]; then
  if [[ -f /usr/share/cups/data/testprint ]]; then
    print_file=/usr/share/cups/data/testprint
  else
    print_file="$script_dir/../test-data/m0-text-test.txt"
  fi
fi
[[ -f $print_file ]] || { echo "ERROR: print file is not a regular file: $print_file" >&2; exit 66; }
print_file=$(cd -- "$(dirname -- "$print_file")" && printf '%s/%s\n' "$PWD" "$(basename -- "$print_file")")

if [[ -z $output_dir ]]; then output_dir="$script_dir/../../../artifacts/m0/linux"; fi
mkdir -p -- "$output_dir"
output_dir=$(cd -- "$output_dir" && pwd -P)
umask 077

echo "Queue: $queue"
echo "File:  $print_file"
lpstat -p "$queue" -l || true
if command -v file >/dev/null 2>&1; then file -- "$print_file"; fi

if ((submit == 0)); then
  echo "Dry run only. Re-run with --submit to execute: lp -d '$queue' '$print_file'"
  exit 0
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
record="$output_dir/${stamp}-linux-baseline-submission.txt"
{
  echo 'Schema: printbridge.m0.linux-baseline-submission.v1'
  echo "Submitted UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "Queue: $queue"
  echo "File: $print_file"
  echo 'lp output follows:'
  lp -d "$queue" "$print_file"
  lp_status=$?
  echo "lp exit: $lp_status"
  echo 'Queue/job state immediately after submission:'
  lpstat -p "$queue" -l || true
  lpstat -W all -o "$queue" || true
  exit "$lp_status"
} 2>&1 | tee -- "$record"
pipeline_status=${PIPESTATUS[0]}

echo "Submission evidence: $record"
echo 'Inspect the physical sheet. A zero exit code means accepted by CUPS, not physically printed.'
exit "$pipeline_status"

