import { useCallback, useEffect, useMemo, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import type { PrintBridgeClient } from "./client";
import type {
  AgentStatus,
  ComponentState,
  DeviceSummary,
  Diagnostics,
  ScreenId,
  TestPrintResult,
  ThemePreference,
} from "./types";
import { ClientError } from "./types";

interface AppProps {
  client: PrintBridgeClient;
  pollIntervalMs?: number;
  tauriEvents?: boolean;
}

const screens: { id: ScreenId; label: string; hint: string; icon: string }[] = [
  { id: "dashboard", label: "Overview", hint: "Bridge health", icon: "⌂" },
  { id: "setup", label: "Setup", hint: "Printer & USB", icon: "◇" },
  { id: "activity", label: "Print test", hint: "Jobs & output", icon: "▤" },
  { id: "scan", label: "Scan", hint: "Documents & photos", icon: "S" },
  { id: "diagnostics", label: "Diagnostics", hint: "Repair & export", icon: "◫" },
  { id: "settings", label: "Settings", hint: "Startup & app", icon: "⚙" },
];

const componentLabels: Record<keyof AgentStatus["components"], string> = {
  hypervisor: "VirtualBox",
  guest: "Linux guest",
  usb: "USB printer",
  cups: "CUPS",
  windows_queue: "Windows queue",
  scanner: "eSCL scanner",
  lan: "Local network",
};

export function App({ client, pollIntervalMs = 5000, tauriEvents = true }: AppProps) {
  const [screen, setScreen] = useState<ScreenId>("dashboard");
  const [status, setStatus] = useState<AgentStatus | null>(null);
  const [diagnostics, setDiagnostics] = useState<Diagnostics | null>(null);
  const [devices, setDevices] = useState<DeviceSummary[] | null>(null);
  const [selectedDevice, setSelectedDevice] = useState<number | null>(null);
  const [usbConsent, setUsbConsent] = useState(false);
  const [printResult, setPrintResult] = useState<TestPrintResult | null>(null);
  const [theme, setTheme] = useState<ThemePreference>("system");
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<ClientError | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [exportPath, setExportPath] = useState<string | null>(null);
  const [closing, setClosing] = useState(false);

  const showError = useCallback((value: unknown) => {
    setError(value instanceof ClientError ? value : new ClientError({
      code: "desktop_action_failed",
      message: value instanceof Error ? value.message : String(value),
      action: "Try the action again. If it continues to fail, open Diagnostics.",
      retryable: true,
    }));
  }, []);

  const refreshStatus = useCallback(async (quiet = false) => {
    if (!quiet) setBusy("status");
    try {
      setStatus(await client.getStatus());
      setError(null);
    } catch (value) {
      showError(value);
    } finally {
      if (!quiet) setBusy(null);
    }
  }, [client, showError]);

  const refreshDiagnostics = useCallback(async () => {
    setBusy("diagnostics");
    try {
      const value = await client.getDiagnostics();
      setDiagnostics(value);
      setStatus(value.status);
      setError(null);
    } catch (value) {
      showError(value);
    } finally {
      setBusy(null);
    }
  }, [client, showError]);

  useEffect(() => {
    void refreshStatus();
    if (pollIntervalMs <= 0) return undefined;
    const timer = window.setInterval(() => void refreshStatus(true), pollIntervalMs);
    return () => window.clearInterval(timer);
  }, [pollIntervalMs, refreshStatus]);

  useEffect(() => {
    if (screen === "diagnostics" || screen === "activity") {
      void refreshDiagnostics();
    }
  }, [screen, refreshDiagnostics]);

  useEffect(() => {
    if (theme === "system") delete document.documentElement.dataset.theme;
    else document.documentElement.dataset.theme = theme;
  }, [theme]);

  useEffect(() => {
    if (!tauriEvents) return undefined;
    const cleanups: (() => void)[] = [];
    void listen<ScreenId>("printbridge:navigate", (event) => {
      if (screens.some((item) => item.id === event.payload)) setScreen(event.payload);
    }).then((unlisten) => cleanups.push(unlisten));
    void listen<{ ok: boolean; message: string }>("printbridge:operation", (event) => {
      if (event.payload.ok) {
        setNotice(event.payload.message);
        void refreshStatus(true);
      } else {
        showError(new Error(event.payload.message));
      }
    }).then((unlisten) => cleanups.push(unlisten));
    return () => cleanups.forEach((cleanup) => cleanup());
  }, [refreshStatus, showError, tauriEvents]);

  const runOperation = useCallback(async (
    name: string,
    action: () => Promise<{ detail: string }>,
  ) => {
    setBusy(name);
    setNotice(null);
    try {
      const result = await action();
      setNotice(result.detail);
      setError(null);
      await refreshStatus(true);
    } catch (value) {
      showError(value);
    } finally {
      setBusy(null);
    }
  }, [refreshStatus, showError]);

  const exitPrintBridge = useCallback(async () => {
    setClosing(true);
    setError(null);
    setNotice(null);
    try {
      await client.exitPrintBridge();
    } catch (value) {
      setClosing(false);
      showError(value);
    }
  }, [client, showError]);

  const overall = status?.overall ?? (error ? "unavailable" : "loading");

  if (closing) return <ClosingState />;

  return (
    <div className="app-shell">
      <aside className="sidebar" aria-label="Primary navigation">
        <div className="brand">
          <div className="brand-mark" aria-hidden="true"><span /></div>
          <div><strong>PrintBridge</strong><small>Local print and scan</small></div>
        </div>

        <nav>
          {screens.map((item) => (
            <button
              className={screen === item.id ? "nav-item active" : "nav-item"}
              key={item.id}
              onClick={() => setScreen(item.id)}
              aria-current={screen === item.id ? "page" : undefined}
            >
              <span className="nav-icon" aria-hidden="true">{item.icon}</span>
              <span><strong>{item.label}</strong><small>{item.hint}</small></span>
            </button>
          ))}
        </nav>

        <div className="sidebar-health">
          <span className={`status-dot state-${stateTone(overall)}`} aria-hidden="true" />
          <div><small>Bridge engine</small><strong>{pretty(overall)}</strong></div>
        </div>
      </aside>

      <div className="workspace">
        <header className="topbar">
          <div>
            <p className="eyebrow">{screens.find((item) => item.id === screen)?.hint}</p>
            <h1>{screens.find((item) => item.id === screen)?.label}</h1>
          </div>
          <div className="top-actions">
            <button className="icon-button" onClick={() => void refreshStatus()} aria-label="Refresh status" title="Refresh status">↻</button>
            <div className={`health-pill state-${stateTone(overall)}`}>
              <span className="status-dot" aria-hidden="true" />
              {pretty(overall)}
            </div>
          </div>
        </header>

        <main id="main-content" tabIndex={-1}>
          {error && <ErrorBanner error={error} onRetry={() => void refreshStatus()} onDiagnostics={() => setScreen("diagnostics")} />}
          {notice && <div className="notice" role="status"><span aria-hidden="true">✓</span>{notice}<button onClick={() => setNotice(null)} aria-label="Dismiss message">×</button></div>}

          {!status && !error ? <LoadingState /> : (
            <>
              {screen === "dashboard" && status && (
                <Dashboard
                  status={status}
                  busy={busy}
                  onRestart={() => void runOperation("restart", () => client.restart())}
                  onTest={() => setScreen("activity")}
                  onSetup={() => setScreen("setup")}
                />
              )}
              {screen === "setup" && status && (
                <Setup
                  status={status}
                  devices={devices}
                  selectedDevice={selectedDevice}
                  consent={usbConsent}
                  busy={busy}
                  onConsent={setUsbConsent}
                  onSelect={setSelectedDevice}
                  onDiscover={async () => {
                    setBusy("discover");
                    try {
                      const found = await client.discoverDevices();
                      setDevices(found);
                      setSelectedDevice(found.find((device) => device.selected)?.index ?? found[0]?.index ?? null);
                      setError(null);
                    } catch (value) { showError(value); }
                    finally { setBusy(null); }
                  }}
                  onConfigure={() => selectedDevice !== null && void runOperation(
                    "setup",
                    () => client.beginSetup(selectedDevice),
                  )}
                />
              )}
              {screen === "activity" && status && (
                <Activity
                  diagnostics={diagnostics}
                  printResult={printResult}
                  busy={busy}
                  onPrint={async () => {
                    setBusy("test-print");
                    setPrintResult(null);
                    try {
                      setPrintResult(await client.testPrint());
                      setError(null);
                    } catch (value) { showError(value); }
                    finally { setBusy(null); }
                  }}
                />
              )}
              {screen === "scan" && status && (
                <ScanScreen
                  status={status}
                  busy={busy}
                  onOpen={async () => {
                    setBusy("open-scanner");
                    try {
                      await client.openScanner();
                      setNotice("Scanner opened in your default browser.");
                      setError(null);
                    } catch (value) { showError(value); }
                    finally { setBusy(null); }
                  }}
                />
              )}
              {screen === "diagnostics" && status && (
                <DiagnosticsScreen
                  diagnostics={diagnostics}
                  busy={busy}
                  exportPath={exportPath}
                  onRefresh={() => void refreshDiagnostics()}
                  onRepair={() => void runOperation("repair", () => client.repair())}
                  onExport={async () => {
                    setBusy("export");
                    try {
                      setExportPath(await client.exportDiagnostics());
                      setError(null);
                    } catch (value) { showError(value); }
                    finally { setBusy(null); }
                  }}
                />
              )}
              {screen === "settings" && status && (
                <Settings
                  status={status}
                  theme={theme}
                  busy={busy}
                  onTheme={setTheme}
                  onStart={() => void runOperation("start", () => client.start())}
                  onStop={() => {
                    if (window.confirm("Stop the printing engine? Windows print jobs will wait until you start it again.")) {
                      void runOperation("stop", () => client.stop());
                    }
                  }}
                  onExit={() => void exitPrintBridge()}
                />
              )}
            </>
          )}
        </main>
        <div className="sr-only" role="status" aria-live="polite">{busy ? `${pretty(busy)} in progress` : notice ?? ""}</div>
      </div>
    </div>
  );
}

function ClosingState() {
  return <main className="closing-state" role="status" aria-live="assertive" aria-busy="true">
    <section className="closing-card">
      <span className="closing-spinner" aria-hidden="true" />
      <p className="eyebrow">Shutting down</p>
      <h1>Closing PrintBridge…</h1>
      <p>Stopping print and scan discovery, releasing the USB device, and shutting down the owned virtual machine.</p>
      <small>This window will close automatically when cleanup is complete.</small>
    </section>
  </main>;
}

function Dashboard({ status, busy, onRestart, onTest, onSetup }: {
  status: AgentStatus; busy: string | null; onRestart(): void; onTest(): void; onSetup(): void;
}) {
  const ready = status.overall === "ready";
  return <div className="screen-stack">
    <section className={`hero-card state-${stateTone(status.overall)}`}>
      <div className="hero-copy">
        <div className="hero-icon" aria-hidden="true">{ready ? "✓" : "!"}</div>
        <div><p className="eyebrow">Current status</p><h2>{ready ? "Ready to print" : pretty(status.overall)}</h2>
          <p>{ready ? "Brother via PrintBridge is available to Windows and trusted local-network devices." : overallGuidance(status.overall)}</p></div>
      </div>
      <div className="hero-actions">
        <button className="button primary" onClick={onTest}>Print a test page</button>
        <button className="button secondary" onClick={onRestart} disabled={busy !== null}>{busy === "restart" ? "Restarting…" : "Restart bridge"}</button>
      </div>
    </section>

    <div className="section-heading"><div><p className="eyebrow">Live path</p><h2>Bridge components</h2></div><button className="text-button" onClick={onSetup}>Review setup →</button></div>
    <section className="component-grid" aria-label="Bridge component health">
      {(Object.keys(componentLabels) as (keyof AgentStatus["components"])[]).map((key) => {
        const component = status.components[key];
        return <article className="component-card" key={key}>
          <div className="component-top"><span className={`component-symbol state-${stateTone(component.state)}`} aria-hidden="true">{componentIcon(key)}</span><StatusBadge state={component.state} /></div>
          <h3>{componentLabels[key]}</h3><p>{component.detail}</p>
        </article>;
      })}
    </section>
    <section className="info-strip"><span aria-hidden="true">●</span><div><strong>The window may be closed to the tray</strong><p>Printing remains available while the PrintBridge tray app is running. Exit PrintBridge to stop sharing and release VM memory.</p></div></section>
  </div>;
}

function Setup({ status, devices, selectedDevice, consent, busy, onConsent, onSelect, onDiscover, onConfigure }: {
  status: AgentStatus; devices: DeviceSummary[] | null; selectedDevice: number | null; consent: boolean; busy: string | null;
  onConsent(value: boolean): void; onSelect(index: number): void; onDiscover(): void; onConfigure(): void;
}) {
  const prerequisites = [
    ["VirtualBox", status.components.hypervisor],
    ["Linux appliance", status.components.guest],
    ["On-demand lifecycle", { state: status.startup.registered ? "error" : "ready", detail: status.startup.registered ? "A legacy login task must be removed by Repair" : "No login task; the app owns the agent and VM" }],
    ["Trusted local network", status.components.lan],
  ] as const;
  return <div className="screen-stack narrow">
    <section className="page-intro"><span className="step-number">1</span><div><p className="eyebrow">Prerequisites</p><h2>Check the printing foundation</h2><p>PrintBridge uses a private Linux guest and the Microsoft IPP Class Driver. It never installs a Brother Windows driver.</p></div></section>
    <section className="check-list">
      {prerequisites.map(([label, item]) => <div className="check-row" key={label}><span className={`check-icon state-${stateTone(item.state)}`} aria-hidden="true">{item.state === "ready" ? "✓" : "!"}</span><div><strong>{label}</strong><p>{item.detail}</p></div><StatusBadge state={item.state as ComponentState} /></div>)}
    </section>

    <section className="page-intro"><span className="step-number">2</span><div><p className="eyebrow">USB ownership</p><h2>Choose the printer/scanner</h2><p>The Linux guest captures the complete USB device for both printing and eSCL scanning. Brother Windows utilities cannot use it while captured.</p></div></section>
    <div className="card">
      <div className="card-toolbar"><div><strong>USB printers</strong><small>Serial values are never shown or exported.</small></div><button className="button secondary" onClick={onDiscover} disabled={busy !== null}>{busy === "discover" ? "Scanning…" : "Scan for devices"}</button></div>
      {devices === null ? <EmptyState title="Scan when the USB printer is connected" detail="Only the device you explicitly confirm can be selected." /> : devices.length === 0 ? <EmptyState title="No compatible USB device found" detail="Connect and power on the printer, then scan again." /> : (
        <div className="device-list" role="radiogroup" aria-label="USB printer selection">
          {devices.map((device) => <label className={selectedDevice === device.index ? "device-option selected" : "device-option"} key={device.index}>
            <input type="radio" name="device" checked={selectedDevice === device.index} onChange={() => onSelect(device.index)} />
            <span className="printer-glyph" aria-hidden="true">▰</span><span><strong>{device.display_name}</strong><small>USB {device.vendor_id}:{device.product_id} · {device.serial_present ? "stable identity available" : "no serial identity"}{device.selected ? " · currently selected" : ""}</small></span>
          </label>)}
        </div>
      )}
      <label className="consent-row"><input type="checkbox" checked={consent} onChange={(event) => onConsent(event.target.checked)} /><span><strong>I understand this transfers the whole USB device</strong><small>Windows cannot use this device directly while PrintBridge owns it.</small></span></label>
      <div className="card-footer"><span>Setup changes only PrintBridge-owned resources.</span><button className="button primary" disabled={!consent || selectedDevice === null || busy !== null} onClick={onConfigure}>{busy === "setup" ? "Configuring…" : "Confirm and configure"}</button></div>
    </div>
  </div>;
}

function ScanScreen({ status, busy, onOpen }: {
  status: AgentStatus; busy: string | null; onOpen(): void;
}) {
  const scanner = status.scanner;
  const manualIpv4 = scannerIpv4(scanner.lan_url);
  return <div className="screen-stack">
    <section className="test-card">
      <div>
        <p className="eyebrow">Driverless eSCL</p>
        <h2>Scan from this PC</h2>
        <p>Open the private scanner page to preview and download a document. Scan image bytes stay between your browser and the Linux scanner service; PrintBridge does not store them or place them in diagnostics.</p>
      </div>
      <button className="button primary large" onClick={onOpen} disabled={busy !== null || !scanner.available}>
        {busy === "open-scanner" ? "Opening…" : "Open scanner"}
      </button>
    </section>
    <section className="card diagnostics-card">
      <div className="card-toolbar"><div><strong>{scanner.make_model ?? "Scanner unavailable"}</strong><small>{scanner.loopback_url}</small></div><StatusBadge state={status.components.scanner.state} /></div>
      <dl className="details-list">
        <div><dt>Sources</dt><dd>{scanner.sources.length ? scanner.sources.map(pretty).join(", ") : "Waiting for capabilities"}</dd></div>
        <div><dt>Color modes</dt><dd>{scanner.color_modes.length ? scanner.color_modes.join(", ") : "Waiting for capabilities"}</dd></div>
        <div><dt>File formats</dt><dd>{scanner.document_formats.length ? scanner.document_formats.join(", ") : "Waiting for capabilities"}</dd></div>
        <div><dt>Resolutions</dt><dd>{scanner.resolutions_dpi.length ? scanner.resolutions_dpi.map((value) => `${value} dpi`).join(", ") : "Waiting for capabilities"}</dd></div>
        <div><dt>Local network</dt><dd>{scanner.lan_url ?? "Scanner discovery is available only after the approved LAN and USB device are ready"}</dd></div>
      </dl>
    </section>
    <section className="info-strip"><span aria-hidden="true">●</span><div><strong>Phones and computers use their normal scan app</strong><p>On Android, install or open Mopria Scan. Windows Scan, macOS Image Capture, and Linux AirScan clients can use the scanner while PrintBridge is running on the same trusted, non-isolated local network.</p></div></section>
    <section className="info-strip"><span aria-hidden="true">+</span><div><strong>Android manual discovery fallback</strong><p>If Mopria Scan keeps searching, open its three-dot menu, choose Add Scanner, and enter the scanner name plus IPv4 address {manualIpv4 ?? "shown here after LAN scanning is ready"}. Manual addition stays limited to the approved local subnet.</p></div></section>
  </div>;
}

function Activity({ diagnostics, printResult, busy, onPrint }: {
  diagnostics: Diagnostics | null; printResult: TestPrintResult | null; busy: string | null; onPrint(): void;
}) {
  return <div className="screen-stack">
    <section className="test-card"><div><p className="eyebrow">End-to-end check</p><h2>Send a PrintBridge test page</h2><p>The agent submits through the real Windows queue. Software can report acceptance and CUPS progress, but only you can confirm paper output.</p></div><button className="button primary large" onClick={onPrint} disabled={busy !== null}>{busy === "test-print" ? "Submitting…" : "Print test page"}</button></section>
    {printResult && <section className="result-card" aria-live="polite"><div className="result-title"><span aria-hidden="true">✓</span><div><h3>Windows accepted the job</h3><p>Correlation {printResult.correlation_id}</p></div></div><dl className="result-grid"><div><dt>Spooler</dt><dd>{pretty(printResult.windows_spooler)}{printResult.spooler_job_id !== null ? ` · job ${printResult.spooler_job_id}` : ""}</dd></div><div><dt>CUPS</dt><dd>{pretty(printResult.cups_processing)}</dd></div><div><dt>Paper output</dt><dd className="truth-label">Requires your confirmation</dd></div></dl></section>}
    <section><div className="section-heading"><div><p className="eyebrow">Agent timeline</p><h2>Recent activity</h2></div></div>
      {!diagnostics ? <div className="loading-lines"><span /><span /><span /></div> : diagnostics.recent_events.length === 0 ? <EmptyState title="No recent events" detail="Bridge lifecycle and recovery events will appear here." /> : <div className="timeline">{diagnostics.recent_events.slice().reverse().slice(0, 8).map((event) => <div className="timeline-row" key={event.sequence}><span className={`timeline-dot level-${event.level}`} /><time dateTime={new Date(event.unix_ms).toISOString()}>{formatTime(event.unix_ms)}</time><div><strong>{pretty(event.event)}</strong><p>{event.detail}</p></div></div>)}</div>}
    </section>
  </div>;
}

function DiagnosticsScreen({ diagnostics, busy, exportPath, onRefresh, onRepair, onExport }: {
  diagnostics: Diagnostics | null; busy: string | null; exportPath: string | null; onRefresh(): void; onRepair(): void; onExport(): void;
}) {
  return <div className="screen-stack">
    <section className="action-grid"><article className="action-card"><span className="action-icon" aria-hidden="true">↻</span><div><h3>Repair owned resources</h3><p>Reconcile the selected VM, USB device, CUPS path, and Windows queue. Other VMs and printers are untouched.</p></div><button className="button primary" onClick={onRepair} disabled={busy !== null}>{busy === "repair" ? "Repairing…" : "Run safe repair"}</button></article><article className="action-card"><span className="action-icon" aria-hidden="true">⇩</span><div><h3>Export diagnostics</h3><p>Write a redacted JSON report to Documents\PrintBridge for troubleshooting.</p></div><button className="button secondary" onClick={onExport} disabled={busy !== null}>{busy === "export" ? "Exporting…" : "Export report"}</button></article></section>
    {exportPath && <div className="notice" role="status"><span aria-hidden="true">✓</span>Saved to {exportPath}</div>}
    <section className="card diagnostics-card"><div className="card-toolbar"><div><strong>Agent details</strong><small>{diagnostics ? `Protocol v${diagnostics.protocol_version} · process ${diagnostics.process_id}` : "Loading from the local agent"}</small></div><button className="icon-button" onClick={onRefresh} aria-label="Refresh diagnostics">↻</button></div>
      {!diagnostics ? <LoadingState compact /> : <><dl className="details-list"><div><dt>Generated</dt><dd>{new Date(diagnostics.generated_at_unix_ms).toLocaleString()}</dd></div><div><dt>Log</dt><dd>{diagnostics.log_path}</dd></div><div><dt>State</dt><dd>{diagnostics.state_path}</dd></div><div><dt>Local security</dt><dd>Owner-only named pipe</dd></div></dl><div className="notes"><h3>Notes</h3>{diagnostics.notes.length ? <ul>{diagnostics.notes.map((note) => <li key={note}>{note}</li>)}</ul> : <p>No diagnostic notes.</p>}</div></>}
    </section>
  </div>;
}

function Settings({ status, theme, busy, onTheme, onStart, onStop, onExit }: {
  status: AgentStatus; theme: ThemePreference; busy: string | null; onTheme(value: ThemePreference): void; onStart(): void; onStop(): void; onExit(): void;
}) {
  return <div className="screen-stack narrow">
    <section className="settings-section"><div className="section-heading"><div><p className="eyebrow">Appearance</p><h2>Theme</h2></div></div><fieldset className="segmented"><legend className="sr-only">Color theme</legend>{(["system", "light", "dark"] as ThemePreference[]).map((value) => <label key={value}><input type="radio" name="theme" checked={theme === value} onChange={() => onTheme(value)} /><span>{pretty(value)}</span></label>)}</fieldset><p className="setting-help">Theme preference stays in this UI process. No credentials or driver files are stored in webview storage.</p></section>
    <section className="settings-section"><div className="section-heading"><div><p className="eyebrow">On demand</p><h2>Print and scan engine</h2></div><StatusBadge state={status.startup.registered ? "error" : "ready"} /></div><div className="setting-row"><div><strong>No Windows login task</strong><p>{status.startup.logoff_behavior}</p></div><span className="read-only-label">App-owned</span></div><div className="setting-row"><div><strong>LAN print endpoint</strong><p>{status.lan.endpoint ?? "Unavailable until an explicitly approved local subnet is active"}</p></div><span className="read-only-label">{status.lan.interface_alias ? `${status.lan.interface_alias} · ${pretty(status.lan.network_category ?? "unknown")}` : "Not shared"}</span></div><div className="setting-row"><div><strong>LAN scan endpoint</strong><p>{status.scanner.lan_url ?? "Unavailable until the scanner and approved LAN are ready"}</p></div><span className="read-only-label">eSCL / AirScan</span></div><div className="engine-actions"><button className="button primary" onClick={onStart} disabled={busy !== null || status.desired === "running"}>Start engine</button><button className="button danger" onClick={onStop} disabled={busy !== null || status.desired === "stopped"}>Stop engine</button></div></section>
    <section className="settings-section"><div className="section-heading"><div><p className="eyebrow">Desktop behavior</p><h2>Window and tray</h2></div></div><div className="setting-row"><div><strong>Closing the window keeps printing active</strong><p>Close hides PrintBridge in the notification area. Explicit Exit stops LAN discovery, the agent, and the owned VM.</p></div><button className="button secondary" onClick={onExit}>Exit PrintBridge</button></div></section>
    <section className="about-card"><div className="brand-mark small" aria-hidden="true"><span /></div><div><strong>PrintBridge 0.1.0</strong><p>Protocol v7 · Tauri 2 desktop</p></div><span>Driverless IPP printing and eSCL scanning · fax is not supported</span></section>
  </div>;
}

function ErrorBanner({ error, onRetry, onDiagnostics }: { error: ClientError; onRetry(): void; onDiagnostics(): void }) {
  return <section className="error-banner" role="alert"><span className="error-symbol" aria-hidden="true">!</span><div><strong>{error.message}</strong><p>{error.action ?? "Open Diagnostics for more information."}</p><small>Error code: {error.code}</small></div><div><button className="button secondary" onClick={onRetry}>Try again</button><button className="text-button" onClick={onDiagnostics}>Diagnostics →</button></div></section>;
}

function StatusBadge({ state }: { state: ComponentState }) {
  return <span className={`status-badge state-${stateTone(state)}`}><span className="status-dot" aria-hidden="true" />{pretty(state)}</span>;
}

function EmptyState({ title, detail }: { title: string; detail: string }) {
  return <div className="empty-state"><span aria-hidden="true">◇</span><strong>{title}</strong><p>{detail}</p></div>;
}

function LoadingState({ compact = false }: { compact?: boolean }) {
  return <div className={compact ? "loading-state compact" : "loading-state"} aria-label="Loading"><span /><span /><span /></div>;
}

function stateTone(state: string): "good" | "warn" | "bad" | "neutral" {
  if (state === "ready" || state === "running") return "good";
  if (["waiting", "connecting", "starting", "stopping", "degraded"].includes(state)) return "warn";
  if (["error", "unavailable"].includes(state)) return "bad";
  return "neutral";
}

function pretty(value: string): string {
  return value.replaceAll("_", " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function scannerIpv4(value: string | null): string | null {
  if (!value) return null;
  try {
    const parsed = new URL(value);
    return parsed.protocol === "http:" && /^\d{1,3}(?:\.\d{1,3}){3}$/.test(parsed.hostname)
      ? parsed.hostname
      : null;
  } catch {
    return null;
  }
}

function componentIcon(key: keyof AgentStatus["components"]): string {
  return ({ hypervisor: "V", guest: "L", usb: "U", cups: "C", windows_queue: "W", scanner: "S", lan: "N" })[key];
}

function overallGuidance(state: string): string {
  if (state === "waiting_for_usb" || state === "waiting") return "Power on and reconnect the selected USB printer. Recovery is automatic.";
  if (state === "not_configured") return "Complete setup to create the local printing path.";
  if (state === "stopped") return "The printing engine is stopped. Opening PrintBridge starts it; explicit Exit stops it.";
  return "Review the component details below or run a safe repair from Diagnostics.";
}

function formatTime(unixMs: number): string {
  return new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit", second: "2-digit" }).format(unixMs);
}
