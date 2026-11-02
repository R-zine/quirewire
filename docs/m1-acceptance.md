# M1 manual VM/USB/CUPS acceptance

This is the owner-executable procedure for M1's hard physical gate. It applies to
the disposable, manually built spike only; it is not a product installer or the
reproducible M4 guest appliance. An accepted Windows/CUPS job is never counted as
a printed page without an explicit observation of the paper.

## Fixed test resources

| Resource | M1 value |
|---|---|
| Owned VM | `QuireWire-M1-Debian13` |
| Owned VM UUID | `fd91fe56-f746-4884-9aa7-3b972882183a` |
| VirtualBox | `7.2.22`, base package, zero Extension Packs |
| Guest | Debian 13.7 x86_64 minimal, no desktop |
| VM resources | 1 vCPU, 768 MiB RAM, 10 GiB dynamically allocated disk |
| VM frontend | headless |
| Network | NAT; M1 host `127.0.0.1:8632` to guest TCP `631`; management `127.0.0.1:2222` to guest TCP `22` |
| USB selector | Brother `04f9:0567` plus exact serial; serial intentionally omitted from committed files |
| Guest queue | `DCPL2600D` |
| Windows queue | `Brother via QuireWire M1` |
| Required Windows driver | `Microsoft IPP Class Driver` |
| IPP URL | `ipp://127.0.0.1:8632/printers/DCPL2600D` |

The guest uses CUPS `2.4.10-3+deb13u2`, Brother's official
`dcpl2600dpdrv-4.1.0-1.i386.deb` (SHA-256
`5b1f0f21344b5d336295930441f9c25cd03fb774d07c8b58bb68ab70d0780f7e`),
and Brother's Debian 11+ legacy USB patch file
`brotherlegacyusb-1.1.1-0.all.deb` (SHA-256
`e0dbd07244327348673760f76fa2c36bcecc290357d5e9ad5c18356d79e7a9b6`).
The latter file's embedded package metadata reports version `1.1.0-0`; this is an
upstream filename/package-version inconsistency. Neither package is committed or
redistributed.

## Safety rules

- Run lifecycle commands against the UUID above, never a display-name match.
- Do not remove or reconfigure another VM, USB filter, Windows printer, driver, or
  port. The preserved M0 Fedora VM and direct Brother Windows queue are out of
  scope.
- USB capture transfers the whole multifunction device away from Windows. This is
  expected; direct Windows printing/scanning is unavailable while captured.
- Do not paste USB serials into committed reports. Evidence belongs under ignored
  `artifacts/m1/` and must be reviewed before sharing.
- Host reboot is performed manually only after saving this checklist and closing
  work. No script in M1 initiates a Windows reboot.

## Common commands

Open an elevated PowerShell at the repository root and set only these scoped
variables:

```powershell
$VBox = 'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe'
$Vm = 'fd91fe56-f746-4884-9aa7-3b972882183a'
$M1 = Join-Path $PWD 'artifacts\m1'
$Ssh = @(
  '-p', '2222', '-i', (Join-Path $M1 'ssh\id_ed25519'),
  '-o', 'IdentitiesOnly=yes', '-o', 'BatchMode=yes',
  '-o', 'StrictHostKeyChecking=yes',
  '-o', "UserKnownHostsFile=$(Join-Path $M1 'ssh\known_hosts')",
  'quirewire@127.0.0.1'
)
```

Collect redacted/read-only evidence at any stage:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\m1\windows\Collect-M1HostDiagnostics.ps1 `
  -VmUuid $Vm

Get-Content .\scripts\m1\linux\collect-m1-guest-diagnostics.sh -Raw |
  & ssh.exe @Ssh "tr -d '\r' | bash -s -- --queue DCPL2600D --usb-id 04f9:0567"
```

## Physical acceptance checklist

### 1. Preconditions and exact capture

