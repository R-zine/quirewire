#!/bin/bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: driver media application requires root" >&2
  exit 1
fi
[[ -f /etc/printbridge/guest.env ]] || { echo "ERROR: not a PrintBridge-owned guest" >&2; exit 1; }

mount_dir=/run/printbridge-driver-media
mounted_here=no
install -d -m 0755 "$mount_dir" /var/lib/printbridge /var/log/printbridge
exec > >(tee -a /var/log/printbridge/driver-media.log) 2>&1

cleanup() {
  if [[ "$mounted_here" == yes ]]; then
    umount "$mount_dir" || true
  fi
}
trap cleanup EXIT

if ! mountpoint -q "$mount_dir"; then
  if [[ ! -b /dev/sr0 ]]; then
    echo "No driver media present; leaving guest unchanged."
    exit 0
  fi
  mount -o ro /dev/sr0 "$mount_dir" 2>/dev/null || {
    echo "No readable driver media present; leaving guest unchanged."
    exit 0
  }
  mounted_here=yes
fi

manifest="$mount_dir/printbridge-driver/manifest.env"
if [[ ! -r "$manifest" ]]; then
  echo "Mounted media is not PrintBridge driver media; leaving guest unchanged."
  exit 0
fi

manifest_value() {
  local key=$1 value
  value=$(sed -n "s/^${key}=//p" "$manifest")
  [[ $(printf '%s\n' "$value" | wc -l) -eq 1 && -n "$value" ]] || {
    echo "ERROR: manifest key $key is missing or duplicated" >&2
    exit 1
  }
  printf '%s' "$value"
}
validate_token() {
  [[ "$2" =~ ^[A-Za-z0-9._:+/@=-]+$ ]] || {
    echo "ERROR: unsafe value for $1" >&2
    exit 1
  }
}

schema=$(manifest_value PRINTBRIDGE_DRIVER_SCHEMA)
driver_mode=$(manifest_value DRIVER_MODE)
queue_name=$(manifest_value QUEUE_NAME)
vendor_id=$(manifest_value USB_VENDOR_ID)
product_id=$(manifest_value USB_PRODUCT_ID)
for pair in "schema:$schema" "driver_mode:$driver_mode" "queue_name:$queue_name" \
  "vendor_id:$vendor_id" "product_id:$product_id"; do
  validate_token "${pair%%:*}" "${pair#*:}"
done
[[ "$schema" == printbridge.m4.driver-media.v1 ]]
[[ "$queue_name" == PrintBridge_DCP_L2600D ]]
[[ "$vendor_id" =~ ^[0-9a-fA-F]{4}$ && "$product_id" =~ ^[0-9a-fA-F]{4}$ ]]

/usr/local/lib/printbridge/provision-base.sh --repair
systemctl is-active --quiet cups.service

selection=/var/lib/printbridge/driver-selection.env
if [[ -f "$selection" ]]; then
  previous_mode=$(sed -n 's/^driver_mode=//p' "$selection")
  [[ "$previous_mode" == "$driver_mode" ]] || {
    echo "ERROR: refusing to replace known-good driver mode $previous_mode with $driver_mode" >&2
    exit 1
  }
fi

