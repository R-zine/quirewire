# PrintBridge — Codex Implementation Specification

**Status:** Proposed engineering specification; hardware feasibility is **NOT YET VERIFIED**.  
**Target:** Windows 11 x64 host, USB-connected legacy Brother multifunction printer, Linux-supported print function.  
**Initial delivery:** Single-user, one printer, one Windows machine.  
**Reference stack:** Rust workspace, VirtualBox provider, minimal Debian-family Linux guest, CUPS, Windows inbox IPP printing, Tauri 2 + React/TypeScript UI.  
**Primary requirement:** Printing works through standard Windows Print dialogs without installing a Brother-specific Windows printer driver.

## 0. Agent execution contract — read first

This repository should be developed **one independently verifiable milestone at a time**. The agent must:

1. Begin by inventorying the repository, existing decisions, available operating system, and available USB/printer hardware. Never claim a physical test was performed if the hardware or Windows host is unavailable.
2. Complete the current milestone and its tests, then record the work in `docs/milestones/Mxx.md`: implementation, commands/results, measured observations, unresolved risks, and next action.
3. Do **not** claim the whole project works because mocks, unit tests, or a CUPS web page work. Actual **Windows app → Microsoft IPP printer → CUPS → USB → printed sheet** is mandatory evidence.
4. Stop progression at each **human hardware acceptance gate** until the owner supplies actual results. If the agent cannot access hardware, create an exact test script/runbook and mark the gate `BLOCKED: REQUIRES HARDWARE`.
5. Keep the system running without the graphical UI. No UI dependency in the background engine, installer, guest provisioning, or Windows print registration.
6. Use supported documented APIs/CLI; verify command syntax against the installed versions. Do not invent tool outputs or hardcode the unknown Brother model.
7. Prefer minimal, reviewable increments with working CLI functionality before cosmetic features. No feature should be declared complete with stubbed behavior.
8. Treat privileged operations, driver installation, and USB capture as opt-in. Never delete existing printers, other VirtualBox VMs, files, or global configurations without explicit consent.
9. Keep a single `docs/feasibility.md` with: host Windows version/build, printer USB VID:PID, physical model when known, Linux driver/architecture, Windows IPP driver, CUPS/VirtualBox versions, job formats and actual printed-page outcomes.
10. Favor concise ADRs over speculative abstraction. Interfaces must correspond to actual external boundaries and have a fake/test implementation.

### Initial Codex task

**Implement Milestone M0 only.** Create the repository skeleton and reproducible feasibility test scripts/runbook; do not start building the GUI or daemon. Where practical, run software-only diagnostics. Request that the owner execute the physical Windows/Linux test and supply outputs, then document the go/no-go determination. Proceed to M1 only after a recorded **PASS**.

## 1. Product requirements

### User story

A user plugs in a USB printer that works with Linux but no longer works with vendor Windows drivers, installs PrintBridge, chooses the USB device once, and obtains a printer named `Brother via PrintBridge` in Windows. From then on, printing from ordinary Windows apps works with no VM window. The bridge starts automatically at Windows login, survives closing the desktop application, displays useful errors, and can be cleanly uninstalled.

### Must-have outcomes

- Standard Windows print queue, using Windows' **built-in IPP class driver** if the feasibility gate confirms compatibility.
- Linux guest owns the **entire selected USB device** through VirtualBox USB passthrough and drives printing through CUPS and a functional Linux printer driver.
- Engine starts headlessly on login and operates when the UI is closed; Windows session must remain logged in for MVP (pre-login/system-service printing is explicitly not promised).
- One-click onboarding after prerequisites are installed, one-time user approval for selecting/capturing the USB device, readable health status, recovery after printer reconnect/reboot, and a test-page action.
- Idempotent installation and setup, safe repair, controlled restart, diagnostics export, clean uninstallation preserving third-party assets.
- No Brother-specific Windows printer driver required, no exposure of CUPS or control APIs to the LAN, no persistent VM management UI.

### Non-goals for v1

