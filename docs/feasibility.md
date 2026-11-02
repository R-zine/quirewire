# M0 feasibility: Windows to Linux CUPS to USB printer

## Current decision

**Result: PASS: PHYSICAL**

The Brother USB printer is captured by an owner-authorized, disposable Fedora 44
VirtualBox guest. The guest has the official Brother RPM, a working `dcpl2600d`
CUPS queue, and a loopback-only IPP endpoint. The owner explicitly confirmed the
Linux baseline (`dcpl2600d-1`), Windows Edge PDF (`dcpl2600d-2`), and Windows
Notepad text (`dcpl2600d-3`) sheets physically printed. Windows registered
`Brother via QuireWire POC` with the Microsoft inbox IPP driver. The mandatory
M0 gate has passed; M1 has not been started.

The required Microsoft inbox driver is named **`Microsoft IPP Class Driver`**.
That is the only acceptable Windows queue driver for this proof. Its name is
specified by Microsoft and is verified after registration by the scripts below;
it is now **observed on the target queue** in this environment. A Brother
Windows driver, generic vendor driver, or a merely successful spool submission is
not an M0 pass.

## Evidence inventory

| Item | Observation as of 2026-10-27 | Status |
|---|---|---|
| Accessible Windows execution context | x64; registry `DisplayVersion=25H2`, build `26200.9711`; runtime reports `Microsoft Windows 10.0.26200` | PASS: SOFTWARE ONLY |
| PowerShell / PrintManagement | Windows PowerShell `5.1.26100.9711`; `Add-Printer` includes `-IppURL`; spooler running/automatic | PASS: SOFTWARE ONLY |
| Windows Protected Print policy | `HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\WPP` not present in this context; effective owner-machine Settings state still requires confirmation | PASS: SOFTWARE ONLY (inventory only) |
| Visible Windows queues/drivers | The pre-existing direct queue is `Brother DCP-L2600D` on `USB001` using `Brother Laser Type1 Class Driver`; the marker-owned `Brother via QuireWire POC` queue uses exactly `Microsoft IPP Class Driver` | PASS: SOFTWARE ONLY (IPP driver verified) |
| Visible USB/PnP devices | After moving from a faulty USB port, Windows enumerated Brother composite interfaces as `VID_04F9:PID_0567`; the serial was captured only in ignored local evidence | PASS: SOFTWARE ONLY (hardware enumerated) |
| IPP endpoint / TCP 631 | VirtualBox NAT forwards only `127.0.0.1:8631` to guest TCP 631; TCP probe and HTTP queue page passed; IPP Get-Printer-Attributes passed | PASS: SOFTWARE ONLY |
| Linux distribution/architecture | Fedora Linux 44 Cloud Edition, x86_64, kernel `6.19.10-300.fc44.x86_64` | PASS: SOFTWARE ONLY |
| CUPS version and shared queue | CUPS `2.4.19-3.fc44`; exact queue `dcpl2600d`; sharing on, remote-any/admin off; queue idle and accepting | PASS: SOFTWARE ONLY |
| Brother physical model and USB VID:PID | Windows PnP and the direct queue identify `DCP-L2600D`; USB `04F9:0567` | OBSERVED ON WINDOWS |
| Linux driver/package architecture/dependencies | Official Brother `dcpl2600dpdrv-4.1.0-2.i386.rpm`, SHA-256 recorded in ignored evidence, installed by DNF with i686 glibc plus x86_64 vendor binaries; PPD and `brother_lpdwrapper_DCPL2600D` verified | PASS: SOFTWARE ONLY |
| Direct Windows USB test page (not M0 acceptance) | `Win32_Printer.PrintTestPage` returned `0`, the queue drained, and the owner confirmed the sheet physically printed; this used the Brother Windows driver | PASS: PHYSICAL — DIRECT USB BASELINE ONLY |
| Linux CUPS to USB physical baseline | CUPS job `dcpl2600d-1` completed through the Brother filter and USB backend; owner explicitly confirmed the expected sheet | PASS: PHYSICAL |
| Windows text page on paper | CUPS job `dcpl2600d-3`, `m0-text-test.txt`, application metadata `Notepad`; owner confirmed the expected sheet | PASS: PHYSICAL |
| Windows PDF/image page on paper | CUPS job `dcpl2600d-2`, `m0-pdf-image-test.pdf`, printed from Microsoft Edge; owner confirmed the expected sheet | PASS: PHYSICAL |
| Optional color/duplex page | Duplex is advertised but the optional duplex fixture was not printed; device is monochrome | NOT TESTED |

