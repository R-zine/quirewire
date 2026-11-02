# Tests

Milestone-specific software-only tests live below this directory. They never
substitute for the physical acceptance gates in `SPEC.md`.

- `public/Invoke-PublicSourceTests.ps1` verifies the license split, package
  metadata, AirSane provenance/hash, installer notices, readable README,
  complete rebrand, and absence of bundled appliances, vendor packages,
  private keys, or compiled binaries.
- `quality/Invoke-QualityHookTests.ps1` verifies the version-controlled hook,
  local-only installer, offline quality commands, CI parity, and strict
  exclusion of physical and disposable-VM tests.
- `m0/Invoke-M0SoftwareTests.ps1` verifies the M0 feasibility tools and fixtures.
- `m1/Invoke-M1SoftwareTests.ps1` verifies the M1 diagnostics, redaction/safety
  invariants, lifecycle fixtures, and negative acceptance paths.
- `m3/Invoke-M3WindowsIntegration.ps1` creates a disposable marked clone,
  removes inherited capture/host-forwarding rules, proves ownership refusal,
  and exercises repeated real VirtualBox start/stop before exact cleanup.
- `m4/Invoke-M4SoftwareTests.ps1` checks guest script syntax, pinned inputs,
  source/binary separation, protected endpoints, repair guards, diagnostics,
  unsafe-input rejection, and the owner-only physical gate recorder.
- `m5/Invoke-M5SoftwareTests.ps1` checks the real PrintManagement capability,
  versioned provider protocol, loopback/ownership/default-printer guards,
  idempotent absent removal, CLI truthfulness, standard-app fixtures, and the
  negative physical-gate recorder without changing an installed queue.
- `m6/Invoke-M6SoftwareTests.ps1` checks the typed IPC allow-list, frame bound,
  owner-only pipe DACL, OS singleton, immutable state, bounded backoff,
  idempotency cache, exact M4 ownership, Task Scheduler safeguards, redaction,
  PowerShell syntax, and absence of Tauri from every headless crate.
- `m7/Invoke-M7SoftwareTests.ps1` checks the Tauri/agent dependency boundary,
  fixed desktop commands, tray exit semantics, CSP/capability, accessible UI
  behavior through fake-client flows, frontend production build, and the
  negative physical-gate recorder.
- `m8/Invoke-M8SoftwareTests.ps1` checks NSIS/current-user packaging, scoped
  one-time printer elevation, non-console background execution, fixed resource
  discovery, exact ownership cleanup, bounded data deletion, configuration
  migration, explicit signing choice, and licensing/resource disclosures.
- `m9/Invoke-M9SoftwareTests.ps1` checks the mixed-job fixture generator,
  exact-owner Notepad/PDF application boundary, redacted metrics, bounded recovery scenarios,
  non-destructive low-disk simulation, complete physical matrix, documentation,
  and negative hardware-gate recorders.
- `m11/Invoke-M11SoftwareTests.ps1` checks pinned scanner inputs, exact USB
  permissions, offline guest provisioning, bounded eSCL parsing, protocol v7,
  separately approved firewall/NAT resources, AirScan discovery, content-free
  diagnostics, fixed local browser launch, and the no-paper physical gate.
- `cargo test --workspace --all-features` runs domain, state-machine, retry,
  telemetry, protocol, CLI, fake-contract, command-parser, ownership, USB, and
  real-provider, secure-pipe, supervisor, startup, and desktop unit tests.

