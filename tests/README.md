# Tests

Milestone-specific software-only tests live below this directory. They never
substitute for the physical acceptance gates in `SPEC.md`.

- `m0/Invoke-M0SoftwareTests.ps1` verifies the M0 feasibility tools and fixtures.
- `m1/Invoke-M1SoftwareTests.ps1` verifies the M1 diagnostics, redaction/safety
  invariants, lifecycle fixtures, and negative acceptance paths.
- `m3/Invoke-M3WindowsIntegration.ps1` creates a disposable marked clone,
  removes inherited capture/host-forwarding rules, proves ownership refusal,
  and exercises repeated real VirtualBox start/stop before exact cleanup.
- `cargo test --workspace --all-features` runs domain, state-machine, retry,
  telemetry, protocol, CLI, fake-contract, command-parser, ownership, USB, and
  real-provider unit tests.

