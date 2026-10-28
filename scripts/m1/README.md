# M1 manual spike tools

These tools support the manually built M1 Debian/VirtualBox spike. They do not
create, provision, start, stop, attach, detach, or delete a VM or USB device.
Generated evidence defaults below `artifacts/m1/`, which is ignored because raw
logs can contain machine names, user names, document names, and device serials.

| Script | Changes system state? | Purpose |
|---|---:|---|
| `windows/Collect-M1HostDiagnostics.ps1` | No; creates evidence files only | Captures the owned VM's bounded configuration/state, target USB visibility without its serial, loopback IPP reachability, and the owned Windows queue |
| `windows/Manage-M1IppPrinter.ps1` | Only with `Register/Remove -Apply` | Creates/removes one marker-owned M1 IPP queue on a loopback endpoint; preserves drivers, ports, and unrelated queues |
| `linux/collect-m1-guest-diagnostics.sh` | No | Captures Debian resources, CUPS/driver packages, redacted USB/queue state, listeners, jobs, and IPP attributes |
| `windows/Record-M1Acceptance.ps1` | No; creates evidence files only | Converts explicit observations into an honest M1 result and refuses a physical pass unless every required lifecycle stage is confirmed |

Run the software checks with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\tests\m1\Invoke-M1SoftwareTests.ps1
```

The complete owner procedure and the exact physical gates are in
[`docs/m1-acceptance.md`](../../docs/m1-acceptance.md). No script or completed
print job can prove that paper physically printed; owner confirmation is required.