`Get-ComputerInfo` and the Windows registry can retain a `Windows 10` product-name
compatibility string on newer builds, so the owner must preserve the raw diagnostics
rather than relying on that label alone. The M0 target remains a supported, patched
Windows 11 x64 machine as required by `SPEC.md`.

The host has QEMU `11.0.50`, Docker Desktop, and only the stopped `docker-desktop`
WSL distribution. An initial QEMU Fedora guest could enumerate the printer but
failed to configure its USB interface (`error -32`) under every documented QEMU
USB reset mode. With the owner's explicit request to install the Linux driver in a
VM and print from this attached machine, Oracle VirtualBox `7.2.22` was installed
with only its core and USB components. There are zero Extension Packs. VirtualBox
successfully captured the printer. This is a bounded feasibility fixture, not a
claim that the separate M1 reboot/reconnect gate or any product automation passed.

## Safety and evidence rules

- Prefer the existing Linux machine as specified for M0. On this machine the owner
  explicitly authorized the disposable VirtualBox fallback because the one USB
  printer could not remain connected to a separate Fedora host. Do not treat this
  exception as an M1 pass.
- Work on a trusted private LAN. CUPS sharing is limited to the local subnet; never
  use `cupsctl --remote-any` and never expose TCP 631 to the internet.
- Replace every angle-bracket placeholder before executing a command. Queue names
  are not display names; obtain the exact value from `lpstat -e`.
- Save raw output below `artifacts/m0/`. It is ignored by Git because it may contain
  local addresses, USB serial numbers, user names, and print document names.
- Do not change Windows Protected Print Mode for this test. Record its current
  effective state in Settings and its policy values. If behavior differs by state,
  that is evidence to analyze, not permission to silently change policy.
- Do not make the POC queue the Windows default. Do not delete printer drivers,
  ports, other queues, CUPS queues, or unrelated firewall rules.
- A CUPS job marked completed proves software processing, not paper output. The
  owner must explicitly inspect the sheets.

## Owner-executable physical acceptance checklist

Use a PowerShell window on Windows and a terminal on the existing Linux printer
host. Keep both clocks reasonably synchronized so job and log timestamps correlate.

### 1. Establish the Linux USB baseline

On Linux, plug the Brother multifunction device directly into the machine and make
sure it is powered on. Inventory queues without changing anything:

```bash
lpstat -e
lpstat -t
lsusb
```

The owner reported `dcpl2600d`. Confirm that it is the exact CUPS queue (not merely
a display/model name), then set it and the VID:PID from `lsusb`:

```bash
lpstat -e | grep -Fx 'dcpl2600d'
export PB_QUEUE='dcpl2600d'
export PB_USB_ID='<VID:PID>'
bash scripts/feasibility/linux/collect-m0-linux-diagnostics.sh \
  --queue "$PB_QUEUE" --usb-id "$PB_USB_ID"
```

Preview and then submit exactly one baseline page through the existing queue:

```bash
bash scripts/feasibility/linux/submit-m0-linux-baseline.sh --queue "$PB_QUEUE"
bash scripts/feasibility/linux/submit-m0-linux-baseline.sh --queue "$PB_QUEUE" --submit
```

Required owner observation: a legible sheet physically exits this USB printer.
Record the CUPS request ID printed by the script. If no page appears, stop: the
pre-existing Linux/driver baseline is not established and Windows IPP testing would
not isolate the intended risk.