1. Power on the printer and connect it to the known-working USB port.
2. Run `& $VBox list usbhost`. Locate exactly one `04f9:0567` device and verify
   its serial against the ignored local selection record. Do not copy the serial
   into a report.
3. Start only the owned VM: `& $VBox startvm $Vm --type headless`.
4. Verify `& ssh.exe @Ssh 'lsusb -d 04f9:0567; systemctl is-active cups; lpstat -p DCPL2600D -l'`.
5. Verify the Windows endpoint and inbox driver:

   ```powershell
   Test-NetConnection 127.0.0.1 -Port 8632
   Get-Printer -Name 'Brother via QuireWire M1' |
     Format-List Name, DriverName, PrinterStatus, PortName, Comment
   ```

Pass only if the device is inside the guest, CUPS is active/idle, TCP succeeds,
and the driver is exactly `Microsoft IPP Class Driver`.

- [x] Exact selected USB captured; unrelated USB devices untouched.
- [x] VM is headless with 1 vCPU and 768 MiB RAM.
- [x] Direct Windows Brother queue is unavailable while the guest owns USB.
- [x] CUPS and loopback IPP endpoint are healthy.

### 2. Guest physical baseline

Submit a uniquely labeled plain-text page inside the guest, retain its CUPS job
ID, and inspect the output. The already executed baseline used M0's known text
fixture and completed as `DCPL2600D-1`.

- [x] CUPS accepted and completed guest job `DCPL2600D-1`.
- [x] Owner explicitly confirmed that the guest baseline page physically printed.
- [x] The same driver/USB path was re-exercised by all later stage prints.

### 3. Initial Windows text and PDF/image

1. Open `scripts/m1/test-data/m1-windows-text-test.txt` in Notepad.
2. Open `artifacts/m1/test-documents/m1-windows-pdf-image-test.pdf` in the normal
   PDF viewer. It is a local copy of the physically proven M0 image/PDF fixture.
3. Print each from the application's ordinary Print UI to
   `Brother via QuireWire M1`.
4. Record the new CUPS job IDs with `& ssh.exe @Ssh 'lpstat -W all -o DCPL2600D'`.
5. Confirm the text token `QUIREWIRE-M1-WINDOWS-TEXT-2026`, the PDF image, page
   edges, and legibility on paper.

- [x] Text page physically printed from Notepad.
- [x] PDF/image page physically printed from the normal PDF viewer.
- [x] Both jobs are correlated with CUPS IDs and the Microsoft inbox IPP queue.

### 4. Clean guest boot

1. Ensure the queue is idle. Request a clean ACPI shutdown:
   `& $VBox controlvm $Vm acpipowerbutton`.
2. Poll `& $VBox showvminfo $Vm --machinereadable` until
   `VMState="poweroff"`; do not force power off.
3. Start a stopwatch, then run `& $VBox startvm $Vm --type headless`.
4. Record time to SSH, CUPS, IPP, and target USB readiness. Confirm the VM has no
   GUI frontend and the exact filter recaptured only `04f9:0567`.
5. Open `scripts/m1/test-data/m1-clean-boot-text-test.txt` in Notepad and print it
   to the POC queue. Correlate the CUPS job and inspect the paper for token
   `QUIREWIRE-M1-CLEAN-BOOT-2026`.

- [x] Clean ACPI shutdown completed.
- [x] Clean headless start recovered SSH, CUPS, IPP, and USB.
- [x] Recovery time recorded.
- [x] Clean-boot page physically printed and CUPS job correlated.

### 5. Physical USB disconnect/reconnect

1. With the guest running and idle, unplug the printer's USB cable for at least
   ten seconds. Confirm `lsusb -d 04f9:0567` no longer finds it.
2. Reconnect to the known-working port and wait up to 30 seconds. Record whether
   the VirtualBox filter automatically attaches it.