- Scanner/fax support; printing is the only mandatory function of the multifunction device.
- Multiple printers, household LAN sharing, Windows-on-ARM, pre-login printing, cloud printing, remote administration.
- Writing a Windows kernel printer driver, custom port monitor, or new IPP implementation for v1.
- Promising support for every Brother/USB printer, full vendor print-options parity, or rescuing a broken Windows print spooler in all cases.
- Silently downloading/repackaging Brother vendor driver binaries without checking source and redistribution terms.

### Supported platform definition

- **Required:** supported, fully patched Windows 11 x64 host with virtualization enabled and supported VirtualBox release.
- **Guest:** minimal x86_64 Debian-family Linux selected against the actual Brother Linux driver's dependencies. Prefer Debian minimal over Alpine until glibc/multilib compatibility is understood.
- **Windows printing:** Microsoft IPP Class Driver, including tests for Windows Protected Print Mode when relevant. Do not change system-wide protected-printing policies automatically.
- **Privilege model:** elevated installer/onboarding only when needed; ordinary user background agent and desktop UI afterward.

## 2. Architecture and ownership boundaries

```text
Windows desktop (Tauri 2 / React + TypeScript)
             | versioned local IPC only
             v
Rust PrintBridge Agent (background, non-UI)
  | State / orchestration / diagnostics / retries
  +-- HypervisorProvider (initial: VirtualBox CLI adapter)
  +-- UsbProvider        (initial: VirtualBox USB host discovery/filter)
  +-- GuestPrinter       (CUPS IPP + guest provisioning/diagnostics)
  +-- WindowsPrinter     (Windows PrintManagement/IPP adapter)
  +-- StartupProvider    (Windows Task Scheduler per-user)
             |
     VirtualBox headless Linux guest
     CUPS shared printer + working Linux driver
             |
     captured USB Brother multifunction device

Windows applications --> Windows inbox IPP queue
                  --> loopback-only VirtualBox NAT forward
                  --> guest CUPS queue --> Linux driver --> USB printer
```

**Hard architectural rule:** UI does not import VirtualBox, printer setup scripts, or USB code. `printbridgectl` also talks to the same agent API. Provider implementations cannot import the UI crate. Rust domain/core crates contain no Tauri symbols.

### Service model

- `printbridge-agent.exe`: per-user background supervisor, started by a **Task Scheduler task at user logon**, irrespective of whether the UI launches. Document that logoff may terminate this mode; test behavior while session is locked.
- `printbridgectl.exe`: development/debug CLI and scriptable control client.
- `printbridge-desktop.exe`: Tauri UI/tray client; quitting it leaves the agent + VM running.
- Use a versioned **Windows named pipe** for command/status IPC with ACL restricted to the owning user SID; avoid public HTTP control endpoints. A polling API is sufficient initially, with optional event streaming after the model stabilizes.
- Only the selected VM is managed. Track its UUID and ownership marker, never operate by ambiguous display name alone.
- The agent reconciles desired/observed state after startup or failure and uses bounded backoff, not tight polling.

### Concrete module layout

```text
printbridge/
  Cargo.toml
  crates/
    domain/                   # data types, state, error taxonomy, traits
    core/                     # orchestrator, state machine, reconciliation
    provider-virtualbox/      # VBoxManage process adapter and parsing
    provider-cups/            # IPP health/jobs, Linux guest management
    provider-windows/         # Windows IPP printer/USB/system integration
    ipc/                      # versioned named-pipe protocol
    agent/                    # background executable
    cli/                      # printbridgectl executable
  apps/desktop/               # Tauri 2 + React/TypeScript UI
  guest/                      # pinned OS image config and CUPS provisioning
  scripts/                    # feasibility probes, setup/cleanup/runbooks
  tests/                      # contract, mock, Windows integration tests
  docs/
    feasibility.md
    adr/
    milestones/
    troubleshooting.md
    security.md
```

### Domain API expectations

Define small Rust traits behind provider boundaries, with async behavior only where it is needed. Candidate capabilities:

