# Release checklist

## Source and quality

- [ ] M0–M9 milestone reports exist and every hard gate has honest evidence.
- [ ] Worktree is clean and the release commit is reviewed.
- [ ] `cargo fmt`, Clippy with warnings denied, all Rust tests, frontend tests/
  build, milestone software suites, and disposable VirtualBox integration pass.
- [ ] M9 metrics meet or explicitly explain agent RSS/CPU, 768 MiB guest,
  startup/recovery, latency, and disk-growth targets.
- [ ] All 10 required M9 scenarios pass; every required physical row has owner
  confirmation. Deferred stress checks are disclosed and not claimed as passed.

## Safety and privacy

- [ ] Installer/repair/uninstall operate only on exact owned resources and the
  clean-uninstall baseline comparison passes.
- [ ] USB serial, keys, vendor packages, configured OVA, logs, and machine
  evidence are absent from Git and release assets.
- [ ] Diagnostics are reviewed for redaction; named-pipe ACL and limited task are
  verified on the candidate.
- [ ] CUPS/SSH remain loopback-only and no inbound firewall/LAN exposure exists.
- [ ] Windows default/unrelated printers and unrelated VMs survive testing.

## Packaging, licensing, and signing

- [ ] `docs/licensing.md` is re-reviewed against every bundled component.
- [ ] VirtualBox, Extension Pack, Brother packages, Debian ISO, configured OVA,
  SSH keys, and USB identity are not accidentally bundled.
- [ ] Production binaries and installer have a valid Authenticode signature and
  trusted timestamp; unsigned artifacts are labeled development-only.
- [ ] Installer SHA-256, size, version, commit, and build log are recorded.
- [ ] A fresh nondeveloper Windows account follows `docs/install.md` and
  `docs/usage.md` without repository-only assumptions.

## Final physical candidate

- [ ] Prior normal-app text/PDF milestone evidence remains applicable; the M9
  20-job mixed soak and long PDF are complete and legible.
- [ ] Required USB-idle, VM-crash, Spooler, guest/CUPS, port-conflict, singleton,
  low-disk, and cold-start checks pass.
- [ ] Deferred stress checks (USB during print, reboot, sleep/resume, no-paper,
  uninstall/reinstall repeat, UI-closed repeat, and normal-app repeat) are listed
  as non-gating and are not represented as tested when no M9 evidence exists.
- [ ] Final status is Ready with one agent; no hidden crashes, duplicate pages,
  residual owned resources, unexplained disk growth, or unrelated data loss.
- [ ] Known limitations and rollback/uninstall steps are communicated.

Do not publish while any required item is unchecked. Deferred stress checks are
not required items. The current unsigned-development artifact is not a public
release candidate.
