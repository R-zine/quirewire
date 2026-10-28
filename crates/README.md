# Rust crates

The M2 workspace keeps the product engine independent of any desktop framework:

| Crate | M2 responsibility |
|---|---|
| `domain` | Data types, error taxonomy, component status, and provider traits |
| `core` | State machine, retry policy/fake clock, controller, fake providers, and safe structured tracing |
| `ipc` | Versioned request/response contract plus an in-process M2 transport |
| `agent` | Framework-free request handler over the core controller; executable transport is M6 |
| `cli` | `printbridgectl status`, `doctor`, and `help` against the fake in-process agent |
| `provider-virtualbox` | Boundary reserved for the real M3 provider |
| `provider-cups` | Boundary reserved for the real M4 provider |
| `provider-windows` | Boundary reserved for the real M5 provider |

No M2 crate depends on Tauri, a Windows API binding, VirtualBox, CUPS, or a shell.
The placeholder provider crates deliberately contain no simulated real behavior;
hardware-free behavior lives only in `core::fake` and is labeled as fake by the
CLI.

