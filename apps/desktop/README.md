# QuireWire desktop

The M7 desktop is a Tauri 2 shell around a React/TypeScript client. Its Rust
side depends only on `quirewire-ipc`; it does not link the agent or any
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

Closing the window hides it in the notification area and keeps the desktop
heartbeat alive. `Exit QuireWire` requests graceful agent/VM shutdown and
stops LAN sharing. The agent is launched hidden on demand; no login task is
created.