- `Hypervisor`: `detect`, `import`, `start_headless`, `stop_gracefully`, `state`, `delete_owned_vm`.
- `UsbAccess`: `list_devices`, `capture_selected`, `release_selected`, `attachment_status`; persist VID:PID and serial when available, not mutable USB bus address alone.
- `GuestPrinting`: `probe_ipp`, `list_queues`, `queue_status`, `submit_test_page`, `jobs`, `diagnostics`.
- `WindowsPrinting`: `detect_ipp_support`, `register_owned_queue`, `list_owned_queues`, `remove_owned_queue`, `verify_driver`.
- `Startup`: `enable_login_start`, `disable_login_start`, `verify_registration`.

Avoid building a general plugin runtime. Interfaces exist to isolate vendor APIs and make fakes possible. Keep subprocess invocation centralized with argument-vector construction, no string-formatted shell commands, bounded timeouts, and captured stderr.

### Status model

Store **component states separately** (hypervisor, guest boot, USB, CUPS, Windows queue); derive an overall UI status. Example: `NotConfigured`, `Provisioning`, `Starting`, `WaitingForUsb`, `Connecting`, `Ready`, `Degraded`, `Error`, `Stopping`. Distinguish an IPP job being **accepted**, **completed by CUPS**, and **physically printed**; software cannot infer the last without a hardware test or reliable device feedback.

### Networking and security

- Default: guest NIC in VirtualBox NAT mode, loopback-only host port forward `127.0.0.1:<chosen-port>` → guest `631`. Reserve a stable available port, persist it, and verify the IPP URI Windows actually installs. Do **not** assume `localhost` succeeds with Windows' print-stack validation or CUPS's advertised `printer-uri-supported` attributes.
- If loopback-forwarded IPP fails for a protocol/URI reason, test a private host-only adapter with stable guest IP as the documented fallback. Keep the alternative behind `PrinterEndpoint`/network configuration rather than hardcoding it everywhere.
- Do not enable CUPS `--remote-any` on arbitrary interfaces, expose CUPS's admin UI on the LAN, or open inbound internet firewall rules.
- Optional guest SSH management must bind only to Windows loopback, use per-install keys with restrictive ACLs, and never permit remote password login. Avoid retaining provisioning secrets.
- Never allow a user-supplied printer name, URL, or USB descriptor to become an unescaped shell expression. Verify downloads by trusted source/checksum and minimize guest packages.

## 3. Critical risks / engineering decisions

| Risk | Consequence | Required experiment or mitigation |
|---|---|---|
| Windows IPP driver rejects legacy CUPS queue | Product concept fails despite working USB | M0: register IPP queue and physically print PDF/text; record IPP attributes, accepted formats, driver selection |
| Windows protected printing policy incompatible | Printer registration or output blocked | M0: inspect current setting; document results; never silently disable system policy |
| CUPS advertises internal guest URI | Windows cannot locate queue behind forwarded port | Test loopback `127.0.0.1` and advertised URI, then host-only network fallback |
| Vendor driver requires i386/glibc/old filters | Tiny Linux distro cannot print | Identify package architecture/dependencies; pin suitable guest distro; keep driver installation modular |
| Composite USB device switches host/guest ownership | Printing/scanning becomes unavailable on Windows while captured | Ask user before capture; identify whole device, persist safe filter, release on uninstall |
| Port is already occupied | Queue becomes offline | Detect, allocate/reuse stable port, repair Windows queue if endpoint changes |
| Host sleep, reboot, USB unplug | Stalled jobs/offline queue | Reconciler, retries, bounded startup, idempotent reattach, integration tests |
| VirtualBox or guest image redistribution rights | Cannot deliver one-click package | Depend on supported installed hypervisor initially; review guest/vendor driver/extension-pack licenses before embedding |
| Task Scheduler launch context mismatch | VM starts under wrong user, USB capture fails | Run agent/VirtualBox under same per-user account; verify locked/logged-in behavior |
| Security of local CUPS/named pipe | Unauthorized print/control activity | Loopback-only transport, named-pipe ACLs, least privilege, redacted diagnostics |

**Alternate backend research (ADR, not implementation):** WSL2 + `usbipd-win` is worth evaluating only after VirtualBox MVP. It may reduce appliance management complexity in some environments, but the USB attachment is not intrinsically persistent across disconnects/reboots and requires lifecycle handling. Do not run two hypervisor backends in parallel before one succeeds.

