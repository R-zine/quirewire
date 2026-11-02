#!/bin/bash
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
  echo "ERROR: CUPS LAN policy configuration requires root" >&2
  exit 1
fi
[[ -f /etc/quirewire/guest.env ]] || {
  echo "ERROR: not a QuireWire-owned guest" >&2
  exit 1
}

conf=/etc/cups/cupsd.conf
begin='# BEGIN QUIREWIRE M10 QUEUE-ONLY LAN ACCESS'
end='# END QUIREWIRE M10 QUEUE-ONLY LAN ACCESS'
[[ -f "$conf" ]] || { echo "ERROR: CUPS configuration is missing" >&2; exit 1; }

begin_count=$(grep -Fxc "$begin" "$conf" || true)
end_count=$(grep -Fxc "$end" "$conf" || true)
if [[ "$begin_count" -ne "$end_count" || "$begin_count" -gt 1 ]]; then
  echo "ERROR: malformed QuireWire CUPS policy markers; refusing mutation" >&2
  exit 1
fi

temporary=$(mktemp /etc/cups/.cupsd.conf.quirewire.XXXXXX)
cleanup() { rm -f "$temporary"; }
trap cleanup EXIT
if [[ "$begin_count" -eq 1 ]]; then
  sed "/^${begin}$/,/^${end}$/d" "$conf" > "$temporary"
else
  cp "$conf" "$temporary"
fi
cat >> "$temporary" <<'EOF'

# BEGIN QUIREWIRE M10 QUEUE-ONLY LAN ACCESS
# The Windows firewall and temporary NAT rule add the outer interface/subnet
# boundary. CUPS exposes only this print queue; root and /admin stay local-only.
ServerAlias quirewire-m4.local
<Location /printers/QuireWire_DCP_L2600D>
  Order allow,deny
  Allow all
</Location>
# END QUIREWIRE M10 QUEUE-ONLY LAN ACCESS
EOF
chown root:lp "$temporary"
chmod 0640 "$temporary"
/usr/sbin/cupsd -t -c "$temporary"
mv "$temporary" "$conf"
trap - EXIT
/usr/sbin/cupsd -t
