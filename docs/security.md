# Security model

## Trust and privilege boundaries

- `printbridge-desktop.exe` launches `printbridge-agent.exe` on demand as the
  installing interactive user with a Limited token. No service, login task, or
  persistently elevated UI process is installed.
- The desktop and CLI send only fixed typed commands over a versioned named pipe
  with a protected owner-SID DACL and first-instance singleton enforcement.
- Queue and scoped firewall creation/removal request one-time UAC only after a
  read-only exact ownership check. VirtualBox/CUPS control never accepts
  arbitrary IPC commands.
- The Linux guest uses NAT. The Windows queue and key-only SSH remain loopback
  only. While the app is running, one separately marker-owned IPP forward binds
  to the active IPv4 address of one explicitly approved default-route interface
  and subnet. Printing permits TCP 8644; scanning requires a second explicit
  approval before TCP 8645 is permitted. Firewall rules are restricted to the
  exact programs, those TCP ports or agent UDP 5353, `Profile=Private,Public`,
  interface alias, and remote CIDR. The
  reference approval is only `Ethernet 3` plus `192.168.100.0/24`; Public does
  not mean another interface or subnet is allowed. CUPS administration, SSH,
  named-pipe control, and password login are never exposed to the LAN.
- AirSane runs as the unprivileged `saned` user and receives access only to the
  exact Brother USB VID/PID through a dedicated group rule. Guest mDNS is off;
  the host agent publishes `_uscan._tcp` only on the approved interface while
  the app is running. eSCL is a trusted-LAN protocol without per-scan user
  authentication, so scan approval must not be granted on an untrusted subnet.
  VirtualBox preserves the original forwarded peer address, so the guest accepts
  RFC1918 IPv4 peers but no public source range; the host firewall remains the
  authoritative narrower boundary for the one approved interface and CIDR.
- Normal AirSane debug logging is disabled because it records job timing and
  option metadata. The M11 diagnostic tooling enables it only in an explicitly
  marked disposable raw clone; that clone and its log are deleted after bounded
  failure analysis.
- The guest retains CUPS `--no-remote-admin --no-remote-any` as its baseline and
  adds one validated marker block for `/printers/PrintBridge_DCP_L2600D` only.
  The CUPS root and `/admin` locations remain local-only.

## Ownership and destructive operations

- VM operations require canonical UUID plus matching live schema and owner
  extradata. Uninstall preserves the accepted pre-existing M4 appliance.
- Printer operations require exact name, endpoint, Microsoft IPP driver, live
  ownership comment, and protected state. Drivers, ports, default printer, and
  unrelated queues are not removed.
- Legacy-startup cleanup verifies the exact task action, arguments, SID, and
  ownership description before removal. LAN NAT/firewall cleanup likewise
  requires exact schema/marker identity. File deletion is bounded below the
  manifest data root.

## Data and diagnostics

The USB serial is stored only where required for exact selection in ACL-protected
configuration/state. It is excluded from IPC device output, logs, diagnostics,
M9 metrics, and committed evidence. Diagnostics can still contain local paths,
SID, VM UUID, queue names, process IDs, and timing; treat exports as private.

Scan pixels, document bytes, previews, output filenames, and scan history never
enter the agent IPC, state, logs, or diagnostics. They flow directly between the
consumer and AirSane. Browser/client applications control their downloaded files.

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