### 2. Record the actual Linux driver and architecture

The diagnostic report records OS architecture, installed CUPS/Brother/printing
packages, the selected queue's device URI, PPD identity/filter declarations when a
PPD exists, USB VID:PID, and `lsusb -v` data. Preserve the package source separately
if the working driver came from Brother rather than the distribution. Record:

- physical model printed on the device;
- Linux distribution, release, and CPU/package architecture;
- exact package name/version/architecture and download source;
- whether the queue is driverless or uses a PPD/filter;
- the printer's stable USB VID:PID and serial when available.

Do not commit a vendor binary until redistribution terms are reviewed.

Because this driver was installed manually on Fedora, capture its exact provenance
and runtime architecture before sharing the queue:

```bash
cat /etc/fedora-release
uname -m
rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n' \
  | grep -Ei 'brother|brlaser|dcp|l2600|cups|printer'
lpstat -v 'dcpl2600d'
lpoptions -p 'dcpl2600d' -l
sudo grep -E '^\*(NickName|ModelName|Manufacturer|cupsFilter|cupsFilter2|FileVersion):' \
  /etc/cups/ppd/dcpl2600d.ppd
sudo ls -l /usr/lib/cups/filter /usr/lib64/cups/filter 2>/dev/null \
  | grep -Ei 'brother|dcp|l2600'
```

For each package or filter identified above, record ownership, architecture, and
dynamic-library requirements (replace the placeholders with the observed values):

```bash
rpm -qi '<DRIVER_RPM_NAME>'
rpm -ql '<DRIVER_RPM_NAME>'
rpm -qf '<FULL_FILTER_PATH>'
file '<FULL_FILTER_PATH>'
ldd '<FULL_FILTER_PATH>'
```

If `rpm -qf` reports that the filter is not owned by a package, record that fact and
the original download URL/checksum; do not silently repackage it. If the PPD path is
absent, record that too rather than assuming a driverless queue.

### 3. Enable narrowly scoped CUPS sharing

First inspect the plan:

```bash
bash scripts/feasibility/linux/manage-m0-cups-sharing.sh \
  --queue "$PB_QUEUE" --action plan
```

Then apply. This records the previous global and per-queue sharing values before
running the official CUPS commands `cupsctl --share-printers` and
`lpadmin -p ... -o printer-is-shared=true`. It refuses a pre-existing
`--remote-any` configuration.

```bash
sudo bash scripts/feasibility/linux/manage-m0-cups-sharing.sh \
  --queue "$PB_QUEUE" --action apply
```

Verify that cupsd is reachable on a non-loopback address, sharing is enabled, and
remote-any remains disabled:

```bash
ip -brief address
sudo ss -ltnp | grep ':631'
cupsctl | grep -E '^(_share_printers|_remote_any)='
lpstat -p "$PB_QUEUE" -l
```

If Fedora's firewalld is active and blocks TCP 631, first inspect its installed
version and active zone, then add a runtime-only rich rule for the Windows host.
This example expires automatically after two hours and is never made permanent:

```bash
sudo firewall-cmd --version
sudo firewall-cmd --state
sudo firewall-cmd --get-active-zones
export PB_FIREWALL_ZONE='<ZONE_FOR_THE_LAN_INTERFACE>'
export PB_WINDOWS_IP='<WINDOWS_IPV4>'
export PB_FIREWALL_RULE="rule family=\"ipv4\" source address=\"${PB_WINDOWS_IP}/32\" port port=\"631\" protocol=\"tcp\" accept"
sudo firewall-cmd --zone="$PB_FIREWALL_ZONE" \
  --add-rich-rule="$PB_FIREWALL_RULE" --timeout=2h
sudo firewall-cmd --zone="$PB_FIREWALL_ZONE" \
  --query-rich-rule="$PB_FIREWALL_RULE"
```

Remove it early, if the test finishes before its automatic timeout:

```bash
sudo firewall-cmd --zone="$PB_FIREWALL_ZONE" \
  --remove-rich-rule="$PB_FIREWALL_RULE"
```

