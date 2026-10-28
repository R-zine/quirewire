# PrintBridge

PrintBridge has completed milestones M0 through M3:

- **M0 — feasibility:** `PASS: PHYSICAL`
- **M1 — manual VM/USB/CUPS spike:** `PASS: PHYSICAL`
- **M2 — Rust workspace/contracts/CLI/fakes:** `PASS: SOFTWARE ONLY`
- **M3 — real VirtualBox provider and USB selection:** `PASS: WINDOWS
  INTEGRATION + OWNER-GATED USB`

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

See [`scripts/m3/README.md`](scripts/m3/README.md) for configuration and the
disposable-VM test, [`docs/m3-acceptance.md`](docs/m3-acceptance.md) for the
owner-gated USB checklist, and [`docs/milestones/M03.md`](docs/milestones/M03.md)
for actual results.

M3 does not build the reproducible appliance, implement a real CUPS provider,
install a Windows queue, run a persistent named-pipe agent, or provide a GUI.
Those remain sequential milestones M4–M7; no M4 work has started.
