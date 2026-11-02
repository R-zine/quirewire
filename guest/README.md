# Reproducible M4 Linux appliance

This directory builds the minimal, headless Debian appliance required by M4. The
build has two deliberate layers:

1. `quirewire-m4-base.ova` contains Debian, CUPS, IPP tools, loopback-key SSH,
   log rotation, and health scripts. It contains no Brother package.
2. `quirewire-m4-dcpl2600d.owner-local.ova` is produced locally after applying
   an owner-selected driver medium. It must not be redistributed until the
   Brother package licence has been reviewed.

The queue name is intentionally fixed as `QuireWire_DCP_L2600D`. The guest has
one NAT NIC, no GUI, no password login, no sudo grant, and no CUPS remote admin.
The minimal base includes pinned D-Bus solely for systemd service health and
repair access from the unprivileged account.
CUPS is reachable from Windows only through a loopback-bound VirtualBox NAT
forward installed by the host-side acceptance script.

## Pinned inputs

The exact machine-readable values live in `manifests/`. The M4 reference build
uses:

| Input | Version / SHA-256 | Source |
|---|---|---|
| Debian amd64 netinst | 13.7.0 / `a7ef94ac2fb9a7fec454552abd629b7cc9d5155c886165a45649f5ce6167e355` | Debian release mirror in `debian-13.7-amd64.env` |
| Debian packages | snapshot `20261028T000000Z`, exact package versions in the manifest | `snapshot.debian.org` |
| Brother legacy USB patch | embedded 1.1.0-0 / `e0dbd07244327348673760f76fa2c36bcecc290357d5e9ad5c18356d79e7a9b6` | Brother FAQ in `brother-dcpl2600d.env` |
| Brother DCP-L2600D i386 driver | 4.1.0-1 / `5b1f0f21344b5d336295930441f9c25cd03fb774d07c8b58bb68ab70d0780f7e` | Brother download page in the manifest |
| Debian `printer-driver-brlaser` | 6.2.7-1 | pinned Debian snapshot |

The Brother patch filename says 1.1.1-0 while its package metadata says
1.1.0-0; both values are checked deliberately. No ISO, `.deb`, VDI, OVA,
private key, or USB serial is tracked by Git.

## Build

Run under the same non-administrator Windows account that owns VirtualBox. From
a clean checkout, download the Debian ISO from the manifest, download and accept
the Brother packages yourself, and create an installation-only SSH key:

```powershell
New-Item -ItemType Directory -Force .\artifacts\m4\ssh | Out-Null
ssh-keygen.exe -t ed25519 -N "" -C quirewire-m4-owner `
  -f .\artifacts\m4\ssh\id_ed25519

powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\guest\windows\New-M4Appliance.ps1 -Stage All `
  -DebianIsoPath .\artifacts\m1\downloads\debian-13.7.0-amd64-netinst.iso `
  -SshPublicKeyPath .\artifacts\m4\ssh\id_ed25519.pub `
  -BrotherPatchPath .\artifacts\m1\downloads\brotherlegacyusb-1.1.1-0.all.deb `
  -BrotherDriverPath .\artifacts\m1\downloads\dcpl2600dpdrv-4.1.0-1.i386.deb
```

The build verifies every hash before mutation, creates uniquely named owned
build VMs, waits for each guest to power itself off, exports OVF 2.0 with a
manifest, and deletes only VMs bearing the exact per-run ownership marker. The
Debian installer receives 1 GiB so it does not stop at its pre-preseed low-memory
dialog; the exported base, configured build, and acceptance VM all run at the
specified 768 MiB. Use `-KeepBuildVms` only for diagnosis.

## Driver workflows

`New-M4DriverMedia.ps1` builds either driver medium without modifying a VM:

```powershell
# Open/distro workflow. This is attempted before any queue mutation. On this
# tested model, pinned brlaser currently does not advertise DCP-L2600D, so the
# guest exits with an actionable unsupported-model error.
.\guest\windows\New-M4DriverMedia.ps1 -Mode open-brlaser `
  -OutputDirectory .\artifacts\m4\open-driver

# Owner-selected official workflow. Packages remain external and are verified.
.\guest\windows\New-M4DriverMedia.ps1 -Mode official-brother `
  -OutputDirectory .\artifacts\m4\official-driver `
  -BrotherPatchPath <owner-downloaded-patch.deb> `
  -BrotherDriverPath <owner-downloaded-driver.deb>
```

The official path validates SHA-256, Debian package name/version/architecture,
installs the Debian 11+ USB patch first, validates the installed PPD hash, and
records the selected hashes. A repair refuses to change the driver mode or
known-good hashes and then recreates only the intentionally named queue.

## Health and physical acceptance

The acceptance harness imports the configured OVA as a fresh VM, boots once
with the same driver medium (proving repair is idempotent), boots again without
media, verifies health through loopback SSH and IPP, and optionally submits one
physical page:

```powershell
.\guest\windows\Invoke-M4Acceptance.ps1 `
  -ConfiguredOvaPath <build>\quirewire-m4-dcpl2600d.owner-local.ova `
  -DriverMediaPath <build>\quirewire-m4-owner-driver.viso `
  -SshPrivateKeyPath .\artifacts\m4\ssh\id_ed25519 `
  -SubmitPhysicalPage
```

`quirewire-health --diagnostics` reports CUPS, queue, IPP, USB, driver mode,
jobs, bounded logs, and explicitly `physical_output=not_inferred`. It redacts
USB serial query parameters. M4 passes only after the owner confirms the paper
contains the token recorded in the ignored acceptance state.