Do not use `--permanent` for this feasibility test. If Fedora is using UFW instead,
first record `sudo ufw status verbose`, then use the actual Windows IPv4:

```bash
sudo ufw allow from <WINDOWS_IPV4>/32 to any port 631 proto tcp comment 'QuireWire M0 POC'
```

Do not add an any-source rule. After the POC, remove exactly that rule:

```bash
sudo ufw delete allow from <WINDOWS_IPV4>/32 to any port 631 proto tcp
```

For another firewall manager, create the equivalent temporary TCP/631 rule limited
to the single Windows address and record both its add and exact removal commands.

### 4. Validate the IPP endpoint and advertised attributes on Linux

Use the Linux host's trusted-LAN IPv4 address, not `localhost`, in the Windows URL:

```bash
export PB_LINUX_IP='<LINUX_LAN_IPV4>'
export PB_IPP_URI="ipp://${PB_LINUX_IP}:631/printers/${PB_QUEUE}"
ipptool -tv "$PB_IPP_URI" /usr/share/cups/ipptool/get-printer-attributes.test \
  | tee artifacts/m0/linux/ipp-attributes.txt
```

If the test file lives elsewhere, find it without guessing:

```bash
find "$(cups-config --datadir)" -name get-printer-attributes.test -print
```

Preserve at least `printer-uri-supported`, `printer-state`,
`document-format-supported`, `media-supported`, `color-supported`, and
`sides-supported`. The `printer-uri-supported` value must be reachable from Windows;
if it advertises an internal or different host, record that exact mismatch before
diagnosis.

Re-run the collector after sharing so the changed configuration and IPP attributes
are in one timestamped report:

```bash
sudo bash scripts/feasibility/linux/collect-m0-linux-diagnostics.sh \
  --queue "$PB_QUEUE" --usb-id "$PB_USB_ID" --ipp-uri "$PB_IPP_URI"
```

### 5. Prepare Windows documents and baseline diagnostics

In PowerShell from the repository root, substitute the URL from step 4:

```powershell
$IppUrl = 'ipp://<LINUX_LAN_IPV4>:631/printers/<EXACT_CUPS_QUEUE>'
$PocName = 'Brother via QuireWire POC'

powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\feasibility\windows\New-M0TestDocuments.ps1

Test-NetConnection -ComputerName '<LINUX_LAN_IPV4>' -Port 631

powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\feasibility\windows\Collect-M0WindowsDiagnostics.ps1 `
  -PrinterName $PocName -IppUrl $IppUrl
```

In **Settings > Bluetooth & devices > Printers & scanners**, record whether
Windows protected print mode is shown as enabled or disabled. Do not change it.
The diagnostic script also records the documented group-policy key at
`HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Printers\WPP` when configured.

### 6. Attempt manual Windows IPP registration

Microsoft's directed-discovery procedure is:

1. Open **Settings > Bluetooth & devices > Printers & scanners**.
2. Select **Add device**, then **Add new device manually**.
3. Choose **Add a printer using an IP address or hostname**.
4. Select **IPP Device** as device type.
5. Enter the full `$IppUrl`, including `/printers/<EXACT_CUPS_QUEUE>`.
6. Finish the wizard and give only this new queue a recognizable POC name.

Immediately capture its actual metadata:

```powershell
Get-Printer | Sort-Object Name |
  Format-Table Name, DriverName, PortName, PrinterStatus, Type -AutoSize
```

Required driver value: **`Microsoft IPP Class Driver`**. Record the wizard result,
queue name, driver, and any error before continuing. If desired, remove only this
just-created manual test queue in Windows Settings after capturing evidence; do not
remove a driver or port and do not remove any pre-existing queue.

### 7. Register the script-owned Windows IPP POC queue

First preview, then explicitly apply:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\feasibility\windows\Manage-M0IppPrinter.ps1 `
  -Action Register -PrinterName $PocName -IppUrl $IppUrl

powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\feasibility\windows\Manage-M0IppPrinter.ps1 `
  -Action Register -PrinterName $PocName -IppUrl $IppUrl -Apply

powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\feasibility\windows\Manage-M0IppPrinter.ps1 `
  -Action Inspect -PrinterName $PocName
```

The apply path is equivalent to the required direct command:

```powershell
Add-Printer -Name 'Brother via QuireWire POC' -IppURL $IppUrl
```

The wrapper additionally marks ownership, refuses name collisions, probes the TCP
endpoint, captures metadata, and fails unless the installed driver is exactly
`Microsoft IPP Class Driver`. It never asks Windows to install a Brother driver.

### 8. Physically print from normal Windows applications

Do not use a script, CUPS web test page, or PrintManagement cmdlet for these two
required jobs.

1. Open `artifacts\m0\test-documents\m0-text-test.txt` in **Notepad** (or another
   ordinary Windows text editor). Use **File > Print**, select
   `Brother via QuireWire POC`, and print one page.
2. Inspect the physical sheet. Confirm the title, complete path text, and token
   `QUIREWIRE-M0-TEXT-2026`. Record application, local time, CUPS request ID, job
   outcome, and `PASS` or `FAIL`.
3. Open `artifacts\m0\test-documents\m0-pdf-image-test.pdf` in a normal PDF viewer
   such as Microsoft Edge or Adobe Acrobat Reader. Use its ordinary Print dialog,
   select the POC queue, and print one page.
4. Inspect the physical sheet. Confirm legible text, the red/blue raster
   checkerboard, and token `QUIREWIRE-M0-PDF-IMAGE-2026`. Record the same evidence.
5. If the IPP attributes advertise color and duplex, open
   `m0-duplex-color-test.pdf`, select two-sided/color in the normal Print dialog,
   and verify FRONT and BACK appear on opposite sides with the expected colors.
   Record `NOT SUPPORTED` if those capabilities are not advertised; this optional
   result does not block M0.

While printing, correlate Windows and CUPS state without treating completion as
physical proof:

```powershell
Get-PrintJob -PrinterName $PocName |
  Format-Table Id, DocumentName, JobStatus, Status, SubmittedTime, TotalPages, PagesPrinted
```

```bash
lpstat -W all -o "$PB_QUEUE"
sudo journalctl --since '-15 minutes' -u cups.service --no-pager
sudo tail -n 300 /var/log/cups/error_log
```

After both jobs, capture final Windows diagnostics:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\feasibility\windows\Collect-M0WindowsDiagnostics.ps1 `
  -PrinterName $PocName -IppUrl $IppUrl
```

### 9. Record the explicit human result

Example for a successful run (replace every value and add photo paths if desired):

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\feasibility\windows\Record-M0Acceptance.ps1 `
  -LinuxUsbBaseline PASS `
  -WindowsTextPhysical PASS `
  -WindowsPdfPhysical PASS `
  -ColorDuplexPhysical NOT_SUPPORTED `
  -DriverName 'Microsoft IPP Class Driver' `
  -PrinterName $PocName `
  -IppUrl $IppUrl `
  -LinuxQueue '<EXACT_CUPS_QUEUE>' `
  -WindowsTextApplication 'Notepad' `
  -WindowsPdfApplication 'Microsoft Edge' `
  -CupsJobIds '<QUEUE-101>','<QUEUE-102>' `
  -Notes '<PHYSICAL SHEET OBSERVATIONS>' `
  -ConfirmPhysicalObservation
```

For an unrun or failed test, pass `NOT TESTED` or `FAIL`; the recorder will not
produce a physical pass. Send back the generated acceptance Markdown plus the
redacted Linux and Windows diagnostics. The repository's committed feasibility and
milestone reports can then be updated from actual evidence.

### 10. Cleanup only owned POC changes

Preview and remove the marker-owned Windows queue:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\feasibility\windows\Manage-M0IppPrinter.ps1 `
  -Action Remove -PrinterName $PocName

powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\feasibility\windows\Manage-M0IppPrinter.ps1 `
  -Action Remove -PrinterName $PocName -Apply
```

Restore only the two CUPS sharing values recorded by the apply step:

```bash
sudo bash scripts/feasibility/linux/manage-m0-cups-sharing.sh \
  --queue "$PB_QUEUE" --action restore
```

Remove the exact firewall rule from step 3 if one was added. Cleanup deliberately
does not delete the Linux queue, Linux driver, Windows printer driver/port, any
unrelated Windows queue, or any other user data.

## Interpretation and failure capture

| Symptom | Evidence to preserve | Next M0 action |
|---|---|---|
| Windows cannot reach TCP 631 | Windows TCP probe, Linux `ss`, firewall status, IP/subnet | Fix only LAN reachability/scope; do not use `--remote-any` |
| `Add-Printer -IppURL` fails | Full PowerShell error, OS build, WPP state, IPP attributes, CUPS log | Compare endpoint path and advertised `printer-uri-supported`; also record manual-wizard result |
| Queue uses a different driver | `Get-Printer`, `Get-PrinterDriver`, wizard screenshots/errors | **FAIL** this proof; do not install a Brother Windows driver |
| Windows job errors before reaching CUPS | Windows PrintService logs and `Get-PrintJob` | Diagnose Windows IPP negotiation/policy |
| CUPS accepts then rejects job | Job ID, `document-format-*`, `error_log`, filter/package metadata | Diagnose advertised formats and Linux driver/filter |
| CUPS says completed but no sheet exits | CUPS job/log, printer panel state, physical observation | **FAIL** physical test; inspect USB/backend/device errors |
| Text prints but PDF/image does not | Both job records, IPP formats, CUPS filter log | **FAIL** required PDF path; do not advance |

## Go/no-go rule

M0 is `PASS: PHYSICAL` only when all are true:

- the selected queue first prints a real page directly from Linux through USB;
- a normal Windows text application physically prints the known text sheet;
- a normal Windows PDF viewer physically prints the known PDF/image sheet;
- the Windows queue reports exactly `Microsoft IPP Class Driver`;
- no Brother-specific Windows printer driver was installed or used;
- the owner explicitly confirms the physical sheets and supplies the recorded
  evidence (photo is useful but an explicit result plus logs is acceptable).

If systematic diagnosis ends with registration or either required physical print
failing, M0 is `FAIL` and M1 does not begin. A mock, generated PDF, reachable CUPS
web page, accepted spool job, unit test, or software-only diagnostic never upgrades
this status.

## Authoritative references checked for M0

- [OpenPrinting: Printer Sharing](https://openprinting.github.io/cups/doc/sharing.html)
- [OpenPrinting: `cupsctl(8)`](https://openprinting.github.io/cups/doc/man-cupsctl.html)
- [OpenPrinting: Command-Line Printer Administration](https://openprinting.github.io/cups/doc/admin.html)
- [firewalld: `firewall-cmd(1)`](https://firewalld.org/documentation/man-pages/firewall-cmd.html)
- [Brother DCP-L2600D Linux RPM downloads](https://support.brother.com/g/b/downloadlist.aspx?c=as_ot&lang=en&os=127&prod=dcpl2600d_eu_as)
- [Brother: Fedora uses the RPM package format](https://support.brother.com/g/b/faqend.aspx?c=ae&faqid=faq00100713_000&ftype3=100258&lang=en&prod=dcpl2600d_eu_as)
- [Microsoft Learn: `Add-Printer`](https://learn.microsoft.com/en-us/powershell/module/printmanagement/add-printer)
- [Microsoft Learn: Using Microsoft IPP Class Driver](https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-connector-with-ipp)
- [Microsoft Learn: Windows protected print mode](https://learn.microsoft.com/en-us/windows/modern-print/windows-protected-print-mode/windows-protected-print-mode-for-enterprises)
- [Microsoft Learn: Printers Policy CSP](https://learn.microsoft.com/en-us/windows/client-management/mdm/policy-csp-printers)

