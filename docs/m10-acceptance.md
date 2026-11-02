# M10 physical acceptance — on-demand trusted-LAN sharing

This gate uses the accepted Brother DCP-L2600D and one phone or computer on the
same trusted local network. It requires one small sheet, not a stress run.

## Preconditions

- [ ] Record the explicit LAN approval as interface `Ethernet 3` and subnet
  `192.168.100.0/24`, then install/repair the candidate and approve only its
  scoped firewall UAC prompt. Keep the Windows category Public; the rule must
  not apply to any other interface or remote subnet.
- [ ] Confirm Windows has no `\QuireWire\Agent` login task.
- [ ] Connect the second device to the same non-isolated LAN/Wi-Fi. Guest Wi-Fi,
  VPNs and routed subnets are outside the supported boundary.
- [ ] Power on/connect the accepted USB printer.

## One-page gate

1. Ensure QuireWire is fully exited. Confirm no `quirewire-agent.exe` or
   owned `VBoxHeadless.exe` remains and the phone cannot use the printer.
2. Open QuireWire. Wait for **Local network: Ready**. Confirm it shows
   `Ethernet 3`, category `Public`, an address within `192.168.100.0/24`, and the
   IPP endpoint; do not record SSID or other sensitive data.
3. On the second device, choose the discovered **Brother via QuireWire**
   printer. Print one short text/PDF page.
4. Owner confirms: the correct page physically printed once and is legible.
5. Close the window with X. Confirm it hides to tray and the printer remains
   discoverable; no second sheet is needed.
6. From the tray/settings choose **Exit QuireWire (stop sharing)**. Allow up
   to 90 seconds for graceful VM shutdown, then confirm:
   - no QuireWire agent remains;
   - the exact owned VM is powered off;
   - `quirewire-m10-lan-ipp` is absent from `VBoxManage showvminfo`;
   - the phone can no longer use the advertised printer.

## Scope check (no paper)

Confirm the two owned firewall rules are limited to `Ethernet 3`, remote address
`192.168.100.0/24`, the exact executable, protocol and port. The Public category
is an explicit exception for this adapter/subnet only; no other Public adapter,
subnet, port, or executable is approved. Missing or mismatched approval must
leave LAN sharing unavailable.

Record results in `docs/milestones/M10.md` using only `PASS`, `FAIL`, or `NOT
TESTED`. A green software suite does not substitute for step 4.
