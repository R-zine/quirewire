# Known limitations

- Supported scope is one Windows 11 x64 computer, one interactive user, one
  tested Brother DCP-L2600D (`04f9:0567`), driverless IPP printing, and
  eSCL/AirScan scanning.
- The user must open QuireWire when printing is needed. There is deliberately
  no login task; explicit Exit, logoff, or loss of the desktop heartbeat stops
  the agent, VM, and sharing.
- VirtualBox 7.1+ major-7, WebView2, and an owner-local configured appliance are
  prerequisites. The installer does not silently download them.
- The Brother Linux driver/configured appliance cannot currently be
  redistributed, so fresh appliance construction is not one click.
- USB passthrough captures the whole multifunction device. Native Brother
  Windows software and faxing cannot use it concurrently. QuireWire
  serializes guest printing/scanning; an active scan may make another scan or
  print wait.
- LAN scanning is unauthenticated trusted-LAN eSCL. It requires a separate
  exact-port approval and must not be enabled on an untrusted or client-isolated
  LAN. The tested Android Mopria Scan client required its documented manual
  IPv4 add flow even though the host `_uscan._tcp` diagnostic resolved the live
  advertisement; QuireWire shows that approved address as a fallback. OCR,
  scan-to-cloud, panel scan-button workflows, and proprietary vendor
  scan applications are outside v1.
- Status distinguishes Windows acceptance and observable CUPS state from paper.
  Physical output, jams, toner, and no-paper may not be reported reliably by
  this legacy driver/device.
- Windows uses a fixed loopback NAT forward. LAN clients use a second temporary
  forward and DNS-SD advertisement only on one explicitly approved active
  default-route interface and directly attached IPv4 subnet. The exact firewall
  rules include Private and Public profiles only because Windows labels the
  reference `Ethernet 3` adapter Public; interface, remote CIDR, program,
  protocol, and port remain fixed. Routed, VPN, internet, other-adapter and
  remote-administration use is unsupported. A port collision blocks startup
  until repaired.
- M4 appliances created before M10 need the documented queue-only CUPS policy
  migration or a rebuild from the current guest sources. The reference VM was
  migrated through a validated offline clone; its original VDI is preserved for
  rollback.
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
