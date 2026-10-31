#!/bin/bash
set -euo pipefail

mode=${1:---repair}
case "$mode" in
  --installer|--repair) ;;
  *) echo "ERROR: expected --installer or --repair" >&2; exit 2 ;;
esac
if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: base provisioning requires root" >&2
  exit 1
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if [[ -r "$script_dir/debian.env" ]]; then
  manifest="$script_dir/debian.env"
  config_dir="$script_dir"
  authorized_keys="$script_dir/authorized_keys"
else
  manifest="$script_dir/../manifests/debian-13.7-amd64.env"
  config_dir="$script_dir/../config"
  authorized_keys="$script_dir/authorized_keys"
fi
[[ -r "$manifest" ]] || { echo "ERROR: missing pinned Debian manifest" >&2; exit 1; }
[[ -r "$config_dir/90-printbridge-sshd.conf" ]] || { echo "ERROR: missing SSH policy" >&2; exit 1; }
[[ -r "$config_dir/printbridge-logrotate" ]] || { echo "ERROR: missing log rotation policy" >&2; exit 1; }
[[ -r "$authorized_keys" ]] || { echo "ERROR: missing owner SSH public key" >&2; exit 1; }
# The manifest is repository-owned, contains only fixed key/value literals, and
# is copied from read-only build media.
# shellcheck disable=SC1090
. "$manifest"
[[ "$PRINTBRIDGE_MANIFEST_SCHEMA" == printbridge.m4.debian.v1 ]]
[[ "$(dpkg --print-architecture)" == "$DEBIAN_ARCH" ]]

install -d -m 0755 /etc/printbridge /var/lib/printbridge /var/log/printbridge
exec > >(tee -a /var/log/printbridge/base-provision.log) 2>&1
echo "PrintBridge M4 base $mode started: $(date --iso-8601=seconds)"

cat > /etc/apt/sources.list.d/printbridge-snapshot.sources <<EOF
Types: deb
URIs: http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT_TIMESTAMP}/
Suites: ${DEBIAN_CODENAME} ${DEBIAN_CODENAME}-updates
Components: main
Check-Valid-Until: no
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT_TIMESTAMP}/
Suites: ${DEBIAN_CODENAME}-security
Components: main
Check-Valid-Until: no
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
rm -f /etc/apt/sources.list
find /etc/apt/sources.list.d -maxdepth 1 -type f ! -name printbridge-snapshot.sources -delete

dpkg --add-architecture i386
export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::Check-Valid-Until=false update
apt-get install -y --no-install-recommends --allow-downgrades \
  "ca-certificates=${CA_CERTIFICATES_VERSION}" \
  "cups=${CUPS_VERSION}" \
  "cups-client=${CUPS_VERSION}" \
  "cups-ipp-utils=${CUPS_VERSION}" \
  "dbus=${DBUS_VERSION}" \
  "file=${FILE_VERSION}" \
  "libc6:i386=${LIBC6_I386_VERSION}" \
  "logrotate=${LOGROTATE_VERSION}" \
  "openssh-server=${OPENSSH_SERVER_VERSION}" \
  "usbutils=${USBUTILS_VERSION}"

printf '%s\n' printbridge-m4 > /etc/hostname
if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
  sed -i 's/^127\.0\.1\.1[[:space:]].*/127.0.1.1 printbridge-m4/' /etc/hosts
else
  printf '%s\n' '127.0.1.1 printbridge-m4' >> /etc/hosts
fi
systemctl set-default multi-user.target

install_if_different() {
  local source=$1 target=$2 mode_bits=$3
  if [[ "$(readlink -f "$source")" != "$(readlink -m "$target")" ]]; then
    install -m "$mode_bits" "$source" "$target"
  else
    chmod "$mode_bits" "$target"
  fi
}