case "$driver_mode" in
  official-brother)
    patch_filename=$(manifest_value PATCH_FILENAME)
    patch_package=$(manifest_value PATCH_PACKAGE)
    patch_version=$(manifest_value PATCH_VERSION)
    patch_arch=$(manifest_value PATCH_ARCHITECTURE)
    patch_sha=$(manifest_value PATCH_SHA256)
    driver_filename=$(manifest_value DRIVER_FILENAME)
    driver_package=$(manifest_value DRIVER_PACKAGE)
    driver_version=$(manifest_value DRIVER_VERSION)
    driver_arch=$(manifest_value DRIVER_ARCHITECTURE)
    driver_sha=$(manifest_value DRIVER_SHA256)
    ppd_path=$(manifest_value PPD_PATH)
    ppd_sha=$(manifest_value PPD_SHA256)
    redistribution=$(manifest_value REDISTRIBUTION)
    for pair in "patch_filename:$patch_filename" "patch_package:$patch_package" \
      "patch_version:$patch_version" "patch_arch:$patch_arch" "patch_sha:$patch_sha" \
      "driver_filename:$driver_filename" "driver_package:$driver_package" \
      "driver_version:$driver_version" "driver_arch:$driver_arch" "driver_sha:$driver_sha" \
      "ppd_path:$ppd_path" "ppd_sha:$ppd_sha" "redistribution:$redistribution"; do
      validate_token "${pair%%:*}" "${pair#*:}"
    done
    [[ "$redistribution" == owner-local-only-pending-license-review ]]
    patch_deb="$mount_dir/printbridge-driver/$patch_filename"
    driver_deb="$mount_dir/printbridge-driver/$driver_filename"
    printf '%s  %s\n' "$patch_sha" "$patch_deb" | sha256sum --check --strict -
    printf '%s  %s\n' "$driver_sha" "$driver_deb" | sha256sum --check --strict -
    [[ "$(dpkg-deb -f "$patch_deb" Package)" == "$patch_package" ]]
    [[ "$(dpkg-deb -f "$patch_deb" Version)" == "$patch_version" ]]
    [[ "$(dpkg-deb -f "$patch_deb" Architecture)" == "$patch_arch" ]]
    [[ "$(dpkg-deb -f "$driver_deb" Package)" == "$driver_package" ]]
    [[ "$(dpkg-deb -f "$driver_deb" Version)" == "$driver_version" ]]
    [[ "$(dpkg-deb -f "$driver_deb" Architecture)" == "$driver_arch" ]]
    if [[ -f "$selection" ]]; then
      [[ "$(sed -n 's/^patch_sha256=//p' "$selection")" == "$patch_sha" ]]
      [[ "$(sed -n 's/^driver_sha256=//p' "$selection")" == "$driver_sha" ]]
    fi
    dpkg -i "$patch_deb"
    dpkg -i "$driver_deb"
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$patch_package")" == installed ]]
    [[ "$(dpkg-query -W -f='${Version}' "$patch_package")" == "$patch_version" ]]
    [[ "$(dpkg-query -W -f='${db:Status-Status}' "$driver_package")" == installed ]]
    [[ "$(dpkg-query -W -f='${Version}' "$driver_package")" == "$driver_version" ]]
    [[ -f "$ppd_path" ]]
    printf '%s  %s\n' "$ppd_sha" "$ppd_path" | sha256sum --check --strict -
    model_argument=(-P "$ppd_path")
    ;;
  open-brlaser)
    # The distro workflow is intentionally attempted before queue mutation. It
    # fails actionably when the pinned driver does not advertise this exact model.
    # shellcheck disable=SC1091
    . /usr/local/lib/printbridge/debian.env
    apt-get -o Acquire::Check-Valid-Until=false update
    apt-get install -y --no-install-recommends "printer-driver-brlaser=${BRLASER_VERSION}"
    model=$(lpinfo -m | awk 'BEGIN{IGNORECASE=1} /DCP-L2600D/{print $1; exit}')
    [[ -n "$model" ]] || {
      echo "ERROR: pinned brlaser does not advertise DCP-L2600D; use owner-selected official media" >&2
      exit 1
    }
    patch_sha=none
    driver_sha=debian-brlaser-${BRLASER_VERSION}
    ppd_sha=distribution-managed
    model_argument=(-m "$model")
    ;;
  *) echo "ERROR: unsupported driver mode $driver_mode" >&2; exit 1 ;;
esac

usb_id="${vendor_id}:${product_id}"
for _ in $(seq 1 180); do
  lsusb -d "$usb_id" >/dev/null 2>&1 && break
  sleep 1
done
lsusb -d "$usb_id" >/dev/null
device_uri=$(lpinfo -v | awk -v id="$usb_id" 'BEGIN{IGNORECASE=1} $0 ~ /^direct usb:/ && $0 ~ /Brother\/DCP-L2600D/ {sub(/^direct /, ""); print; exit}')
[[ "$device_uri" == usb://Brother/DCP-L2600D* ]] || {
  echo "ERROR: exact Brother USB backend URI was not found" >&2
  exit 1
}

if lpstat -p DCPL2600D >/dev/null 2>&1; then
  lpadmin -x DCPL2600D
fi
lpadmin -p "$queue_name" -E -v "$device_uri" "${model_argument[@]}" \
  -D 'Brother DCP-L2600D via PrintBridge' \
  -o printer-is-shared=true -o printer-error-policy=retry-job
cupsaccept "$queue_name"
cupsenable "$queue_name"
/usr/sbin/cupsd -t

{
  echo 'schema=printbridge.m4.driver-selection.v1'
  echo "driver_mode=$driver_mode"
  echo "queue_name=$queue_name"
  echo "usb_id=$usb_id"
  echo "patch_sha256=$patch_sha"
  echo "driver_sha256=$driver_sha"
  echo "ppd_sha256=$ppd_sha"
  echo "last_completed=$(date --iso-8601=seconds)"
} > "$selection"
chmod 0644 "$selection"

/usr/local/sbin/printbridge-health
sync
echo "PrintBridge driver media completed without logging the USB serial."
if [[ "${PRINTBRIDGE_POWER_OFF_AFTER_MEDIA:-0}" == 1 ]]; then
  systemctl poweroff
fi
