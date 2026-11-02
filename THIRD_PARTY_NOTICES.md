# Third-party notices

QuireWire is built with third-party open-source libraries and interoperates
with separately installed software. Each component remains under its own
license. `Cargo.lock` and `apps/desktop/package-lock.json` are the authoritative
version inventories for a particular source revision.

## Source included in this repository

| Component | Version / revision | License | Treatment |
|---|---|---|---|
| AirSane compatibility patch | Upstream commit `08ff4d798d718e2e50ef805404ddef82f6d03cc1` | GPL-3.0-only | The patch and modification provenance are public. No AirSane binary is bundled. See `guest/patches/README.md`. |

## Direct application dependencies

| Component | Locked version | License expression |
|---|---:|---|
| Tauri | 2.11.6 | Apache-2.0 OR MIT |
| React | 19.3.1 | MIT |
| React DOM | 19.3.1 | MIT |
| Tauri JavaScript API | 2.11.1 | Apache-2.0 OR MIT |
| Tokio | 1.53.1 | MIT |
| Serde / serde_json | 1.0.229 / 1.0.151 | MIT OR Apache-2.0 |
| mdns-sd | 0.21.6 | MIT OR Apache-2.0 |
| quick-xml | 0.38.4 | MIT |
| windows-sys | 0.61.2 | MIT OR Apache-2.0 |

The Windows desktop dependency graph also contains the following MPL-2.0
source components: `cssparser 0.36.0`, `cssparser-macros 0.6.1`,
`dtoa-short 0.3.5`, `option-ext 0.2.0`, and `selectors 0.36.1`. MPL-2.0 permits
these files to be part of a larger work under different terms, but a binary
distributor must preserve their notices, make their covered source available,
and tell recipients where to obtain it.

## Required binary-release step

Before publishing an installer or other compiled artifact, generate a complete
license inventory from the exact lockfiles, collect every required license and
NOTICE file, and package that material with the artifact. The public source
revision used for the build must remain available. The current repository does
not treat a short dependency table as a substitute for a generated binary
notice bundle.

## Separately installed or owner-supplied software

QuireWire does not redistribute VirtualBox, the VirtualBox Extension Pack,
WebView2, Debian installation media, Brother print/scanner packages, SumatraPDF,
or a configured guest appliance. Their respective vendors and copyright
holders license those components separately. See `docs/licensing.md` for the
packaging boundary.