3. If automatic attachment fails, manual remediation is allowed for M1 only:
   inspect `& $VBox list usbhost`, verify both VID:PID and the stored exact serial,
   copy that device's VirtualBox UUID, then run
   `& $VBox controlvm $Vm usbattach '<verified-host-usb-uuid>'`. Never select by
   bus/address alone.
4. Confirm guest `lsusb`, CUPS idle/enabled, and loopback IPP reachability.
5. Print `scripts/m1/test-data/m1-usb-reconnect-text-test.txt` from Notepad.
   Correlate the job and inspect the paper for token
   `QUIREWIRE-M1-USB-RECONNECT-2026`.

- [x] Owner explicitly confirmed the physical unplug/wait/reconnect sequence.
- [x] Post-reconnect host and guest state verified automatic capture; no manual remediation occurred.
- [x] Reconnect page physically printed and CUPS job correlated.

### 6. Windows host reboot

The M1 VM deliberately has no product autostart; that belongs to M6. Save open
work first. Cleanly shut down the M1 VM, reboot Windows manually, sign back into
the same account, and resume from this file.

After Windows returns:

1. Confirm the printer is present on the working USB port.
2. Confirm the M1 VM is powered off; record that M1 requires manual startup.
3. Run `& $VBox startvm $Vm --type headless` and repeat the health checks from
   step 1. Record automatic versus manual USB capture.
4. Print `scripts/m1/test-data/m1-host-reboot-text-test.txt` from Notepad and
   inspect the paper for token `QUIREWIRE-M1-HOST-REBOOT-2026`.
5. Collect both diagnostics reports and correlate the CUPS job.

- [x] Windows host actually rebooted; date/time recorded.
- [x] Manual headless VM startup dependency recorded.
- [x] USB, CUPS, IPP, and Microsoft inbox queue recovered.
- [x] Post-host-reboot page physically printed and CUPS job correlated.

### 7. Record the gate

Only after every box above is supported by logs and explicit paper observation,
run `Record-M1Acceptance.ps1` with the real job IDs. Example shape:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\scripts\m1\windows\Record-M1Acceptance.ps1 `
  -VmUuid $Vm `
  -GuestUsbBaseline PASS -WindowsTextPhysical PASS -WindowsPdfPhysical PASS `
  -CleanGuestBootPhysical PASS -UsbReconnectPhysical PASS -HostRebootPhysical PASS `
  -ExactUsbCapture PASS -HeadlessOperation PASS `
  -DriverName 'Microsoft IPP Class Driver' `
  -QueueName 'Brother via QuireWire M1' `
  -JobEvidence 'Replace with every correlated real CUPS job ID and stage.' `
  -Notes 'Replace with observed capture/remediation and timings.' `
  -OwnerConfirmedPhysicalOutput
```

Any `FAIL` yields `FAIL`. Missing tests, the wrong Windows driver, incomplete
metadata, or missing owner confirmation yields `BLOCKED: REQUIRES HARDWARE`.

## Current checkpoint

The guest baseline is physically confirmed. The first Windows Notepad submission
through the preserved M0 POC queue failed before reaching CUPS because its WSD
port cached the M0 printer UUID while the Debian queue advertises a different
UUID. The M0 queue is preserved for audit. The dedicated M1 endpoint/queue fixed
that identity collision: the owner confirmed Windows Notepad text and Edge PDF
jobs `DCPL2600D-2` and `DCPL2600D-3`. A clean headless boot automatically captured
USB, reached the systemd target in 9.175 seconds, and physically printed job
`DCPL2600D-4`. A physical unplug/reconnect then automatically recaptured USB with
no manual attach, and reconnect job `DCPL2600D-5` physically printed. Windows then
actually rebooted at 12:40:45 local time. The expected manual headless VM start
restored USB/CUPS/IPP/the Windows queue, and the owner confirmed post-reboot job
`DCPL2600D-6` physically printed. The final acceptance record returned
**PASS: PHYSICAL**. M1 is complete; M2 is permitted but has not been started.
