# Rust crates

The workspace keeps the product engine independent of any desktop framework:

| Crate | Current responsibility |
|---|---|
| `domain` | Data types, error taxonomy, component status, and provider traits |
| `core` | State machine, retry policy/fake clock, controller, fake providers, and safe structured tracing |
| `ipc` | Protocol v4 typed wire messages, owner-only Windows named pipe, plus legacy in-process transport |
| `agent` | Standalone M6 supervisor executable plus legacy fake/M3/M5 handlers |
| `cli` | M6 named-pipe client commands plus legacy M3/M5 development commands |
| `provider-virtualbox` | Real, timeout-bounded `VBoxManage` provider with exact ownership and USB selection |
| `provider-cups` | Real bounded IPP health, queue, job, test-page, and diagnostics adapter |
| `provider-windows` | Real timeout-bounded PrintManagement/IPP adapter with marker-owned queue safety |

No crate depends on Tauri or a shell. The CLI imports the agent/API, not the
VirtualBox provider. The M3 process runner invokes `VBoxManage` directly with
argument arrays and bounded timeouts. The M4 CUPS adapter speaks binary IPP over
a bounded TCP connection and never reports CUPS completion as physical output.
The Windows provider invokes tracked PowerShell adapters with argument arrays,
uses versioned response protocols, verifies Microsoft IPP Class Driver, and
owns only its exact per-user startup task. The M6 agent persists immutable
desired-state generations, reconciles providers with bounded backoff, and
never infers physical output. Hardware-free behavior stays explicitly labeled
in `core::fake`.

