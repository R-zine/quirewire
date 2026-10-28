# PrintBridge

PrintBridge has completed **Milestone M0: feasibility** with `PASS: PHYSICAL`.
It has also completed **Milestone M1: manual VM/USB/CUPS spike** with
`PASS: PHYSICAL`. **Milestone M2: Rust workspace/contracts/CLI/fakes** is complete
with `PASS: SOFTWARE ONLY`.

The current work verifies the essential path before product development starts:

```text
Windows application -> Microsoft IPP Class Driver -> Linux CUPS
                    -> Linux printer driver -> USB printer -> paper
```

Read [`SPEC.md`](SPEC.md) for the authoritative design and
[`docs/feasibility.md`](docs/feasibility.md) for the exact M0 owner checklist.
Generated evidence is written below `artifacts/`, which is intentionally ignored
because it can contain machine names, local IP addresses, USB serial numbers, and
print logs.

The M0 Linux USB baseline and normal Windows Notepad/PDF prints were physically
confirmed through the **Microsoft IPP Class Driver**. See
[`docs/milestones/M00.md`](docs/milestones/M00.md) for the correlated CUPS job IDs
and test results. M1 physically passed normal Windows text/PDF, clean guest boot,
USB disconnect/reconnect, and actual Windows host reboot through the minimal
headless Debian guest. See
[`docs/m1-acceptance.md`](docs/m1-acceptance.md) and
[`docs/milestones/M01.md`](docs/milestones/M01.md).

The M2 `printbridgectl` is deliberately hardware-free and labels its provider
`fake-in-memory`. It exercises the same versioned request handler that the later
agent transport will expose:

```powershell
cargo run --quiet -p printbridgectl -- status
cargo run --quiet -p printbridgectl -- doctor
cargo run --quiet -p printbridgectl -- help
```

It does not invoke VirtualBox, CUPS, Windows printing APIs, or physical hardware,
and it never treats a completed fake job as physical output. Real VirtualBox work
is M3; no managed appliance, persistent background executable, named-pipe
transport, or desktop UI exists yet. See
[`docs/milestones/M02.md`](docs/milestones/M02.md). M3 is permitted but has not
been started.

