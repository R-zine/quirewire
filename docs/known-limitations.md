# Known limitations

- Supported scope is one Windows 11 x64 computer, one interactive user, one
  tested Brother DCP-L2600D (`04f9:0567`), and printing only.
- The user must remain logged in. The per-user task stops at logoff; pre-login
  printing is not promised.
- VirtualBox 7.1+ major-7, WebView2, and an owner-local configured appliance are
  prerequisites. The installer does not silently download them.
- The Brother Linux driver/configured appliance cannot currently be
  redistributed, so fresh appliance construction is not one click.
- USB passthrough captures the whole multifunction device. Native Windows
  scanning/faxing/printing cannot use it concurrently.
- Status distinguishes Windows acceptance and observable CUPS state from paper.
  Physical output, jams, toner, and no-paper may not be reported reliably by
  this legacy driver/device.
- The supported endpoint is a fixed loopback NAT forward. LAN sharing and remote
  administration are non-goals. A port collision blocks startup until repaired.
- One Windows PDF viewer (Chrome on the reference host) has no unattended
  `printto` verb. M9 automation therefore uses a signature-verified portable
  SumatraPDF as an owner-local test tool; it is not a product dependency or
  bundled component. Normal Chrome dialogs were physically proven in earlier
  milestones but were not repeated in the bounded M9 gate.
- Actual disk exhaustion is not induced because it risks user/VM data. M9 tests
  a simulated threshold that must refuse before submission.
- USB-during-print, host-reboot, sleep/resume, no-paper, uninstall/reinstall,
  UI-closed, and normal-app repeats are optional M9 stress checks. They remain
  unclaimed unless separately run; the bounded release gate does not cover
  every environmental fault combination.
- Performance numbers are reference-host observations, not universal guarantees.
- Current development installers are unsigned. A signed production artifact and
  public distribution pipeline remain blocked on a production certificate and
  final license review.
