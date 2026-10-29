# Rust crates

The workspace keeps the product engine independent of any desktop framework:

| Crate | Current responsibility |
|---|---|
| `domain` | Data types, error taxonomy, component status, and provider traits |
| `core` | State machine, retry policy/fake clock, controller, fake providers, and safe structured tracing |
| `ipc` | Protocol v3 requests/responses plus the current in-process transport |
| `agent` | Fake/M3 handlers plus the real M5 Windows-printer handler; executable transport is M6 |
| `cli` | Real M3 `doctor`/`vm`/`usb` and M5 `printer` commands through the agent API |
| `provider-virtualbox` | Real, timeout-bounded `VBoxManage` provider with exact ownership and USB selection |
| `provider-cups` | Real bounded IPP health, queue, job, test-page, and diagnostics adapter |
| `provider-windows` | Real timeout-bounded PrintManagement/IPP adapter with marker-owned queue safety |

No crate depends on Tauri or a shell. The CLI imports the agent/API, not the
VirtualBox provider. The M3 process runner invokes `VBoxManage` directly with
argument arrays and bounded timeouts. The M4 CUPS adapter speaks binary IPP over
a bounded TCP connection and never reports CUPS completion as physical output.
The Windows provider invokes a tracked PowerShell adapter with argument arrays,
uses a versioned response protocol, verifies Microsoft IPP Class Driver, and
never infers physical output. Hardware-free behavior stays explicitly labeled
in `core::fake`.