## 4. Milestones and hard acceptance gates

### M0 — Proof of actual Windows → Linux printing (HARD GO/NO-GO)

**Implement:**

- Create `scripts/feasibility/` with documented PowerShell/Linux scripts to capture versions, printer USB IDs, Linux queue name, CUPS configuration, relevant log snippets, and Windows printer driver metadata.
- Use the **existing working Linux machine** first, with the Brother USB printer physically connected there; configure the working CUPS queue to share over IPP on a trusted local network. This deliberately removes the VM from the experiment.
- From Windows, attempt manual addition via the IPP URL and via `Add-Printer -Name "Brother via PrintBridge POC" -IppURL <validated-url>` where available. Confirm installed Windows driver is Microsoft's inbox IPP driver, not a Brother driver. Test direct IPP printing from Word/Notepad/PDF viewer.
- Print a known one-page text document, a one-page PDF with images, and (if supported) a page exercising color/duplex. Record whether media options and job completion work.
- Capture CUPS IPP attributes (`Get-Printer-Attributes` via suitable tooling), Windows job error details, CUPS `error_log` where needed, and physical print results. Test Windows Protected Print Mode only without changing policies unexpectedly.
- Create `docs/feasibility.md` with explicit `PASS`, `FAIL`, or `BLOCKED` plus machine-specific evidence. Ensure scripts are safe and reversible.

**PASS:** At least the required text and PDF jobs are actually printed on paper from a normal Windows application using the Microsoft IPP Class Driver, with no Brother Windows driver.

**FAIL:** Client cannot register or physically print after systematic diagnosis; do **not** continue to GUI/app implementation. Investigate standard IPP Everywhere/Mopria exposure or other supported existing bridges as a separate, time-boxed research decision. Do not assume changing the hypervisor will resolve an IPP protocol incompatibility.

**Hardware gate:** Mandatory owner confirmation with photo/log/explicit result; agent-generated mocks do not count.

### M1 — Manual VM/USB/CUPS end-to-end spike (HARD GO/NO-GO)

**Implement:**

- Manually create a lightweight x86_64 Debian-family VM in a supported VirtualBox release, headless where possible. Start with **1 vCPU and ~768 MiB RAM**, tune after measuring; no graphical Linux desktop.
- Verify USB capture of the selected Brother device using VirtualBox host USB enumeration/device filter. Record whether unplug/replug is needed; printer becomes inaccessible to host Windows while captured.
- Install CUPS and the exact known-working Linux driver and dependencies; test guest printing before testing Windows networking.
- Start from NAT with localhost port forwarding (example host `127.0.0.1:8631` → guest `631`). If Windows IPP negotiation fails, test host-only networking separately. Verify actual IPP URI, queue name, advertised supported document formats, and physical output.
- Reboot guest, reboot host, disconnect/reconnect USB; record successes/failures and dependencies.

**PASS:** Normal Windows application can physically print through the headless VM after a clean boot, and after a USB reconnection (manual remediation may be documented for this spike).

**Hardware gate:** Mandatory physical tests; do not start infrastructure automation if failed.

### M2 — Rust workspace, contracts, CLI, fakes

**Implement:**

- Initialize Cargo workspace and crate boundaries shown above. Write ADR-001 (Rust/Tauri vs Go/Wails, including measured/controller-vs-VM overhead rationale) and ADR-002 (hypervisor/provider boundaries).
- Define error types (`MissingDependency`, `PermissionDenied`, `UsbBusy`, `PrinterMissing`, `GuestUnhealthy`, `IppNegotiationFailed`, `PortConflict`, `UnsupportedDriver`, `Timeout`, `Internal`) and typed status objects.
- Implement command-line `printbridgectl status`, `doctor`, `help` using a **fake in-memory provider**. Add structured tracing with safe defaults and redaction.
- Implement state-machine tests, retry/backoff tests using fake clock where needed, and interface contract tests. Set up formatting/lint/CI (`cargo fmt`, `clippy`, tests, frontend later).

**PASS:** All state transitions/error mapping can be exercised without hardware; no Tauri, Windows API, or VirtualBox access leaks into the domain crates.

