# M3 physical USB acceptance checklist

This checklist is owner-gated because USB capture temporarily removes the
printer from Windows. It does not require a print job; M3 proves safe VirtualBox
lifecycle and USB ownership. M4 returns to physical guest printing.

## Preconditions

- The disposable test VM is M3-owned, has no unrelated USB filters, and uses a
  configuration whose UUID and marker match the live extra-data values.
- `printbridgectl doctor` reports supported VirtualBox and hardware
  virtualization.
- `printbridgectl usb list` shows the intended Brother as `04f9:0567`. Its serial
  value remains redacted.
- Any document currently printing from Windows has completed.

## Owner-executable gate

1. Explicitly consent to transferring `04f9:0567` from Windows to the configured
   disposable VM.
2. Run `printbridgectl --config <path> vm start` twice. Both calls must succeed;
   `vm status` must be `ready`.
3. Run `printbridgectl --config <path> usb attach` twice. Both calls must be
   safe/idempotent. If the configuration intentionally omits a serial and more
   than one identical serial-less device exists, review `usb list` and use
   `usb attach --index N`.
4. Confirm VirtualBox reports the exact selected device attached to the exact
   configured VM. Confirm no unrelated host USB device moved and no pre-existing
   filter was removed.
5. Run `usb release` (or the same `--index N`) twice. Confirm Windows can see and
   use the printer again.
6. Physically unplug and reconnect the Brother. Repeat `usb list`, `usb attach`,
   and `usb release`; confirm recovery and Windows return.
7. Run `vm stop` twice. Both calls must succeed and `vm status` must be `stopped`.

Record command exits, the redacted VID:PID, VM state transitions, whether Windows
regained the printer, and the owner's explicit pass/fail statement. Never record
the USB serial in repository-tracked evidence.
