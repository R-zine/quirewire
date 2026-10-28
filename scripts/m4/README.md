# M4 operator runbook

Read `guest/README.md` first. The short path is:

1. Run `tests/m4/Invoke-M4SoftwareTests.ps1` and the Rust workspace checks.
2. Build both appliance layers with `guest/windows/New-M4Appliance.ps1`.
3. Keep the Brother printer connected and powered on. If Windows owns a busy
   connection after the exact VM filter is installed, power-cycle only that
   printer once; never detach another USB device.
4. Run `guest/windows/Invoke-M4Acceptance.ps1 -SubmitPhysicalPage` against the
   newly exported configured OVA and driver medium.
5. Inspect the page for the exact token printed by the harness. Record the
   answer without claiming that CUPS completion proves paper output:

   ```powershell
   .\guest\windows\Record-M4Acceptance.ps1 `
     -StatePath <acceptance-dir>\acceptance-state.json `
     -PhysicalPagePrinted yes
   ```

6. Preserve the configured OVA and driver packages only under ignored local
   `artifacts/`; their redistribution remains pending licence review.

The acceptance VM remains running so the physical result can be checked. Its
UUID and exact ownership marker are stored in `acceptance-state.json`; later
milestones must operate by those values, not by display name.
