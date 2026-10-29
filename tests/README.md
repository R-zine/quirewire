# Tests

Milestone-specific software-only tests live below this directory. They never
substitute for the physical acceptance gates in `SPEC.md`.

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
- `cargo test --workspace --all-features` runs domain, state-machine, retry,
  telemetry, protocol, CLI, fake-contract, command-parser, ownership, USB, and
  real-provider unit tests.

