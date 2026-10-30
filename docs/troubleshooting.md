# Troubleshooting

Start with the dashboard or the owner-only CLI:

```powershell
$cli = "$env:LOCALAPPDATA\PrintBridge\bin\printbridgectl.exe"
& $cli status
& $cli diagnostics
```

Do not post diagnostic exports publicly: they omit the USB serial but can contain
local paths, account SID, VM UUID, and printer names.

| Symptom | Meaning | Safe action |
|---|---|---|
| Agent unavailable | The per-user task has not started or exited | Check `\PrintBridge\Agent`, then rerun installer Repair; never create a second ad-hoc elevated agent |
| Waiting for USB | The exact accepted USB identity is absent or still owned by Windows | Power on/reconnect that printer, wait, then use Repair; do not broaden the USB filter |
| Guest stopped/error | Owned VM could not start or crashed | Check VirtualBox 7.x is installed, then use Restart/Repair; never start/delete by display name |
| CUPS error | Loopback IPP is unavailable or guest printing is unhealthy | Use Restart/Repair; CUPS is intentionally not exposed to the LAN |
| Windows queue error | Spooler is stopped, queue is absent, or ownership drifted | Start the Windows Spooler if appropriate; run installer Repair for scoped UAC queue recreation |
| Port conflict | Another process owns the configured loopback port | Stop the conflicting process only if you own it; PrintBridge refuses to start the VM into a collision |
| Job accepted, no paper | Acceptance proves only spooler submission | Check paper/toner/printer panel, CUPS status, USB capture, and retry after fixing the physical condition |
| No-paper is not shown | This printer/driver may not propagate `media-empty` through IPP | Use the printer panel and physical observation; PrintBridge must not claim telemetry it does not receive |
| Terminal flashes | Release agent/provider children are GUI/no-console processes | Stop PrintBridge to isolate; if flashing continues, investigate the unrelated process rather than changing PrintBridge ownership state |
| Low disk | Setup or the M9 guard refuses before new work | Free space on the installation/VM volume; do not delete arbitrary VM or user files |
| Queue is Windows default during uninstall | Safe uninstall refuses removal | Select another default printer, then retry uninstall |

If ownership validation fails, stop. Do not rename a VM/queue marker or delete
state to force cleanup. Preserve the error and use the diagnostic export.

Microsoft documents the Windows IPP registration surface in
[`Add-Printer`](https://learn.microsoft.com/en-us/powershell/module/printmanagement/add-printer),
and Oracle documents exact-VM lifecycle commands in
[`VBoxManage`](https://docs.oracle.com/en/virtualization/virtualbox/7.1/user/vboxmanage.html).
