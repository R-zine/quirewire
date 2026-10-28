# ADR-001: Rust/Tauri over Go/Wails

- Status: Accepted
- Date: 2026-10-28
- Milestone: M2

## Context

PrintBridge needs a long-running, non-UI Windows controller, a small CLI, typed
state and error contracts, provider isolation, and eventually a desktop/tray UI.
The engine must continue when the UI is closed. The main implementation options
considered were Rust with Tauri 2 and Go with Wails.

M1 establishes that the guest VM dominates the known resource budget:

- 768 MiB was assigned to the Debian VM and approximately 715 MiB was visible in
  the guest;
- sampled guest usage was approximately 193–214 MiB, with approximately
  500–521 MiB available and swap unused;
- the guest disk used approximately 1.3 GiB;
- measured clean guest startup completed in 8.653–9.175 seconds.

No Rust agent existed during those measurements. Controller RSS, CPU, startup,
and total VirtualBox host-process RSS are therefore **not measured yet**. The
specification's controller goal of under 50 MiB resident memory remains a target,
not an M2 result. This ADR does not invent a Rust-versus-Go benchmark.

## Decision

Use Rust for the domain, controller, providers, IPC, agent, and CLI. Use Tauri 2
for the desktop only when M7 begins. The background agent and CLI will not depend
on Tauri or the webview.

Reasons:

- Rust gives explicit ownership and error handling around destructive VM/printer
  operations without a garbage-collected runtime in the long-lived controller.
- Traits map directly to the external boundaries already proven in M0/M1 and can
  be exercised through deterministic fakes.
- One language can cover the service, CLI, protocol, provider adapters, and the
  native side of the later Tauri UI.
- A framework-free core keeps the UI replaceable and makes headless behavior the
  default rather than an alternate mode.
- Since the VM is already the dominant assigned footprint, optimization effort
  should first protect correctness and recovery. Controller overhead will still
  be measured against the target rather than assumed negligible.

## Alternatives

### Go with Wails

Go would provide fast builds, straightforward concurrency, and a productive
single-binary controller. Wails could provide a comparable web UI shell. It was
not selected because PrintBridge benefits from Rust's compile-time ownership
model around resource identity and cleanup, and the reference architecture
already calls for Tauri 2. This is a tradeoff, not a claim that Go would exceed a
resource budget; no comparative benchmark was run.

### UI-hosted backend

Rejected. Closing a desktop window must not stop printing. Provider and lifecycle
code therefore belongs in the independent agent, never in the webview process.

## Consequences

- M2 pins and tests a Rust workspace with no Tauri dependency.
- Tauri/React work remains deferred to M7 and communicates only through the
  versioned agent API.
- Compile times and Rust expertise are accepted costs.
- Later milestones must measure agent RSS/CPU/startup on the real Windows host and
  revise the target or design based on evidence.
- The VM footprint measurements above are a baseline, not a controller benchmark.
