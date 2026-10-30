# Security model

## Trust and privilege boundaries

- `printbridge-agent.exe` and the Task Scheduler entry run as the installing
  interactive user with a Limited token. There is no service or persistently
  elevated UI process.
- The desktop and CLI send only fixed typed commands over a versioned named pipe
  with a protected owner-SID DACL and first-instance singleton enforcement.
- Queue creation/removal requests one-time UAC only after a read-only exact
  ownership check. VirtualBox/CUPS control never accepts arbitrary IPC commands.
- The Linux guest uses NAT. CUPS and key-only SSH forwards bind to Windows
  loopback; no CUPS administration or password login is exposed to the LAN.

## Ownership and destructive operations

- VM operations require canonical UUID plus matching live schema and owner
  extradata. Uninstall preserves the accepted pre-existing M4 appliance.
- Printer operations require exact name, endpoint, Microsoft IPP driver, live
  ownership comment, and protected state. Drivers, ports, default printer, and
  unrelated queues are not removed.
- Startup cleanup verifies the exact task action, arguments, SID, and ownership
  description. File deletion is bounded below the manifest data root.

## Data and diagnostics

The USB serial is stored only where required for exact selection in ACL-protected
configuration/state. It is excluded from IPC device output, logs, diagnostics,
M9 metrics, and committed evidence. Diagnostics can still contain local paths,
SID, VM UUID, queue names, process IDs, and timing; treat exports as private.

The optional M9 process/resource collectors omit command lines, environment
variables, window titles, and file contents. Test documents contain only public
tokens. No driver packages, configured OVA, SSH private key, or machine evidence
is committed.

## Remaining risks

- The installer is currently an unsigned development artifact and may trigger
  SmartScreen. Production release requires Authenticode signing and validation.
- VirtualBox and Brother components are owner-installed dependencies with their
  own update and licensing boundaries.
- Whole-device USB capture intentionally makes the multifunction device
  unavailable to native Windows while the guest owns it.
- A compromised owner account can control that account's printer and VM; the
  product does not attempt to defend against its owning user.

Windows Protected Print Mode is never silently changed. See Microsoft's
[current policy documentation](https://learn.microsoft.com/en-us/windows/modern-print/windows-protected-print-mode/windows-protected-print-mode).
