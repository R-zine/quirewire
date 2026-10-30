# M9 release-candidate validation

M9 combines reproducible Windows measurements with owner-observed hardware
checks. A Windows spooler/CUPS success never proves that paper emerged.
Generated evidence stays under ignored `artifacts/m9/` because it contains local
paths, process IDs, printer/VM names, and timings. USB serials, command lines,
environment variables, file contents, and window titles are deliberately absent.

## Workload and metrics

Run from an ordinary PowerShell window unless a command explicitly displays a
UAC prompt:

```powershell
$root = Join-Path $env:LOCALAPPDATA 'PrintBridge'
$cli = Join-Path $root 'bin\printbridgectl.exe'
& $cli status

.\scripts\m9\windows\New-M9TestDocuments.ps1
.\scripts\m9\windows\Collect-M9Metrics.ps1 -Phase Baseline -DurationSeconds 60
.\scripts\m9\windows\Invoke-M9ApplicationSoak.ps1 -Action Plan
```

The document set contains 10 one-page text jobs, 10 one-page PDFs, and one
20-page PDF. Text uses Windows Notepad's registered `/pt` path. PDF uses a
signature-verified portable SumatraPDF with an explicit `-print-to` queue; keep
it under ignored `artifacts/m9/tools` and never bundle it. The harness verifies
each new CUPS job over loopback-only key SSH and preserves printer inventory and
the Windows default. Normal Notepad/Chrome dialog printing was physically
established in M0/M5; its M9 repeat is optional while product binaries remain
unchanged.

With paper loaded and the UI closed, submit the sequential and long workloads:

```powershell
.\scripts\m9\windows\Invoke-M9ApplicationSoak.ps1 -Action Sequential
.\scripts\m9\windows\Invoke-M9ApplicationSoak.ps1 -Action LongPdf
.\scripts\m9\windows\Collect-M9Metrics.ps1 -Phase PostSoak -DurationSeconds 60
```

Inspect every numbered/tokenized sheet. Record missing, duplicate, damaged,
blank, or reordered pages; queue drain alone is not a pass.

## Automated recovery scenarios

Run one scenario at a time and physically confirm the submitted page after every
scenario that prints:

```powershell
$scenarios = 'SecondInstance','LowDiskGuard','ColdStart','VmCrash',
  'GuestCupsRestart','PortConflict','SpoolerRestart'
foreach ($scenario in $scenarios) {
  .\scripts\m9\windows\Invoke-M9RecoveryScenario.ps1 -Scenario $scenario
}
```

`SpoolerRestart` requests one UAC approval for the bounded service stop/start.
`VmCrash` hard-powers off only the manifest UUID after checking both live
ownership markers. `GuestCupsRestart` restarts the owned guest, which starts a
fresh CUPS service; it does not claim a service-only remote restart. `LowDiskGuard`
raises its required-free-space threshold above current free space and proves no
job is submitted; it does not fill the real disk.

## Owner-timed scenarios

USB idle recovery is part of the bounded M9 gate:

```powershell
.\scripts\m9\windows\Watch-M9ManualScenario.ps1 -Scenario UsbIdle
```

The remaining manual stress checks are retained but non-gating. Run them only
when the additional paper and machine interruption are desired:

```powershell
.\scripts\m9\windows\Watch-M9ManualScenario.ps1 -Scenario UsbDuringPrint
.\scripts\m9\windows\Watch-M9ManualScenario.ps1 -Scenario SleepResume
.\scripts\m9\windows\Watch-M9ManualScenario.ps1 -Scenario NoPaper
```

For `NoPaper`, remove paper before submission and refill only after observing the
printer/UI. Some legacy devices do not propagate `media-empty` through CUPS/IPP;
the evidence records that limitation rather than inventing detection.

Host reboot is an optional two-command stress check:

```powershell
.\scripts\m9\windows\Invoke-M9HostReboot.ps1 -Action Prepare
# Restart Windows, then log in normally. Do not manually start PrintBridge.
.\scripts\m9\windows\Invoke-M9HostReboot.ps1 -Action Complete
```

## Final evidence

Use `Record-M9Scenario.ps1` only after reviewing each evidence JSON and receiving
the owner's explicit paper observation. Software-only scenarios use
`-OwnerConfirmedPhysical not-applicable`; all others require `yes` or `no`.
After all 10 required matrix entries are recorded:

```powershell
.\scripts\m9\windows\Collect-M9Metrics.ps1 -Phase Final -DurationSeconds 60
.\scripts\m9\windows\Record-M9Acceptance.ps1 `
  -MetricsBaselinePath <baseline-json> `
  -MetricsFinalPath <final-json> `
  -DocumentManifestPath .\artifacts\m9\documents\manifest.json `
  -ScenarioDirectory .\artifacts\m9\scenarios
```

The recorder remains `BLOCKED: REQUIRES HARDWARE` until every required physical
row is explicitly confirmed. The seven deferred rows are recorded as
non-gating policy, not silently passed. See `docs/m9-acceptance.md`.
