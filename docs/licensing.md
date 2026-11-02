# Licensing and redistribution boundary

This engineering inventory is not legal advice. It was last reviewed on
2026-11-02 and must be reviewed again before publishing any binary release.

## Repository license

Except where a file or directory says otherwise, original QuireWire source code
and documentation are available under either the Apache License 2.0 or the MIT
License, at the recipient's option. The governing files are:

- [`../LICENSE`](../LICENSE), which explains the license split;
- [`../LICENSE-APACHE`](../LICENSE-APACHE);
- [`../LICENSE-MIT`](../LICENSE-MIT); and
- [`../NOTICE`](../NOTICE).

Rust crates and the desktop npm package declare `MIT OR Apache-2.0`. Copyright
remains with the contributors; a public repository does not require a copyright
assignment from outside contributors unless the project later adopts one.

## Separately licensed source in this repository

The patch at `guest/patches/airsane-brscan5-session.patch` contains and modifies
AirSane material. It is distributed under GPL-3.0-only, not under QuireWire's
dual license. Its provenance and modification notice are in
[`../guest/patches/README.md`](../guest/patches/README.md), its SPDX mapping is
in [`../REUSE.toml`](../REUSE.toml), and the GPLv3 text is in
[`../LICENSES/GPL-3.0-only.txt`](../LICENSES/GPL-3.0-only.txt).

A release that includes a guest image or another binary containing patched
AirSane must provide the complete corresponding patched AirSane source and the
required license/notices alongside that binary. Shipping only the patch is not
sufficient for a binary distribution.

## Dependency notices

[`../Cargo.lock`](../Cargo.lock) and
[`../apps/desktop/package-lock.json`](../apps/desktop/package-lock.json) are the
exact dependency inventories for a revision. A short reviewed inventory is in
[`../THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).

The Windows desktop graph currently includes MPL-2.0 source components. A
binary distributor must retain their notices, make the MPL-covered source files
available, and tell recipients where that source can be obtained. Before a
public installer is released, generate a complete license report from the exact
lockfiles and package all required license and NOTICE material. The checked-in
summary is not a substitute for that generated binary notice bundle.

## Packaging inventory

| Component | Treatment | Reason / source |
|---|---|---|
| Original QuireWire Rust, React, Tauri, scripts and documentation | Source may be published under `MIT OR Apache-2.0` | Root license files and package metadata declare the terms. |
| AirSane compatibility patch | Source may be published under `GPL-3.0-only` | Modification/provenance notice and full GPLv3 text are included. [AirSane source](https://github.com/SimulPiscator/AirSane) |
| Microsoft Edge WebView2 Runtime | Not bundled | Windows 11 normally supplies it. A missing runtime must be obtained under Microsoft's terms. [WebView2 distribution](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution) |
| Oracle VirtualBox base package | Not bundled or silently installed | QuireWire checks for an installed supported major-7 version. This leaves Oracle packaging, drivers, updates and license presentation to Oracle. [Downloads](https://www.virtualbox.org/wiki/Downloads), [licensing FAQ](https://www.virtualbox.org/wiki/Licensing_FAQ) |
| Oracle VirtualBox Extension Pack | Not required or bundled | The tested USB path uses the base package. The Extension Pack has separate PUEL terms. [Oracle PUEL](https://www.virtualbox.org/wiki/VirtualBox_PUEL) |
| Debian installation media and packages | Not committed or bundled in the Windows installer | Package copyright files remain authoritative. Any distributed appliance needs its own complete source/notice review. [Debian license information](https://www.debian.org/legal/licenses/) |
| CUPS, SANE, AirSane and guest packages | Built into the owner-local appliance | No guest binary is copied into the Windows installer. A future appliance release requires a separate corresponding-source and notice process. |
| Brother DCP-L2600D print/scanner packages and legacy USB patch | **Owner-local only; never bundled** | The owner downloads the packages from Brother and accepts Brother's component-specific terms directly. The repository records official pages and hashes but does not assume redistribution rights. |
| Configured Brother appliance | **Owner-local only; never bundled** | It contains the Brother packages above. `*.ova`, `*.vdi`, vendor packages, keys, serial numbers and machine evidence remain ignored. |
| SumatraPDF test tool | Owner-local test artifact only; never bundled | It was used only for an explicit-printer physical test. Re-review its GPL/source obligations before any different distribution. [SumatraPDF](https://www.sumatrapdfreader.org/) |

The QuireWire installer therefore contains QuireWire executables, fixed
PowerShell lifecycle/provider scripts, guest provisioning source, manifests,
documentation and license notices. It contains no VirtualBox installer,
Extension Pack, Debian ISO, Brother package, configured appliance, private key,
USB identity or document data.

## Network disclosure

The NSIS installer itself is offline. Network access is needed only when the
owner obtains missing prerequisites or appliance inputs directly from their
publishers. Those downloads are explicit and outside the installer.

`Build-M8Installer.ps1` requires an explicit choice between an unsigned
development build and a certificate-thumbprint signing path. The repository
contains no signing key. Unsigned output must remain labeled development-only;
public production binaries should be signed and timestamped. See Tauri's
[Windows signing guide](https://v2.tauri.app/distribute/sign/windows/).

## Name and trademarks

The QuireWire name received a preliminary public-project/package search on
2026-11-02, but that is not a formal trademark clearance. Repeat the search in
the intended release jurisdictions before promotion or commercial use.

QuireWire is independent and is not affiliated with, endorsed by, or sponsored
by Brother, Microsoft, Mopria, Apple, Oracle, Debian, CUPS, SANE, AirSane or
their respective owners. Product and project names remain trademarks of their
owners.

## Public-release gate

Publishing this source tree is compatible with the checked-in license split as
reviewed above, provided excluded vendor binaries and private artifacts remain
absent. Publishing a compiled installer or appliance is a separate gate. Use
[`release-checklist.md`](release-checklist.md) and do not release binaries until
the generated dependency notices, corresponding-source duties, signing,
hardware evidence and artifact inspection are complete.