### M3 — Real VirtualBox provider and USB selection

**Implement:**

- Discover installation/version of VBoxManage; reject unsupported/incompatible versions with actionable messages.
- Import/register/start/stop **only** the VM owned by PrintBridge; safely query actual state. Use `startvm <UUID> --type headless`.
- Discover USB devices via supported VirtualBox interface; select exact VID:PID plus serial when available; apply filters and verify attachment; handle serial-less duplicates interactively.
- Validate virtualization prerequisites, permission failures, device-busy errors, and USB detach/reconnect. Do not accidentally capture unrelated devices or remove a user's preexisting filters.
- Implement CLI: `doctor`, `vm status`, `vm start`, `vm stop`, `usb list`, `usb attach`, `usb release`.

**PASS:** Unit tests with mocked command results, plus Windows integration tests that create/use a disposable **owned** test VM; real USB test gated by owner. Idempotent repeated start/stop.

### M4 — Reproducible Linux appliance and guest management

**Implement:**

- Create a version-pinned, unattended minimal guest build in `guest/` using documented build scripts and manifests; OVA export/import or equivalent appliance package. Separate **base OS+CUPS** from **printer-specific driver installation**.
- Install/configure CUPS, printing tools, an intentionally named print queue, log rotation, health reporting, and least-privilege guest settings. No GUI environment.
- Provide driver workflows: (a) distro-provided/open driver, when functional; (b) owner-selected official Brother Linux package with architecture/dependency detection and hash/source tracking. Do not bundle restricted binaries before licensing review.
- Expose guest CUPS/IPP only through the chosen protected VM endpoint. Implement health check and diagnostics retrieval through IPP and optionally loopback-only SSH/guest-control mechanism.
- Scripted upgrades/repair must preserve selected driver configuration and avoid silently replacing a known-good image. Guest image build should be repeatable from documented inputs.

**PASS:** Fresh VM instance builds from a clean repository checkout, guest CUPS reports healthy, guest prints physically to the selected USB device, and re-running provisioning is safe.

### M5 — Windows IPP printer integration

**Implement:**

- Implement `WindowsPrinting` adapter around supported Windows PrintManagement/IPP integration. Detect printer already registered, driver actually selected, queue name/path, spooler state and `-IppURL` support on installed build.
- Register an **owned** Windows queue to the correct stable guest endpoint. Implement `printbridgectl printer install`, `status`, `test-page`, `remove` with safe idempotence.
- Do not remove/change unrelated printer queues or default printer. Do not silently downgrade to a Brother Windows driver. Support guided manual fallback if IPP registration requires UI on a specific Windows build.
- Distinguish spooler submit from actual CUPS processing; log correlation ID where available.

**PASS:** A newly installed Windows queue prints real text/PDF from standard applications, displays correct driver, survives restart, and can be removed independently of the physical device or other printers.

### M6 — Headless supervisor, IPC, recovery

**Implement:**

- Implement the standalone `printbridge-agent` process with versioned local named-pipe IPC, per-user ACL, single-instance enforcement, bounded state reconciler, structured logging, and observable events.
- Provide `GetStatus`, `DiscoverDevices`, `BeginSetup`, `Start`, `Stop`, `Restart`, `TestPrint`, `GetDiagnostics` and `Repair` commands with explicit error/status payloads. Never permit arbitrary command execution through IPC.
- Enable per-user login startup with Task Scheduler; agent restarts/reconciles VM+CUPS+USB+Windows queue while UI remains closed. Safely handle resume/sleep, USB unplug/replug, CUPS restart, host printer spooler restart and port conflict.
- Ensure processes and jobs are not duplicated by two agent/UI starts. Persist owned resource IDs and desired state atomically.

**PASS:** Printing works with Tauri never launched; tests cover UI close, locked session, logon, recoverable failure, and unplug/replug. Report logoff behavior explicitly.

### M7 — Modern Tauri 2 desktop and system tray

**Implement:**

