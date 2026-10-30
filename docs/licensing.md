# Packaging and redistribution boundary

This is an engineering inventory, not legal advice. It was last reviewed on
2026-10-30 and must be reviewed again before any public release. M9 adds only
repository PowerShell validation tools and documentation; it adds no runtime or
redistributed third-party binary.

| Component | M8 treatment | Reason / source |
|---|---|---|
| PrintBridge Rust, React, and Tauri output | Bundled | Repository code and dependency notices are build inputs. Tauri documents NSIS packaging and resource inclusion under its MIT/Apache-compatible project terms. |
| Microsoft Edge WebView2 Runtime | Not bundled | Supported Windows 11 supplies the evergreen runtime. The installer is offline and checks the runtime; a missing runtime requires the owner to obtain Microsoft's current installer. [Microsoft WebView2 distribution](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution) |
| Oracle VirtualBox base package | Not bundled or silently installed | PrintBridge checks for a supported installed 7.1+ major-7 release and links to Oracle's installer. This avoids taking responsibility for Oracle packaging, kernel drivers, updates, and license presentation. [Oracle downloads](https://www.virtualbox.org/wiki/Downloads), [Oracle licensing FAQ](https://www.virtualbox.org/wiki/Licensing_FAQ) |
| Oracle VirtualBox Extension Pack | Not required or bundled | The tested USB path uses the base package. The Extension Pack has separate PUEL terms and is outside the product dependency set. [Oracle PUEL](https://www.virtualbox.org/wiki/VirtualBox_PUEL) |
| Debian base appliance inputs | Buildable from pinned official inputs; no OVA committed | Debian `main` packages are redistributable under their individual free-software licenses, but a public binary appliance still needs a complete corresponding notice/source review. [Debian license information](https://www.debian.org/legal/licenses/) |
| CUPS and distro packages | Built into owner-local/base appliance, subject to package notices | Package license/copyright files remain the source of truth. No separate binary is copied into the Windows installer. |
| Brother DCP-L2600D driver and legacy USB patch | **Owner-local only; never bundled** | The repository has hashes and official download pages but no verified grant allowing PrintBridge to redistribute these vendor binaries. The owner downloads and accepts Brother's terms directly. |
| Configured Brother appliance | **Owner-local only; never bundled** | It contains the Brother binaries above. `*.ova`, `*.vdi`, vendor packages, keys, and serials remain ignored artifacts. |
| SumatraPDF M9 test tool | Owner-local test artifact only; never bundled | The reference host uses the official portable, Authenticode-valid executable only because Chrome exposes no unattended explicit-printer verb. Re-review its GPL terms/source before any different use. [SumatraPDF](https://www.sumatrapdfreader.org/) |

The M8 setup executable therefore contains only PrintBridge executables,
PowerShell lifecycle/provider scripts, guest build source, manifests, and
documentation. It contains no VirtualBox installer, Extension Pack, Debian ISO,
Brother package, configured OVA, SSH private key, or USB serial.

## Network disclosure

The PrintBridge NSIS installer itself is offline. Setup needs network access only
when prerequisites are missing: to obtain VirtualBox from Oracle, WebView2 from
Microsoft on an abnormal Windows 11 image, Debian inputs, or owner-licensed
Brother packages. All such downloads are explicit and outside the installer.

## Signing

`Build-M8Installer.ps1` refuses an ambiguous build: select the explicit
`-UnsignedDevelopmentBuild` path or supply a certificate thumbprint. The signed
path signs the agent and CLI before bundling and configures Tauri to sign and
timestamp the desktop/installer. No signing certificate is available in the
repository, so CI and local development artifacts must be labeled unsigned.
[Tauri's Windows signing guide](https://v2.tauri.app/distribute/sign/windows/)
explains why unsigned downloads can show SmartScreen warnings.
