# Release checklist

This checklist distinguishes publishing source from distributing compiled
Windows or guest artifacts. Do not call an unchecked binary a production
release.

## Source publication

- [ ] The release commit is reviewed, the worktree is clean and no generated
  evidence is staged.
- [ ] `LICENSE`, `LICENSE-MIT`, `LICENSE-APACHE`, `NOTICE`, `REUSE.toml`,
  `THIRD_PARTY_NOTICES.md` and `LICENSES/GPL-3.0-only.txt` are present.
- [ ] Package metadata declares `MIT OR Apache-2.0`, and the AirSane patch is
  explicitly mapped to `GPL-3.0-only` with modification provenance.
- [ ] No VirtualBox installer, Extension Pack, Debian ISO, Brother package,
  configured OVA/VDI, private key, USB identity, machine log, scan or printed
  document is tracked.
- [ ] A current name/package/trademark search has been reviewed. Record that a
  preliminary search is not formal trademark clearance.
- [ ] `tests/public/Invoke-PublicSourceTests.ps1` passes.

## Source and quality

- [ ] M0-M11 milestone reports exist and every hard gate has honest evidence.
- [ ] `cargo fmt`, Clippy with warnings denied, all Rust tests, frontend tests
  and build, and every milestone software suite pass.
- [ ] The disposable VirtualBox integration passes against an explicitly
  accepted source UUID, without mutating the source VM.
- [ ] M9 measurements meet or explicitly explain the 768 MiB guest, agent
  RSS/CPU, startup/recovery, latency and disk-growth targets.
- [ ] All 10 required M9 scenarios pass and the bounded physical matrix is
  accurately reported. Deferred stress checks are disclosed and never
  represented as tested.

## Safety and privacy

- [ ] Installer, repair and uninstall operate only on exactly owned resources,
  and the clean-uninstall baseline comparison passes.
- [ ] Diagnostics are reviewed for redaction and contain no document payloads.
- [ ] The named-pipe ACL, desktop heartbeat and lack of automatic login startup
  are verified on the candidate.
- [ ] CUPS administration and SSH remain loopback-only.
- [ ] LAN rules are exact-program TCP IPP/UDP mDNS rules, limited to the
  approved interface/subnet; scanning has its own exact TCP eSCL rule.
- [ ] Windows default/unrelated printers, ports, drivers, firewall rules and
  unrelated VMs survive testing.

## Binary license, packaging and signing

- [ ] `docs/licensing.md` is re-reviewed against every bundled component.
- [ ] A complete license inventory is generated from the release lockfiles and
  all required dependency license/NOTICE material is packaged.
- [ ] MPL-2.0-covered dependency source is available and the installer tells
  recipients where to obtain it.
- [ ] If any guest image or patched AirSane binary is distributed, complete
  corresponding patched AirSane source and GPL notices accompany it.
- [ ] Brother packages remain owner-local unless a separate written review
  confirms that the exact packages and delivery method may be redistributed.
- [ ] VirtualBox, Extension Pack, Debian ISO, configured appliance, private
  keys and USB identity are absent from the Windows bundle.
- [ ] Production executables and installer have valid Authenticode signatures
  and trusted timestamps. Unsigned artifacts remain labeled development-only.
- [ ] Installer SHA-256, size, version, commit, dependency inventory and build
  log are recorded.
- [ ] A fresh nondeveloper Windows account can follow `docs/install.md` and
  `docs/usage.md` without repository-only assumptions.

## Final physical candidate

- [ ] Normal Windows text and PDF jobs print completely and legibly.
- [ ] One approved same-subnet phone/LAN print succeeds while QuireWire runs;
  explicit Exit then removes discovery, stops the agent/VM and releases USB.
- [ ] Local browser scanning, Windows Scan and one approved LAN scan client
  acquire a real page without document bytes entering QuireWire diagnostics.
- [ ] Firewall inspection proves the Public-category exception is limited to
  the approved interface, subnet, programs, protocols and ports.
- [ ] Required USB-idle, VM-crash, Spooler, guest/CUPS, port-conflict,
  singleton, low-disk and cold-start recovery checks pass.
- [ ] Final status is Ready with one agent and no hidden crashes, duplicate
  pages, residual owned resources, unexplained disk growth or unrelated data
  loss.
- [ ] Known limitations, ownership of the whole USB device, rollback and
  uninstall behavior are communicated.

Do not publish while any required item is unchecked. The current unsigned
development artifact is not a public production release.