- Build a polished Windows-oriented Tauri 2 + React/TypeScript UI. Light/dark mode, keyboard accessibility, loading/error/empty states, readable typography, consistent spacing, unobtrusive animations, high-DPI behavior.
- Build screens: (1) setup wizard with prerequisites + USB confirmation, (2) dashboard with printer/VM/USB/CUPS/Windows queue status, (3) optional recent jobs and print test, (4) diagnostics/log export and actionable repair, (5) settings/startup/preferences/about.
- Add tray icon, `Open`, `Test page`, `Restart bridge`, `View diagnostics`, `Exit UI`; clearly differentiate exit UI from stop printing engine.
- All UI behavior comes through IPC client; implement frontend using fake client first, then real agent integration. Never store root credentials/driver downloads in webview local storage.

**PASS:** Complete functional UI flows with real backend, user can configure, print, diagnose and recover without opening VirtualBox or SSH. UI process can exit during an active print without stopping it.

### M8 — Installer, startup, repair, uninstallation

**Implement:**

- Package Windows binaries/UI and an optional prebuilt guest appliance after verifying all applicable licenses. If VirtualBox is not installed, provide dependency/version checks and guided installer rather than silently redistributing it.
- Explicit privilege elevation only for operations that need it. Never run the persistent user-facing agent elevated. Ensure Windows queues, VM, startup task, logs and settings have tracked ownership and deterministic repair/uninstall steps.
- Support offline installation for components whose licenses permit bundling; otherwise disclose network requirements before setup. Show disk/memory estimates and USB ownership consent.
- Provide upgrades with persistent configuration migration; signed artifacts/release pipeline where feasible; clearly documented unsigned development build path.

**PASS:** Fresh Windows installation can be onboarded through the app and print a physical page; repair and uninstallation succeed without removing unrelated VirtualBox VMs/printers or user data. No residual startup task or owned Windows print queue after uninstall.

### M9 — Soak test, observability, release candidate

**Implement:**

- Windows integration test suite + a bounded manual hardware matrix. Baseline VM memory, agent RSS/CPU, cold startup, print latency, idle-disconnect recovery, and disk growth; compare against accepted targets.
- The M9 release gate requires: 20 sequential text/PDF jobs; a long PDF; device unplug/reconnect while idle; VM crash; Windows spooler restart; CUPS restart; port conflict; second PrintBridge instance; low-disk guard; and cold start. These checks exercise the release-candidate print path and recovery behavior without repeatedly consuming paper for every environmental stress case.
- Keep USB-during-print, host-reboot, sleep/resume, and no-paper scripts as optional, non-gating stress checks. Do not require M9 repeats of normal-app text/PDF, uninstall/reinstall, or UI-closed printing while the applicable M0/M5, M8, and M6 physical gates remain valid and M9 has not changed product binaries. Never report a deferred check as passed unless it was actually run.
- Clearly identify which outcomes cannot be reliably automatically detected (e.g., a physically printed page with no printer telemetry).
- Write end-user install/usage/troubleshooting guide, developer build/test guide, security and licensing notes, known limitations, and release checklist.

**PASS:** The bounded physical end-to-end regression gate passes with evidence; prior applicable physical milestone gates remain valid; deferred stress checks are disclosed rather than claimed; no hidden background crashes/leaks or data loss appears in the required workload; status is truthful; polished UI and documented installer are usable by someone who has never seen VirtualBox.

## 5. Proposed performance targets (measure, do not assume)

- Start from 1 vCPU, **~768 MiB RAM** guest allocation; experiment with 512 MiB once printing is stable. Do not under-provision below what the actual driver/CUPS needs.
- Idle background Rust agent: aim **<50 MiB resident memory** and negligible steady-state CPU on reference Windows machine; measure actual process tree. This is a goal, not a prerequisite to functionality.
- Desktop UI: may be closed permanently; no impact on print availability.
- Guest VM dominates total footprint: track allocated VM RAM, total VirtualBox process RSS, and persistent image disk footprint. Set measured budget after M1 rather than fabricating benchmarks.
- Reasonable cold-start/recovery times are optimization targets; correctness, resilience and clean recovery win over premature optimization.

## 6. Test strategy and CI boundaries

**Unit tests:** domain/state/retry policy, parser against saved known VBoxManage outputs, IPC validation, fake-provider interactions, endpoint/URI handling, untrusted USB names/escaping.

