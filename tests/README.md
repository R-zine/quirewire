# Tests

Milestone-specific software-only tests live below this directory. They never
substitute for the physical acceptance gates in `SPEC.md`.

- `m0/Invoke-M0SoftwareTests.ps1` verifies the M0 feasibility tools and fixtures.
- `m1/Invoke-M1SoftwareTests.ps1` verifies the M1 diagnostics, redaction/safety
  invariants, lifecycle fixtures, and negative acceptance paths.
- `cargo test --workspace --all-features` runs M2 domain, state-machine, retry,
  telemetry, protocol, CLI, and fake provider contract tests.

