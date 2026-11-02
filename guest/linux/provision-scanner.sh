#!/bin/bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: scanner provisioning requires root" >&2
  exit 1
fi
[[ -f /etc/printbridge/guest.env ]] || {
  echo "ERROR: not a PrintBridge-owned guest" >&2
  exit 1
}

manifest=
brscan_deb=
airsane_archive=
airsane_patch=
offline=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) manifest=${2:-}; shift 2 ;;
    --brscan-deb) brscan_deb=${2:-}; shift 2 ;;
    --airsane-source) airsane_archive=${2:-}; shift 2 ;;
    --airsane-patch) airsane_patch=${2:-}; shift 2 ;;
    --offline) offline=yes; shift ;;
    *) echo "ERROR: unknown scanner provisioning argument: $1" >&2; exit 2 ;;
  esac
done
for required in "$manifest" "$brscan_deb" "$airsane_archive" "$airsane_patch"; do
  [[ -r "$required" && -f "$required" ]] || {
    echo "ERROR: required scanner input is missing" >&2
    exit 1
  }
done

manifest_value() {
  local key=$1 value count
  value=$(sed -n "s/^${key}=//p" "$manifest")
  count=$(grep -Ec "^${key}=" "$manifest" || true)
  [[ "$count" -eq 1 && -n "$value" ]] || {
    echo "ERROR: manifest key $key is missing or duplicated" >&2
    exit 1
  }
  printf '%s' "$value"
}
validate_token() {
  [[ "$2" =~ ^[A-Za-z0-9._:+/@=-]+$ ]] || {
    echo "ERROR: unsafe manifest value for $1" >&2
    exit 1
  }
}

schema=$(manifest_value PRINTBRIDGE_SCANNER_SCHEMA)
vendor_id=$(manifest_value USB_VENDOR_ID)
product_id=$(manifest_value USB_PRODUCT_ID)
brscan_filename=$(manifest_value BRSCAN_FILENAME)
brscan_package=$(manifest_value BRSCAN_PACKAGE)
brscan_version=$(manifest_value BRSCAN_VERSION)
brscan_arch=$(manifest_value BRSCAN_ARCHITECTURE)
brscan_sha=$(manifest_value BRSCAN_SHA256)
brscan_redistribution=$(manifest_value BRSCAN_REDISTRIBUTION)
airsane_filename=$(manifest_value AIRSANE_FILENAME)
airsane_commit=$(manifest_value AIRSANE_COMMIT)
airsane_sha=$(manifest_value AIRSANE_SHA256)
airsane_license=$(manifest_value AIRSANE_LICENSE)
airsane_patch_filename=$(manifest_value AIRSANE_PATCH_FILENAME)
airsane_patch_sha=$(manifest_value AIRSANE_PATCH_SHA256)
airsane_patch_issue=$(manifest_value AIRSANE_PATCH_UPSTREAM_ISSUE)
guest_port=$(manifest_value AIRSANE_GUEST_PORT)
for pair in \
  "schema:$schema" "vendor_id:$vendor_id" "product_id:$product_id" \
  "brscan_filename:$brscan_filename" "brscan_package:$brscan_package" \
  "brscan_version:$brscan_version" "brscan_arch:$brscan_arch" \
  "brscan_sha:$brscan_sha" "brscan_redistribution:$brscan_redistribution" \
  "airsane_filename:$airsane_filename" "airsane_commit:$airsane_commit" \
  "airsane_sha:$airsane_sha" "airsane_license:$airsane_license" \
  "airsane_patch_filename:$airsane_patch_filename" \
  "airsane_patch_sha:$airsane_patch_sha" \
  "airsane_patch_issue:$airsane_patch_issue" \
  "guest_port:$guest_port"; do
  validate_token "${pair%%:*}" "${pair#*:}"
done
[[ "$schema" == printbridge.m11.scanner.v1 ]]
[[ "$vendor_id" == 04f9 && "$product_id" == 0567 ]]
[[ "$brscan_redistribution" == owner-local-only ]]
[[ "$airsane_license" == GPL-3.0-only ]]
[[ "$guest_port" == 8090 ]]
[[ "$(basename "$brscan_deb")" == "$brscan_filename" ]]
[[ "$(basename "$airsane_archive")" == "$airsane_filename" ]]
[[ "$(basename "$airsane_patch")" == "$airsane_patch_filename" ]]
printf '%s  %s\n' "$brscan_sha" "$brscan_deb" | sha256sum --check --strict -
printf '%s  %s\n' "$airsane_sha" "$airsane_archive" | sha256sum --check --strict -
printf '%s  %s\n' "$airsane_patch_sha" "$airsane_patch" | sha256sum --check --strict -
[[ "$(dpkg-deb -f "$brscan_deb" Package)" == "$brscan_package" ]]
[[ "$(dpkg-deb -f "$brscan_deb" Version)" == "$brscan_version" ]]
[[ "$(dpkg-deb -f "$brscan_deb" Architecture)" == "$brscan_arch" ]]

# shellcheck disable=SC1091
. /usr/local/lib/printbridge/debian.env
apt-get -o Acquire::Check-Valid-Until=false update
apt-get install -y --no-install-recommends \
  "sane-utils=$(manifest_value SANE_UTILS_VERSION)" \
  "libsane-dev=$(manifest_value LIBSANE_DEV_VERSION)" \
  "libjpeg62-turbo-dev=$(manifest_value LIBJPEG_DEV_VERSION)" \
  "libpng-dev=$(manifest_value LIBPNG_DEV_VERSION)" \
  "libavahi-client-dev=$(manifest_value LIBAVAHI_DEV_VERSION)" \
  "libusb-1.0-0-dev=$(manifest_value LIBUSB_DEV_VERSION)" \
  "cmake=$(manifest_value CMAKE_VERSION)" \
  "g++=$(manifest_value GXX_VERSION)" \
  "make=$(manifest_value MAKE_VERSION)" \
  "patch=$(manifest_value PATCH_VERSION)"

