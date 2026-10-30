# M9 bounded physical acceptance matrix

Every required row needs timestamped ignored evidence. `Software observed` must
state only what Windows/VirtualBox/CUPS actually reported; `Owner observed`
records paper/device behavior. A spooler/CUPS success alone is never a physical
pass.

The owner narrowed the M9 gate after the core soak and recovery runs to avoid
duplicative, paper-intensive stress printing. Deferred checks remain available
but do not pass implicitly and do not block M9.

## Required gate

| Scenario ID | Procedure and required observation | Physical? |
|---|---|---:|
| `sequential-text-pdf` | Submit 20 alternating fixtures; 20 distinct ordered legible sheets, no loss/duplicates | yes |
| `long-pdf` | Submit 20-page PDF; all numbered pages complete and ordered | yes |
| `usb-idle` | Unplug while idle, observe Waiting for USB, reconnect, Ready, test page | yes |
| `vm-crash` | Hard power off exact owned VM; automatic recovery within target, page | yes |
| `spooler-restart` | Scoped 15-second Spooler interruption, Ready, page | yes |
| `cups-restart` | Restart owned guest (fresh CUPS), Ready, page | yes |
| `port-conflict` | Bind exact loopback port while stopped; error without VM start; release/repair, page | yes |
| `second-instance` | Second agent rejected; original PID and singleton remain | no |
| `low-disk` | Simulated threshold refuses before submission; no real disk fill or job | no |
| `cold-start` | Owned VM stopped then started; Ready within target, page | yes |

## Deferred, non-gating stress checks

These rows are `NOT TESTED` for M9 unless separate evidence is recorded. They
must never be described as passing merely because they are not release-gating.

| Scenario ID | Optional procedure | Reason not repeated in M9 gate |
|---|---|---|
| `standard-app-text-pdf` | Repeat Notepad and Chrome normal-dialog pages | Normal-app text/PDF physically passed M0/M5; M9 did not change product binaries |
| `usb-during-print` | Unplug during a numbered long job and inspect recovery | Paper-intensive fault injection; optional stress coverage |
| `host-reboot` | Prepare/reboot/login/complete and submit a page | Prior login/reboot gates remain evidence; optional M9 repeat |
| `sleep-resume` | Sleep at least 30 seconds, resume, and submit a page | Optional environmental stress repeat |
| `no-paper` | Empty tray during a long job, refill, and inspect output | Paper-intensive and device telemetry is not reliable |
| `uninstall-reinstall` | Repeat exact owned-resource removal and installation | Physically passed M8 with the unchanged candidate binaries |
| `ui-closed` | Repeat a print with the desktop absent | Physically passed M6; M9 baseline also observed no desktop process |

Reference targets:

- agent working-set peak at or below 50 MiB;
- steady agent CPU at or below 1% of one core on the reference host;
- configured guest RAM exactly 768 MiB;
- cold start and recovery scenarios at or below 180 seconds;
- p95 Windows submission latency at or below 10 seconds;
- M9 data-root growth at or below 32 MiB and VM-directory growth at or below
  128 MiB.

Targets describe this reference release gate, not guarantees for every PC.
