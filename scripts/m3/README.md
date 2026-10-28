# M3 VirtualBox and USB acceptance

M3 uses the real `VBoxManage` process interface through argument arrays with
bounded timeouts. It never authorizes a VM by display name: every lifecycle or
USB mutation requires a canonical UUID plus both live extra-data values:

```text
PrintBridge/Schema=printbridge.m3.owned-vm.v1
PrintBridge/Owner=<the marker in the selected configuration>
```

## Configuration

Pass `--config <path>` or set `PRINTBRIDGE_M3_CONFIG`. If neither is supplied,
the CLI reads `%LOCALAPPDATA%\PrintBridge\m3.conf` when that file exists.

```text
schema=printbridge.m3.config.v1
vm_uuid=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
vm_marker=printbridge.m3.owner-generated-marker
usb_vendor_id=04f9
usb_product_id=0567
usb_serial=owner-selected-serial-when-present
```

Treat the configuration as private because the optional serial is a stable
device identifier. CLI output and structured trace output never reveal it.

## Software and disposable-VM tests

```powershell
cargo test --workspace --all-features
cargo run --quiet -p printbridgectl -- doctor
cargo run --quiet -p printbridgectl -- usb list
powershell.exe -NoProfile -File tests/m3/Invoke-M3WindowsIntegration.ps1 `
  -SourceVmUuid <closed-source-uuid>
```

The integration harness requires a source VM stably reported as `poweroff` or
closed `aborted`, and confirms no running source process before use. It creates a full
clone, immediately removes inherited USB filters and NAT host-forwarding rules,
keeps guest NAT available for normal boot, proves the unmarked clone is rejected, applies unique M3 ownership
metadata, exposes one temporary loopback-only readiness port, waits for guest
CUPS plus a bounded settle interval before ACPI, exercises repeated
start/stop, and then deletes only that exact UUID
after revalidating both markers. It does not mutate or delete the source VM.

The current M1-derived guest needs a 90-second post-CUPS settle because an
early-boot job continues after CUPS accepts connections; ACPI sent earlier is
ignored by this image. The shutdown assertion itself remains bounded at 60
seconds and is not replaced with forced power-off.

## USB rules

- Normal selection matches VID:PID plus serial and verifies an owned filter and
  live attachment.
- `usb list` redacts serial values. If otherwise identical serial-less devices
  exist, choose the current one-based list entry with `usb attach --index N`.
  That session uses the exact host UUID and deliberately avoids a broad filter.
- `usb release` removes only the deterministic filter owned by the configured
  marker. A mismatching filter is refused, not changed.
- The real capture/release check transfers the printer away from Windows and is
  therefore owner-gated. Follow `docs/m3-acceptance.md`; do not automate consent.
