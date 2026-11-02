# QuireWire

QuireWire lets Windows and trusted devices on your local network print to and
scan from a USB multifunction device whose best driver support is on Linux. It
runs only when you open it: start QuireWire when you need the device, then use
**Exit QuireWire (stop sharing)** to release the USB device and the memory used
by its private Linux guest.

The reference system is Windows 11 x64 with a Brother DCP-L2600D. QuireWire
uses standard protocols, but other printer/scanner models have not yet passed
the project's physical acceptance process.

## Features

- Prints from ordinary Windows applications through the Microsoft IPP Class
  Driver; no custom Windows kernel driver is installed.
- Shares printing with phones and computers on one explicitly approved local
  IPv4 subnet while QuireWire is running.
- Scans from the QuireWire interface, Windows Scan, Mopria Scan, macOS Image
  Capture, and Linux AirScan/eSCL clients.
- Displays the scanner's IPv4 address for clients that require manual setup.
- Captures only the exact USB device selected by the owner and refuses
  ambiguous or unowned resources.
- Keeps document and scan contents out of agent logs and diagnostics.
- Runs on demand, not as an always-on Windows service or login application.
- Removes only resources carrying QuireWire's ownership markers during repair
  or uninstall.

Fax is not supported. Network access is intended for a trusted, non-isolated
home or small-office LAN, not an untrusted or routed network.

## How it works

```text
Windows apps -- Microsoft IPP ---------------+
LAN devices -- IPP + eSCL/AirScan -----------+-- QuireWire agent
QuireWire desktop/CLI -- owner-only IPC ------+        |
                                                       v
                                            VirtualBox Linux guest
                                                       |
                                                CUPS + SANE/AirSane
                                                       |
                                                 selected USB MFP
```

The Rust background agent owns orchestration. The desktop and CLI are clients
of the same local, owner-only IPC interface. VirtualBox, Windows printer APIs,
CUPS, LAN discovery, and scanning are isolated behind provider boundaries.

## Requirements

- Windows 11 x64 and one interactive Windows user.
- Oracle VirtualBox 7.1 or later in the major-7 series. The Extension Pack is
  not required.
- Microsoft Edge WebView2 Runtime, normally included with Windows 11.
- At least 12 GiB free disk space and 768 MiB RAM for the running guest.
- A USB printer/scanner supported by Linux. The tested device is the Brother
  DCP-L2600D (`04f9:0567`).
- A trusted local network without wireless client isolation for phone or LAN
  access.

Building from source also requires Git, the Rust toolchain declared in
[`rust-toolchain.toml`](rust-toolchain.toml), Node.js 24.15+, npm, PowerShell 5.1+
and the Tauri 2 Windows prerequisites.

## Installation status

QuireWire does not yet publish a supported signed binary release. The
repository can build an explicitly unsigned development installer, but Windows
may show a SmartScreen warning and the installer still requires an owner-built
Linux appliance.

The configured appliance is deliberately not distributed: it can contain
vendor printer/scanner packages that QuireWire is not licensed to redistribute.
VirtualBox, Debian installation media, vendor packages, private keys,
configured OVA/VDI files, and USB identities are also excluded from this
repository and its installer.

## Set up from source

1. Clone this repository and install the requirements above.
2. Follow [`guest/README.md`](guest/README.md) to download the pinned Debian
   input, obtain any required vendor packages directly from their publisher,
   and build the owner-local appliance.
3. Complete the appliance's physical print acceptance. QuireWire never treats
   a queued software job as proof that paper printed.
4. Create the protected host configuration with
   [`New-M6Configuration.ps1`](scripts/m6/windows/New-M6Configuration.ps1).
   The script verifies the accepted appliance, exact VM UUID, ownership
   metadata, USB identity and loopback endpoints.
5. Build the unsigned development installer from the repository root:

   ```powershell
   .\scripts\m8\windows\Build-M8Installer.ps1 -UnsignedDevelopmentBuild
   ```

6. Run the generated `target\release\bundle\nsis\*-setup.exe`, then open
   QuireWire. In Setup, choose the exact USB device, read the whole-device
   capture notice, grant consent and select **Confirm & enable bridge**.
7. For phone or LAN access, approve only the current trusted interface and its
   directly attached subnet. Printing and scanning have separate approvals;
   follow the exact commands in [`docs/install.md`](docs/install.md).

For local development without packaging the installer:

```powershell
cargo build --workspace

Push-Location .\apps\desktop
npm ci
npm run build
Pop-Location
```

The complete build, test, signing and architecture notes are in
[`docs/development.md`](docs/development.md).

## Daily use

1. Connect and power on the multifunction device.
2. Open QuireWire and wait for **Ready**.
3. Print to **Brother via QuireWire**, or open the Scan page to use the local
   scanner. LAN clients can discover the services only while the app is on.
4. Closing the window keeps QuireWire in the notification area. Use the
   explicit Exit command when you want to stop sharing, shut down the guest and
   release its memory.

See [`docs/usage.md`](docs/usage.md) for Windows, Android/Mopria, macOS and
Linux client instructions. Repair and uninstall steps are in
[`docs/install.md`](docs/install.md), with failure guidance in
[`docs/troubleshooting.md`](docs/troubleshooting.md).

## Tests and project status

Milestones M0 through M11 have completed their specified software and physical
acceptance gates on the reference system. Evidence summaries are kept in
[`docs/milestones/`](docs/milestones/); machine-specific artifacts remain
ignored because they may contain local paths, machine names or USB identifiers.

Run the software suite with:

```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --offline -- -D warnings
cargo test --workspace --all-features --offline

Push-Location .\apps\desktop
npm ci
npm test
npm run build
Pop-Location

.\tests\public\Invoke-PublicSourceTests.ps1
Get-ChildItem .\tests -Filter 'Invoke-*SoftwareTests.ps1' -Recurse |
    ForEach-Object { & $_.FullName }
```

Real VirtualBox, Windows queue, USB, scan and paper-output checks are separate
hardware tests; see the relevant milestone runbooks before running them.

## Security and privacy

QuireWire binds management interfaces to loopback and creates narrowly scoped
LAN rules only after explicit approval. Scanning approval is separate because
it grants local-network devices access to document acquisition. Diagnostics
record states and actionable errors, not print or scan payloads. Review the
threat model and trust boundary in [`docs/security.md`](docs/security.md).

## Licensing

Original QuireWire code and documentation are dual licensed under
[Apache-2.0](LICENSE-APACHE) or [MIT](LICENSE-MIT), at your option. The AirSane
compatibility patch is a separately identified GPL-3.0-only derivative; see
[`guest/patches/README.md`](guest/patches/README.md) and
[`LICENSES/GPL-3.0-only.txt`](LICENSES/GPL-3.0-only.txt). Dependencies and
external programs keep their own terms. Read [`LICENSE`](LICENSE),
[`NOTICE`](NOTICE), [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md), and
[`docs/licensing.md`](docs/licensing.md) before distributing binaries.

QuireWire is an independent project. Brother, Microsoft, Windows, Mopria,
AirScan, Apple, macOS, Oracle, VirtualBox, Debian, CUPS, SANE and AirSane are
names or trademarks of their respective owners; their mention does not imply
affiliation, endorsement or sponsorship.

## Documentation

- [Installation, repair and uninstall](docs/install.md)
- [User guide](docs/usage.md)
- [Known limitations](docs/known-limitations.md)
- [Troubleshooting](docs/troubleshooting.md)
- [Security model](docs/security.md)
- [Developer guide](docs/development.md)
- [Architecture decisions](docs/adr/README.md)
- [Product specification](SPEC.md)
