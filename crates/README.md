# Rust crates

The workspace keeps the product engine independent of any desktop framework:

| Crate | Current responsibility |
|---|---|
| `domain` | Data types, error taxonomy, component status, and provider traits |
| `core` | State machine, retry policy/fake clock, controller, fake providers, and safe structured tracing |
| `ipc` | Protocol v2 requests/responses plus the current in-process transport |
| `agent` | M2 fake handler and real M3 VirtualBox handler; executable transport is M6 |
| `cli` | Real M3 `doctor`, `vm`, and `usb` commands through the agent API |
| `provider-virtualbox` | Real, timeout-bounded `VBoxManage` provider with exact ownership and USB selection |
| `provider-cups` | Real bounded IPP health, queue, job, test-page, and diagnostics adapter |
| `provider-windows` | Boundary reserved for the real M5 provider |

No crate depends on Tauri or a shell. The CLI imports the agent/API, not the
VirtualBox provider. The M3 process runner invokes `VBoxManage` directly with
argument arrays and bounded timeouts. The M4 CUPS adapter speaks binary IPP over
a bounded TCP connection and never reports CUPS completion as physical output.
The Windows provider remains an M5 boundary; hardware-free behavior stays
explicitly labeled in `core::fake`.

