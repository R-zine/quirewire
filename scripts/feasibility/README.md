# M0 feasibility tools

These tools exercise only the M0 path. They do not install a VM, daemon, CLI, or
GUI. Run commands from the repository root unless the command says otherwise.

| Script | Changes state? | Purpose |
|---|---:|---|
| `linux/collect-m0-linux-diagnostics.sh` | No | CUPS/Linux/USB versions, queue/driver data, IPP attributes, configuration, jobs, and logs |
| `linux/manage-m0-cups-sharing.sh` | Only with `--action apply` or `restore` | Shares one existing queue on the local subnet and records/restores the two prior sharing values |
| `linux/submit-m0-linux-baseline.sh` | Only with `--submit` | Sends one file to one existing Linux CUPS queue; never changes the queue |
| `windows/New-M0TestDocuments.ps1` | Creates files only | Generates required text, one-page PDF/image, and optional two-page color/duplex documents |
| `windows/Collect-M0WindowsDiagnostics.ps1` | No system changes | Captures Windows build, IPP cmdlet support, policy state, queue/driver metadata, USB IDs, jobs, and print events |
| `windows/Manage-M0IppPrinter.ps1` | Only with `Register/Remove -Apply` | Creates/removes one marker-owned IPP POC queue and verifies `Microsoft IPP Class Driver` |
| `windows/Record-M0Acceptance.ps1` | Creates evidence only | Converts explicit owner observations into `PASS: PHYSICAL`, `FAIL`, or `BLOCKED: REQUIRES HARDWARE` |

Generated evidence defaults to `artifacts/m0/`. That directory is ignored because
logs may contain machine names, addresses, USB serials, user names, and document
names. Review and redact before sharing. The committed, self-contained procedure is
[`docs/feasibility.md`](../../docs/feasibility.md).