**Contract tests:** each provider against a common expected behavior suite (fake implementation always; real provider when tool available).

**Software-only Windows integration:** managed test VM; print-to-file or dummy CUPS queue may validate registration and submission, but **cannot** count as full product feasibility.

**Physical hardware acceptance:** requires owner on real Windows 11 + real selected Brother USB device. Preserve exact commands and timestamped results under `docs/milestones/` (remove sensitive details before committing).

**Required honest labels:** `PASS: PHYSICAL`, `PASS: SOFTWARE ONLY`, `FAIL`, `BLOCKED: REQUIRES HARDWARE`, `NOT TESTED`.

## 7. Acceptance matrix and release definition

| Scenario | M0 | M1 | Release |
|---|---:|---:|---:|
| Linux prints through USB | verified baseline | yes | yes |
| Windows prints text through Linux with inbox IPP | physically yes | physically yes | automated setup + physically yes |
| Windows prints PDF/image | physically yes | physically yes | physically yes |
| USB device captured and released safely | n/a | manual | automatic/repairable |
| VM/headless app runs without desktop UI | n/a | manually | yes |
| Reconnect after unplug | n/a | documented spike | automatic or actionable recovery |
| Windows login autostart | n/a | n/a | yes |
| GUI setup/status/diagnostics | n/a | n/a | yes |
| Clean uninstall without collateral deletion | n/a | n/a | yes |
| Resource budget and soak test | n/a | baseline | measured/passed |

**Definition of done:** A nondeveloper on the supported Windows host can install/configure PrintBridge, close its window, select `Brother via PrintBridge` in Notepad or PDF reader and reliably print a real page. The project reports status honestly, recovers from expected disconnects, starts on login, and uninstalls cleanly. Claims about the printer model and compatibility are limited to actually tested hardware.

## 8. Human-in-the-loop reporting format

For each milestone, the Codex agent should produce:

```text
Milestone: Mxx
Result: PASS: PHYSICAL | PASS: SOFTWARE ONLY | FAIL | BLOCKED: REQUIRES HARDWARE
Changed files:
Test commands and outcomes:
Actual hardware observations:
Known failures and security/licensing notes:
How to reproduce:
Next milestone / next owner action:
```

At M0/M1, do not advance based on green CI alone. Request the exact missing human test result and wait for it to be supplied in a later interaction, without claiming asynchronous work.

## 9. Source references for implementation verification

Recheck current documentation against the versions installed at implementation time:

- OpenPrinting CUPS printer sharing: https://openprinting.github.io/cups/doc/sharing.html
- Microsoft `Add-Printer` and `-IppURL`: https://learn.microsoft.com/en-us/powershell/module/printmanagement/add-printer
- Microsoft IPP Class Driver: https://learn.microsoft.com/en-us/universal-print/fundamentals/universal-print-connector-with-ipp
- Microsoft Windows Protected Print Mode: https://learn.microsoft.com/en-us/windows/modern-print/windows-protected-print-mode/windows-protected-print-mode
- Oracle VirtualBox USB capture: https://docs.oracle.com/en/virtualization/virtualbox/7.1/user/BasicConcepts.html
- Oracle VirtualBox networking: https://docs.oracle.com/en/virtualization/virtualbox/7.1/user/networkingdetails.html
- Oracle VBoxManage CLI: https://docs.oracle.com/en/virtualization/virtualbox/7.1/user/vboxmanage.html
- Tauri v2 architecture: https://v2.tauri.app/concept/architecture/
- WSL alternative USB forwarding for later ADR: https://github.com/dorssel/usbipd-win

---

### Start-here prompt for Codex

> Implement PrintBridge following this specification. Begin with M0 only: inspect the repository and environment, create reproducible feasibility scripts and `docs/feasibility.md`, run all safe software-only checks available, and write the exact owner-executed Windows/Linux hardware acceptance steps. Do not build the full application or UI before the physical Windows → Linux → USB printer test passes. For every subsequent milestone, implement concrete functionality, add tests, document results, and respect hard hardware gates. Be explicit when a claim could not be verified in your execution environment.
