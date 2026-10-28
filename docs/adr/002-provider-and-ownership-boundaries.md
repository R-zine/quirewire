# ADR-002: Provider and ownership boundaries

- Status: Accepted
- Date: 2026-10-28
- Milestone: M2

## Context

PrintBridge coordinates five external boundaries with different failure and
privilege models: VirtualBox, whole-device USB capture, guest CUPS/IPP, Windows
printing, and per-user startup. Direct calls from UI or orchestration code would
make safety rules difficult to test and would couple the product to command-line
output and platform APIs.

M1 also exposed a concrete identity hazard: a Windows IPP/WSD port cached the M0
CUPS printer UUID and could not safely be reused for the M1 server behind the same
forwarded address. Resource names and mutable bus addresses are not sufficient
ownership identifiers.

## Decision

Define the external contracts in the framework-free `domain` crate:

- `Hypervisor` owns detect/import/headless start/graceful stop/state and deletion
  of a typed `OwnedVm` only;
- `UsbAccess` identifies the selected whole device by VID:PID plus serial when
  present, and separates list/capture/release/attachment state;
- `GuestPrinting` owns IPP health, queue state, test submission, jobs, and redacted
  diagnostics;
- `WindowsPrinting` owns inbox-IPP detection and marker-owned queue lifecycle;
- `Startup` owns the per-user login registration boundary.

Provider implementation crates may depend on `domain` and shared process helpers,
but never on the desktop. Domain/core/IPC/agent crates contain no Tauri symbols.
The CLI and future desktop are clients of the same versioned agent protocol.

M2 uses one explicitly labeled in-memory fake implementing all contracts. Real
implementations arrive only in their milestones:

- VirtualBox in M3;
- guest/CUPS in M4;
- Windows printing in M5;
- startup and named-pipe transport in M6.

## Safety and process rules

- Persist immutable provider identities: owned VM UUID plus marker, USB VID:PID
  plus serial when available, and Windows queue ownership metadata.
- Deletion/release methods accept typed owned resources and must revalidate live
  identity before mutation. They must never enumerate by display name and then
  delete all matches.
- Centralize subprocess execution in the concrete provider layer. Construct an
  argument vector, use bounded timeouts, and capture stdout/stderr separately; no
  string-formatted shell expressions.
- Provider errors map to the stable domain taxonomy with actionable remediation.
- Diagnostics classify sensitive fields explicitly. USB serials, local paths,
  user names, and raw command output are not safe trace fields by default.
- Keep methods synchronous until real I/O demonstrates a need for async behavior;
  do not introduce an async runtime into pure domain code.

## Consequences

- State-machine, retry, CLI, and error behavior are testable without Windows,
  VirtualBox, CUPS, or hardware.
- Provider crates begin as compile-time boundaries only; they do not pretend to
  implement later milestones.
- Some cross-provider reconciliation remains in `core`, where it can be tested
  using the common fake and fake clock.
- A second backend can implement the same contracts later, but this decision does
  not create a general plugin runtime.
- Interface changes require contract-test updates and protocol compatibility
  review rather than ad hoc UI changes.
