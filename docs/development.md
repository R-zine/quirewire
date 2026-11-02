# Developer build and test guide

## Toolchain

- Windows 11 x64, PowerShell 5.1+, Git, and Rust from `rust-toolchain.toml`.
- Node.js 24.15+ and npm for the React/Tauri desktop.
- Tauri 2 Windows prerequisites and an installed WebView2 runtime.
- VirtualBox 7.1+ major-7 only for real-provider and hardware tests.

Build/test from the repository root:

```powershell
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --all-features --offline -- -D warnings
cargo test --workspace --all-features --offline

Push-Location .\apps\desktop
npm ci
npm test
npm run build
Pop-Location

.\tests\public\Invoke-PublicSourceTests.ps1
$software = Get-ChildItem .\tests -Filter 'Invoke-M*SoftwareTests.ps1' -Recurse
foreach ($test in $software) {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File $test.FullName
}
```

## Pre-commit quality gate

Enable the repository-owned hook once per checkout:

```powershell
.\scripts\quality\Install-GitHooks.ps1
```

The hook runs `git diff --cached --check`, locked/offline Cargo metadata,
`cargo fmt`, Clippy with warnings denied, the complete Rust and frontend test
suites, the frontend production build, the public-source/license audit, and
every milestone software suite. It never invokes M3's disposable VirtualBox
integration or any USB, printer, scanner, LAN, paper-output, or other physical
acceptance test.

Frontend dependencies must already be installed with `npm ci`; the hook does
not modify dependencies or access the network. The same gate can be run without
committing:

```powershell
.\scripts\quality\Invoke-PreCommit.ps1
```

The disposable real-VirtualBox integration requires the explicit accepted source
UUID and deletes only its newly marked clone:

```powershell
.\tests\m3\Invoke-M3WindowsIntegration.ps1 -SourceVmUuid <uuid>
```

Build an explicitly unsigned development installer with:

```powershell
.\scripts\m8\windows\Build-M8Installer.ps1 -UnsignedDevelopmentBuild
```

Production signing requires a real certificate thumbprint and timestamp service;
never relabel an unsigned artifact as a release. The official Tauri guides cover
[Windows installers](https://v2.tauri.app/distribute/windows-installer/) and
[Windows signing](https://v2.tauri.app/distribute/sign/windows/).

## Architecture rules

- Domain/core/headless crates contain no Tauri dependency.
- Desktop and CLI are clients of the same versioned owner-only named pipe.
- Providers own OS/VirtualBox/CUPS integration and use argument vectors with
  bounded subprocess timeouts.
- Real hardware output is never inferred from a mock, spooler job, or CUPS job.
- Generated evidence stays ignored under `artifacts/`; inspect it for sensitive
  local data before sharing.

Run M9 according to `scripts/m9/README.md`. Physical scenarios are deliberately
outside CI and require explicit owner confirmation.

The mixed workload uses Notepad's registered `/pt` command for text and a
signature-verified, owner-local portable SumatraPDF for explicit-queue PDF
printing. SumatraPDF is never bundled. The initial Win32 RAW experiment was
rejected because Windows marked jobs complete without forwarding them to CUPS;
those jobs are not acceptance evidence.
