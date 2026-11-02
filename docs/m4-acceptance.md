# M4 physical acceptance checklist

M4 cannot pass on unit tests, a successful OVA export, an IPP response, or a
completed CUPS job alone.

- [x] Build started from the pinned source and Debian ISO hash.
- [x] Base OVA built unattended and contains no Brother package.
- [x] Owner-local configured OVA was created from a fresh base OVA import.
- [x] Official package name, embedded version, architecture, source and hashes
      were validated; restricted binaries were not committed.
- [x] A new acceptance VM was imported from the configured OVA with 1 vCPU and
      768 MiB RAM.
- [x] The exact USB device `04f9:0567` was attached; no unrelated USB device or
      VM was changed.
- [x] Reapplying the same driver medium completed and powered off normally.
- [x] With build media removed, CUPS was active, `QuireWire_DCP_L2600D` was
      idle and accepting, IPP passed, and the USB device was present.
- [x] The host endpoint was loopback-only and CUPS remote administration was
      disabled.
- [x] The harness submitted token `M4-20261028T204354Z`; CUPS returned idle.
- [x] **Owner inspected the sheet and confirmed the recorded token printed.**

Result: **PASS: PHYSICAL** on 2026-10-28.

If the last item is not confirmed, record `BLOCKED: REQUIRES HARDWARE` (or
`FAIL` if output was wrong), stop M4, and do not start M5.
