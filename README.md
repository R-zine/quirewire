# PrintBridge

PrintBridge has completed milestones M0 through M5:

- **M0 — feasibility:** `PASS: PHYSICAL`
- **M1 — manual VM/USB/CUPS spike:** `PASS: PHYSICAL`
- **M2 — Rust workspace/contracts/CLI/fakes:** `PASS: SOFTWARE ONLY`
- **M3 — real VirtualBox provider and USB selection:** `PASS: WINDOWS
  INTEGRATION + OWNER-GATED USB`
- **M4 — reproducible Linux appliance and guest management:** `PASS: PHYSICAL`
- **M5 — Windows IPP printer integration:** `PASS: PHYSICAL`

The proven product path remains:

```text
Windows application -> Microsoft IPP Class Driver -> Linux CUPS
                    -> Linux printer driver -> USB printer -> paper
```

Read [`SPEC.md`](SPEC.md) for the authoritative design. Milestone evidence and
limitations are in [`docs/milestones/`](docs/milestones/). Generated machine
evidence is written below `artifacts/`, which is ignored because it can contain
machine names, local paths, USB serial numbers, and print logs.

M3 replaces the fake default CLI with a real VirtualBox-backed agent handler:

```powershell
cargo run --quiet -p printbridgectl -- doctor
cargo run --quiet -p printbridgectl -- usb list
cargo run --quiet -p printbridgectl -- --config <path> vm status
cargo run --quiet -p printbridgectl -- --config <path> vm start
cargo run --quiet -p printbridgectl -- --config <path> vm stop
cargo run --quiet -p printbridgectl -- --config <path> usb attach
cargo run --quiet -p printbridgectl -- --config <path> usb release
```

Every VM mutation requires an exact canonical UUID and matching live
PrintBridge ownership metadata. USB selection uses VID:PID plus serial when
available; explicit one-based selection safely handles identical serial-less
devices without installing a broad filter. CLI and trace output redact serial
values.

See [`scripts/m3/README.md`](scripts/m3/README.md) for real VirtualBox provider
configuration and [`guest/README.md`](guest/README.md) for the reproducible M4
base/configured appliance build. M4's actual fresh-import, idempotent repair,
real-IPP health and physical page evidence is recorded in
[`docs/milestones/M04.md`](docs/milestones/M04.md).

M5 adds a marker-owned Windows queue and safe real commands:

```powershell
cargo run --quiet -p printbridgectl -- --config .\scripts\m5\m5.conf printer install
cargo run --quiet -p printbridgectl -- --config .\scripts\m5\m5.conf printer status
cargo run --quiet -p printbridgectl -- --config .\scripts\m5\m5.conf printer test-page
cargo run --quiet -p printbridgectl -- --config .\scripts\m5\m5.conf printer remove
```

See [`scripts/m5/README.md`](scripts/m5/README.md) for the physical text/PDF,
restart, independent-removal and final-reinstall gate. The persistent named-pipe
agent and GUI remain later sequential milestones and do not start until M5 passes.
