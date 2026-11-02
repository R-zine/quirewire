# M11 physical acceptance — driverless scanning

Result: `PASS: PHYSICAL` on the accepted Brother DCP-L2600D. These checks used
the scanner only and did not print or consume paper. The owner used a
non-sensitive flatbed test sheet and inspected the resulting files locally.

## Scope and prerequisites

- The exact accepted VM and USB identity remain unchanged.
- The owner-local Brother `brscan5` 1.7.0-0 package has been verified by SHA-256
  and installed only inside the owned Linux guest.
- AirSane is built from pinned GPL-3.0 source commit
  `08ff4d798d718e2e50ef805404ddef82f6d03cc1` plus the hash-pinned source patch
  for [upstream issue #132](https://github.com/SimulPiscator/AirSane/issues/132).
- QuireWire is open, the USB device is powered on, and the dashboard reports
  the eSCL scanner ready.
- LAN printing is already approved. Separately approve TCP 8645 for scanning:

```powershell
$root = (Resolve-Path '.').Path
$config = Join-Path $env:LOCALAPPDATA 'QuireWire\m6.conf'
& "$root\scripts\m11\windows\Set-M11ScanApproval.ps1" `
  -Action Approve -ConfigPath $config
```

Run the installed lifecycle Repair once after approval so the exact
`VBoxHeadless.exe` TCP 8645 firewall rule is created for the already approved
interface/subnet. No other interface, subnet, executable, or Public-network
scope is authorized.

## Software/host preflight

1. `quirewirectl status` reports protocol 7, `components.scanner=ready`, the
   model, at least `platen`, a document format, and a loopback URL.
2. `Test-M11Escl.ps1` succeeds against `127.0.0.1:8645` and the approved LAN
   address. It retrieves capabilities only, never scan pixels.
3. `quirewire-agent diagnose-scan <LAN IPv4> 8645 --output <file>` resolves
   **Brother via QuireWire Scanner** as `_uscan._tcp`, with the AirSane v2
   compatibility fields `rs=eSCL`, `vers=2.0`, `pdl`, `cs`, `is`, `duplex`,
   `adminurl`, and a lowercase UUID.
4. Windows Firewall contains exactly one marker-owned TCP 8645 rule limited to
   the approved interface, approved remote CIDR, `Private,Public`, and the exact
   `VBoxHeadless.exe`. The existing TCP 8644 and agent UDP 5353 rules remain
   equally scoped.

## Physical scan gate

Record each observation; protocol success alone is not physical proof.

- [x] **Unprivileged guest acquisition:** AirSane runs as `saned`, the service
  account can enumerate the exact `04f9:0567` scanner, and an eSCL scan completes.
- [x] **QuireWire desktop/browser consumer:** from the Scan screen, choose
  **Open scanner**, scan the flatbed test sheet, download it, and visually verify
  that the result is legible and correctly oriented.
- [x] **Windows inbox consumer:** after adding **Brother via
  QuireWire Scanner** without a Brother Windows driver, completes a scan, and
  the saved image is visually correct.
- [x] **Android consumer:** while on the approved Wi-Fi subnet, Mopria Scan (the
  separate scanning app, not Mopria Print Service) automatically discovers or
  is manually given the approved IPv4 address, completes a scan, and displays
  the correct image. The tested phone required Mopria's manual IPv4 add flow;
  automatic discovery did not find the otherwise valid live advertisement.
- [x] **Privacy:** agent logs, exported diagnostics, and IPC contain scanner
  capability metadata only—no document bytes, thumbnails, filenames, or scan
  history.
- [x] **Exit cleanup:** explicit Exit showed its closing state, then the desktop,
  agent, VM, TCP 8644/8645 listeners, `_ipp._tcp`, and `_uscan._tcp`
  advertisements are gone. No `quirewire-m10-lan-ipp` or
  `quirewire-m11-lan-escl` live LAN forward remains. The narrowly scoped
  persistent firewall rules may remain for the next explicit launch.

Compatible macOS Image Capture and Linux `sane-airscan` clients use the same
standard eSCL/AirScan endpoint and are covered by protocol/capability tests;
M11 does not claim physical testing on hardware that is not present.

## Gate rule

The owner confirmed every physical scan, privacy, and cleanup observation above.
M11 may be completed and committed; no later milestone is included in that
commit.
