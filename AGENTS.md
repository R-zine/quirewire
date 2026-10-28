# Codex agent instructions — PrintBridge

**Read `SPEC.md` in full before making changes.** It is the authoritative product/architecture/milestone specification.

## Execution rules

- **Begin at Milestone M0, and implement M0 only until it passes its physical gate.**
- Progress through M1–M9 sequentially. Do not skip milestones; each requires test evidence and a written milestone report in `docs/milestones/Mxx.md`.
- Do not fabricate actual Windows, VirtualBox, printer, USB, printed-page, benchmark, or licensing results. Software-only tests are distinct from hardware acceptance.
- If a necessary test requires a Windows host or USB printer unavailable in this environment, do everything possible without it, supply a precise human runbook, and mark the milestone `BLOCKED: REQUIRES HARDWARE`.
- Follow modularity rules: the background Rust agent runs without Tauri; desktop UI and CLI are clients of the same local IPC; providers encapsulate VirtualBox/CUPS/Windows APIs.
- Start with the proven protocol path and minimal functionality. Never implement a custom Windows kernel print driver for v1.
- Capture errors with actionable diagnostics, use tests for new functionality, and maintain safety/ownership guarantees before adding features.
- Never remove existing unrelated Windows printers, VirtualBox VMs, or user data; keep destructive operations restricted to explicitly owned PrintBridge resources.
- When unsure of installed CLI syntax or OS behavior, inspect/version-check instead of assuming; record the finding.
- After a milestone, summarize changed files, commands/tests and results, blocked real-hardware checks, and next step. Do not claim to continue work asynchronously.
- After every completed milestone, commit that milestone's reviewed changes and report the commit hash. Do not mix work from the next milestone into that commit.

## First task

Create the necessary repository skeleton, safe feasibility scripts, and `docs/feasibility.md` for **M0**. Include commands for Linux CUPS sharing and Windows IPP registration/physical text+PDF print tests; identify the Microsoft inbox driver used. If execution environment lacks the actual Windows host/USB printer, create a self-contained owner-executable checklist and stop at the physical gate. **Do not start building the GUI yet.**