if ! dpkg-query -W -f='${db:Status-Status} ${Version}' "$brscan_package" 2>/dev/null |
  grep -Fxq "installed $brscan_version"; then
  dpkg -i "$brscan_deb"
fi
[[ "$(dpkg-query -W -f='${db:Status-Status}' "$brscan_package")" == installed ]]
[[ "$(dpkg-query -W -f='${Version}' "$brscan_package")" == "$brscan_version" ]]

getent group scanner >/dev/null || groupadd --system scanner
usermod -a -G scanner saned
cat > /etc/udev/rules.d/99-printbridge-scanner.rules <<EOF
# Exact selected PrintBridge scanner; do not grant access to unrelated Brother USB devices.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="$vendor_id", ATTR{idProduct}=="$product_id", GROUP:="scanner", MODE:="0660", ENV{libsane_matched}:="yes"
EOF
chmod 0644 /etc/udev/rules.d/99-printbridge-scanner.rules
if [[ "$offline" == no ]]; then
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=usb --attr-match=idVendor="$vendor_id" --attr-match=idProduct="$product_id" || true
fi

selection=/var/lib/printbridge/scanner-selection.env
needs_build=yes
if [[ -x /usr/local/bin/airsaned && -f "$selection" ]] &&
  grep -Fxq "airsane_commit=$airsane_commit" "$selection" &&
  grep -Fxq "airsane_sha256=$airsane_sha" "$selection" &&
  grep -Fxq "airsane_patch_sha256=$airsane_patch_sha" "$selection"; then
  needs_build=no
fi
if [[ "$needs_build" == yes ]]; then
  build_root=$(mktemp -d /var/tmp/printbridge-airsane.XXXXXX)
  cleanup() { rm -rf --one-file-system "$build_root"; }
  trap cleanup EXIT
  tar -xzf "$airsane_archive" -C "$build_root"
  source_root="$build_root/AirSane-$airsane_commit"
  [[ -f "$source_root/LICENSE" && -f "$source_root/CMakeLists.txt" ]]
  patch --directory="$source_root" --strip=1 --fuzz=0 \
    --no-backup-if-mismatch < "$airsane_patch"
  grep -Fq 'release it before accepting scan jobs' "$source_root/server/server.cpp"
  cmake -S "$source_root" -B "$build_root/build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr/local
  cmake --build "$build_root/build" --parallel 1
  cmake --install "$build_root/build"
  trap - EXIT
  cleanup
fi

cat > /etc/default/airsane <<'EOF'
INTERFACE=*
LISTEN_PORT=8090
ACCESS_LOG=
HOTPLUG=true
RELOAD_DELAY=1
MDNS_ANNOUNCE=false
ANNOUNCE_SECURE=false
ANNOUNCE_BASE_URL=
UNIX_SOCKET=
WEB_INTERFACE=true
RESET_OPTION=false
DISCLOSE_VERSION=false
LOCAL_SCANNERS_ONLY=true
RANDOM_PATHS=false
COMPATIBLE_PATH=true
OPTIONS_FILE=/etc/airsane/options.conf
ACCESS_FILE=/etc/airsane/access.conf
IGNORE_LIST=/etc/airsane/ignore.conf
EOF
cat > /etc/airsane/access.conf <<'EOF'
# VirtualBox preserves the original IPv4 peer on forwarded connections.
# Keep a private-address guest boundary; Windows Firewall remains authoritative
# for the exact approved interface, remote CIDR, executable, and host port.
allow 10.0.0.0/8
allow 172.16.0.0/12
allow 192.168.0.0/16
EOF
cat > /etc/airsane/options.conf <<'EOF'
location Shared by PrintBridge while the app is running
EOF
chmod 0644 /etc/default/airsane /etc/airsane/access.conf /etc/airsane/options.conf
systemctl enable airsaned.service
if [[ "$offline" == no ]]; then
  systemctl daemon-reload
  systemctl restart airsaned.service
  systemctl is-active --quiet airsaned.service
fi

install -d -m 0755 /var/lib/printbridge
{
  echo 'schema=printbridge.m11.scanner-selection.v1'
  echo "brscan_package=$brscan_package"
  echo "brscan_version=$brscan_version"
  echo "brscan_sha256=$brscan_sha"
  echo "airsane_commit=$airsane_commit"
  echo "airsane_sha256=$airsane_sha"
  echo "airsane_patch_sha256=$airsane_patch_sha"
  echo "airsane_patch_upstream_issue=$airsane_patch_issue"
  echo "guest_port=$guest_port"
  echo "last_completed=$(date --iso-8601=seconds)"
} > "$selection"
chmod 0644 "$selection"

if [[ "$offline" == yes ]]; then
  echo 'Scanner packages installed into the owned offline guest clone; live enumeration is deferred to first boot.'
elif lsusb -d "$vendor_id:$product_id" >/dev/null 2>&1; then
  timeout 20s runuser -u saned -- scanimage -L | grep -qi 'brother'
else
  echo 'Scanner packages installed; physical USB enumeration remains blocked until the selected device is connected.'
fi
echo 'PrintBridge scanner provisioning completed without retaining scan content.'
