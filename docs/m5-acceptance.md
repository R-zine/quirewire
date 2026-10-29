# M5 physical acceptance checklist

M5 cannot pass on unit tests, queue creation, spooler acceptance, a Windows job
disappearing, or CUPS completion alone.

- [x] Installed PrintManagement version and `Add-Printer -IppURL` support were
      inspected on the actual Windows build.
- [x] Software tests preserve the existing queue inventory and default printer.
- [x] The marker-owned `Brother via PrintBridge` queue installs twice without
      duplication and uses the stable M4 endpoint.
- [x] Its driver is exactly `Microsoft IPP Class Driver`; no Brother Windows
      driver is selected as a fallback.
- [x] `printbridgectl printer test-page` returns a correlation ID and the owner
      confirms its physical sheet.
- [x] Notepad prints token `PRINTBRIDGE-M5-TEXT-2026` on paper through the M5
      queue.
- [x] A normal PDF application prints token
      `PRINTBRIDGE-M5-PDF-IMAGE-2026` and its checkerboard on paper.
- [x] After a Windows restart, the same name, endpoint, port, ownership and
      Microsoft driver remain, and another physical test page prints.
- [x] `printer remove` removes only the marker-owned queue, a repeated remove is
      a no-op, and the physical device/VM remain independent.
- [x] Baseline/removed evidence proves the default and every unrelated printer
      stayed unchanged.
- [x] The queue is reinstalled once and final status is healthy.
- [x] The owner explicitly confirms all physical sheets.

Result: **PASS: PHYSICAL** on 2026-10-29.

The owner confirmed the CLI test page, Notepad text fixture, Edge PDF/image
fixture, and post-Windows-restart test page all physically printed correctly.
The safe removal restored the exact pre-M5 queue inventory and preserved the
default printer; the final marker-owned queue is installed and healthy.
