# AirSane compatibility patch

`airsane-brscan5-session.patch` modifies AirSane commit
`08ff4d798d718e2e50ef805404ddef82f6d03cc1` so the startup-only SANE session is
released before Brother `brscan5` opens the device for acquisition. The change
was made for QuireWire in 2026 and corresponds to upstream AirSane issue #132.

AirSane and this derivative patch are distributed under `GPL-3.0-only`, not
under QuireWire's MIT/Apache-2.0 dual license. The full GPLv3 text is at
`../../LICENSES/GPL-3.0-only.txt`. The pinned upstream source, archive hash,
patch hash, and issue URL are recorded in
`../manifests/scanner-dcpl2600d.env`.

QuireWire does not bundle an AirSane binary. If a release ever distributes a
guest image or other binary containing the patched AirSane build, that release
must provide the complete corresponding patched AirSane source and a clear
source offer alongside the binary. The patch alone is not a substitute for
complete corresponding source in a binary distribution.