install -d -m 0755 /usr/local/lib/printbridge
install_if_different "$script_dir/provision-base.sh" /usr/local/lib/printbridge/provision-base.sh 0755
install_if_different "$script_dir/firstboot.sh" /usr/local/lib/printbridge/firstboot.sh 0755
install_if_different "$script_dir/apply-driver-media.sh" /usr/local/lib/printbridge/apply-driver-media.sh 0755
install_if_different "$script_dir/health.sh" /usr/local/lib/printbridge/health.sh 0755
install_if_different "$script_dir/configure-lan-cups.sh" /usr/local/lib/printbridge/configure-lan-cups.sh 0755
install_if_different "$script_dir/apply-driver-media.sh" /usr/local/sbin/printbridge-apply-driver-media 0755
install_if_different "$script_dir/health.sh" /usr/local/sbin/printbridge-health 0755
install_if_different "$manifest" /usr/local/lib/printbridge/debian.env 0644
install_if_different "$config_dir/90-printbridge-sshd.conf" /usr/local/lib/printbridge/90-printbridge-sshd.conf 0644
install_if_different "$config_dir/printbridge-logrotate" /usr/local/lib/printbridge/printbridge-logrotate 0644
install_if_different "$authorized_keys" /usr/local/lib/printbridge/authorized_keys 0600
install_if_different "$config_dir/90-printbridge-sshd.conf" /etc/ssh/sshd_config.d/90-printbridge.conf 0644
install_if_different "$config_dir/printbridge-logrotate" /etc/logrotate.d/printbridge 0644

install -d -m 0700 -o printbridge -g printbridge /home/printbridge/.ssh
install -m 0600 -o printbridge -g printbridge "$authorized_keys" /home/printbridge/.ssh/authorized_keys
passwd -l root || true
passwd -l printbridge || true
install -d -m 0755 /run/sshd
/usr/sbin/sshd -t

cat > /etc/printbridge/guest.env <<EOF
PRINTBRIDGE_GUEST_SCHEMA=printbridge.m4.guest.v1
DEBIAN_VERSION=${DEBIAN_VERSION}
DEBIAN_SNAPSHOT_TIMESTAMP=${DEBIAN_SNAPSHOT_TIMESTAMP}
QUEUE_NAME=PrintBridge_DCP_L2600D
EOF

cat > /etc/systemd/system/printbridge-firstboot.service <<'EOF'
[Unit]
Description=Finalize PrintBridge base image once
After=network-online.target cups.service ssh.service
Wants=network-online.target cups.service ssh.service
ConditionPathExists=!/var/lib/printbridge/base-complete

[Service]
Type=oneshot
ExecStart=/usr/local/lib/printbridge/firstboot.sh

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/printbridge-driver-media.service <<'EOF'
[Unit]
Description=Apply owner-selected PrintBridge driver media
After=network-online.target cups.service
Wants=network-online.target cups.service

[Service]
Type=oneshot
Environment=PRINTBRIDGE_POWER_OFF_AFTER_MEDIA=1
ExecStart=/usr/local/sbin/printbridge-apply-driver-media

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/printbridge-health.service <<'EOF'
[Unit]
Description=Refresh PrintBridge guest health report
After=cups.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c '/usr/local/sbin/printbridge-health > /run/printbridge-health.txt.tmp && mv /run/printbridge-health.txt.tmp /run/printbridge-health.txt'
EOF

cat > /etc/systemd/system/printbridge-health.timer <<'EOF'
[Unit]
Description=Periodically refresh PrintBridge guest health

[Timer]
OnBootSec=30s
OnUnitActiveSec=5min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable cups.service ssh.service printbridge-driver-media.service printbridge-health.timer
if [[ "$mode" == --installer ]]; then
  systemctl enable printbridge-firstboot.service
fi

if [[ "$mode" == --repair ]] && systemctl is-active --quiet cups.service; then
  /usr/sbin/cupsctl --share-printers --no-remote-admin --no-remote-any
  /usr/local/lib/printbridge/configure-lan-cups.sh
  /usr/sbin/cupsd -t
  systemctl restart cups.service
fi

{
  echo "schema=printbridge.m4.base-state.v1"
  echo "manifest_schema=${PRINTBRIDGE_MANIFEST_SCHEMA}"
  echo "debian_version=${DEBIAN_VERSION}"
  echo "snapshot=${DEBIAN_SNAPSHOT_TIMESTAMP}"
  echo "last_mode=${mode#--}"
  echo "last_completed=$(date --iso-8601=seconds)"
} > /var/lib/printbridge/base-state.env
chmod 0644 /var/lib/printbridge/base-state.env
echo "PrintBridge M4 base $mode completed: $(date --iso-8601=seconds)"
