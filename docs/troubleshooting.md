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
| Agent unavailable | The on-demand agent is still starting or the desktop heartbeat stopped | Keep/open PrintBridge and retry; run installer Repair if the installed agent is missing; never create an elevated ad-hoc agent |
| Waiting for USB | The exact accepted USB identity is absent or still owned by Windows | Power on/reconnect that printer, wait, then use Repair; do not broaden the USB filter |
| Guest stopped/error | Owned VM could not start or crashed | Check VirtualBox 7.x is installed, then use Restart/Repair; never start/delete by display name |
| CUPS error | IPP is unavailable or guest printing is unhealthy | Use Restart/Repair; only the selected print queue—not CUPS administration—is exposed to a trusted LAN |
| Local network unavailable | Explicit interface/subnet approval is absent or no longer matches, the exact firewall rules are absent, or DNS-SD failed | Verify the approved alias and CIDR, then run installer Repair; never enable an Any-profile, Any-interface, or broader-subnet rule |
| Phone cannot find printer | Phone is on another subnet/guest Wi-Fi, mDNS is filtered, its Android Default/Mopria Print Service is disabled, or PrintBridge is not Ready | Keep the app running, use the same non-isolated LAN, enable the phone's print service, and check the Local network component; routed discovery is unsupported |
| Windows queue error | Spooler is stopped, queue is absent, or ownership drifted | Start the Windows Spooler if appropriate; run installer Repair for scoped UAC queue recreation |
| Port conflict | Another process owns the configured loopback port | Stop the conflicting process only if you own it; PrintBridge refuses to start the VM into a collision |
| Job accepted, no paper | Acceptance proves only spooler submission | Check paper/toner/printer panel, CUPS status, USB capture, and retry after fixing the physical condition |
| No-paper is not shown | This printer/driver may not propagate `media-empty` through IPP | Use the printer panel and physical observation; PrintBridge must not claim telemetry it does not receive |
| Terminal flashes | Every release background child, including the cached owner-SID lookup, must use no-console creation flags | Stop PrintBridge to restore usability, collect a bounded process-name/path trace, and report the result; do not assume the source is unrelated |
| Low disk | Setup or the M9 guard refuses before new work | Free space on the installation/VM volume; do not delete arbitrary VM or user files |
| Queue is Windows default during uninstall | Safe uninstall refuses removal | Select another default printer, then retry uninstall |

If ownership validation fails, stop. Do not rename a VM/queue marker or delete
state to force cleanup. Preserve the error and use the diagnostic export.

Microsoft documents the Windows IPP registration surface in
[`Add-Printer`](https://learn.microsoft.com/en-us/powershell/module/printmanagement/add-printer),
and Oracle documents exact-VM lifecycle commands in
[`VBoxManage`](https://docs.oracle.com/en/virtualization/virtualbox/7.1/user/vboxmanage.html).
