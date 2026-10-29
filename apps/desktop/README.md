# PrintBridge desktop

The M7 desktop is a Tauri 2 shell around a React/TypeScript client. Its Rust
side depends only on `printbridge-ipc`; it does not link the agent or any
VirtualBox, CUPS, USB, or Windows printer provider.

## Development

```powershell
npm ci
npm test
npm run build
cargo tauri dev
```

Run the UI without Tauri using `npm run dev:fake`. That explicit mode uses the
in-memory fake client. A Tauri window always uses the owner-only named pipe.

Closing the window hides it in the notification area. `Exit UI` terminates only
the desktop process; the independently scheduled `printbridge-agent.exe` keeps
the printing engine running.

