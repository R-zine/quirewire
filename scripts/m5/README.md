# M5 Windows IPP integration runbook

M5 operates on one queue named `Brother via PrintBridge` and the accepted M4
loopback endpoint:

```text
http://127.0.0.1:8644/printers/PrintBridge_DCP_L2600D
```

The reference configuration is `scripts/m5/m5.conf`. The real adapter invokes
Windows PowerShell with an argument vector and bounded timeout. Its ownership
record is per-user at `%LOCALAPPDATA%\PrintBridge\m5-windows-printer.json`.
Removal requires the live name, driver, port and ownership comment to match that
record. It never removes a printer driver or port and refuses to remove the
queue if it is the Windows default.

## Software checks

From a normal PowerShell window in the repository root:

```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features -- -D warnings
cargo test --workspace --all-features
powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
  .\tests\m5\Invoke-M5SoftwareTests.ps1
```

The M5 suite inspects the installed PrintManagement syntax, exercises only
read-only/no-op provider paths, snapshots all queues plus the default before and
after, generates the fixtures, and proves its negative recorder remains
`BLOCKED: REQUIRES HARDWARE`.

## Physical acceptance sequence

Do not infer paper output from these commands. The owner must inspect each sheet.

1. Ensure the exact accepted M4 appliance is running and still owns the selected
   USB printer. Verify TCP 8644 is reachable. Do not start or attach another VM.
2. Capture the baseline:

   ```powershell
   .\scripts\m5\windows\Collect-M5Diagnostics.ps1 -Phase Baseline
   ```

3. Install twice to prove idempotence, then inspect the result:

   ```powershell
   cargo run -q -p printbridgectl -- --config .\scripts\m5\m5.conf printer install
   cargo run -q -p printbridgectl -- --config .\scripts\m5\m5.conf printer install
   cargo run -q -p printbridgectl -- --config .\scripts\m5\m5.conf printer status
   .\scripts\m5\windows\Collect-M5Diagnostics.ps1 -Phase Installed
   ```

   Required observations: `ownership_verified: true`, driver exactly
   `Microsoft IPP Class Driver`, endpoint port 8644, spooler running, and
   `default_printer: false`. If the name already belongs to an unowned queue, the
   install must stop without changing it.

4. Submit the CLI test page:

   ```powershell
   cargo run -q -p printbridgectl -- --config .\scripts\m5\m5.conf printer test-page
   ```

   Preserve its correlation ID and optional Windows spooler job ID. The command
   reports only `accepted_by_windows_spooler`; check the physical page yourself.

5. Generate and print through ordinary applications:

   ```powershell
   .\scripts\m5\windows\New-M5TestDocuments.ps1
   notepad.exe .\artifacts\m5\test-documents\m5-standard-app-text.txt
   ```

   In Notepad choose **File > Print**, select `Brother via PrintBridge`, and
   inspect token `PRINTBRIDGE-M5-TEXT-2026`. Open
   `artifacts\m5\test-documents\m5-standard-app-pdf.pdf` in Microsoft Edge or
   another normal PDF application, select the same queue, and inspect token
   `PRINTBRIDGE-M5-PDF-IMAGE-2026` plus the checkerboard. Application print
   dialogs—not `Out-Printer` or a CUPS page—are mandatory for these two checks.

6. Reboot Windows. After login, ensure the accepted M4 appliance is running,
   then repeat `printer status` and `printer test-page`. The same queue, port,
   driver and ownership must remain and the post-restart sheet must print. Run:

   ```powershell
   .\scripts\m5\windows\Collect-M5Diagnostics.ps1 -Phase Restarted
   ```

7. Prove independent safe removal. First confirm the M5 queue is not default,
   then run removal twice:

   ```powershell
   cargo run -q -p printbridgectl -- --config .\scripts\m5\m5.conf printer remove
   cargo run -q -p printbridgectl -- --config .\scripts\m5\m5.conf printer remove
   .\scripts\m5\windows\Collect-M5Diagnostics.ps1 -Phase Removed
   ```

   Compare Baseline/Removed diagnostics. The default and every unrelated queue,
   including earlier M0/M1 evidence queues and the direct USB Brother queue, must
   be unchanged. The physical printer, VM, Microsoft driver and WSD port are not
   removal targets.

8. Reinstall once so the working product queue remains available, run status,
   and capture `-Phase Final`. Record the gate with
   `Record-M5Acceptance.ps1`, marking every check honestly. Only all `PASS`
   values plus `-OwnerConfirmedPhysicalOutput` produce `PASS: PHYSICAL`.

## Manual fallback

If the installed build does not expose `Add-Printer -IppURL`, the CLI returns a
guided fallback. In **Settings > Bluetooth & devices > Printers & scanners**,
choose **Add device > Add manually > Add a printer using an IP address or
hostname**, select **IPP Device**, enter the exact loopback URL, and verify the
resulting driver is `Microsoft IPP Class Driver`. Never select or install a
Brother Windows driver as a fallback. A manually created queue is not
marker-owned and the CLI will refuse to remove it; document and remove it only
through the same manual Windows UI after confirming its identity.

Authoritative API references checked for M5:

- <https://learn.microsoft.com/en-us/powershell/module/printmanagement/add-printer>
- <https://learn.microsoft.com/en-us/powershell/module/printmanagement/get-printer>
- <https://learn.microsoft.com/en-us/powershell/module/printmanagement/remove-printer>
- <https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/printtestpage-method-in-class-win32-printer>
