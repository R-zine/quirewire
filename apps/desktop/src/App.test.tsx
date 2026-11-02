import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { App } from "./App";
import { FakeQuireWireClient } from "./fakeClient";
import { ClientError } from "./types";

function renderApp(client = new FakeQuireWireClient()) {
  return render(<App client={client} pollIntervalMs={0} tauriEvents={false} />);
}

describe("QuireWire desktop flows", () => {
  it("renders real component-level status from the client", async () => {
    renderApp();
    expect(await screen.findByRole("heading", { name: "Ready to print" })).toBeTruthy();
    for (const name of ["VirtualBox", "Linux guest", "USB printer", "CUPS", "Windows queue", "eSCL scanner", "Local network"]) {
      expect(screen.getByRole("heading", { name })).toBeTruthy();
    }
    expect(screen.getByText("Brother via QuireWire is available to Windows and trusted local-network devices.")).toBeTruthy();
  });

  it("requires explicit whole-device consent before setup", async () => {
    const user = userEvent.setup();
    const client = FakeQuireWireClient.notConfigured();
    renderApp(client);
    await screen.findByRole("heading", { name: "Not Configured" });
    await user.click(screen.getByRole("button", { name: /^Setup/ }));
    await user.click(screen.getByRole("button", { name: "Scan for devices" }));
    expect(await screen.findByText("Brother DCP-L2600D")).toBeTruthy();

    const configure = screen.getByRole("button", { name: "Confirm and configure" }) as HTMLButtonElement;
    expect(configure.disabled).toBe(true);
    await user.click(screen.getByRole("checkbox", { name: /I understand this transfers/ }));
    expect(configure.disabled).toBe(false);
    await user.click(configure);

    await waitFor(() => expect(client.calls).toContain("beginSetup:2"));
    expect((await screen.findAllByText("Printer selected and setup reconciliation started")).length).toBeGreaterThan(0);
  });

  it("submits a test page without claiming physical output", async () => {
    const user = userEvent.setup();
    const client = new FakeQuireWireClient();
    renderApp(client);
    await screen.findByRole("heading", { name: "Ready to print" });
    await user.click(screen.getByRole("button", { name: "Print a test page" }));
    await user.click(await screen.findByRole("button", { name: "Print test page" }));

    expect(await screen.findByRole("heading", { name: "Windows accepted the job" })).toBeTruthy();
    expect(screen.getByText("Requires your confirmation")).toBeTruthy();
    expect(client.calls).toContain("testPrint");
  });

  it("shows live scanner capabilities and opens the fixed local scanner", async () => {
    const user = userEvent.setup();
    const client = new FakeQuireWireClient();
    renderApp(client);
    await screen.findByRole("heading", { name: "Ready to print" });
    await user.click(screen.getByRole("button", { name: /^Scan/ }));
    expect(await screen.findByRole("heading", { name: "Scan from this PC" })).toBeTruthy();
    expect(screen.getByText("http://127.0.0.1:8645/")).toBeTruthy();
    expect(screen.getByText(/300 dpi/)).toBeTruthy();
    expect(screen.getByText(/IPv4 address 192\.168\.1\.20/)).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "Open scanner" }));
    await waitFor(() => expect(client.calls).toContain("openScanner"));
    expect((await screen.findAllByText("Scanner opened in your default browser.")).length).toBeGreaterThan(0);
  });

  it("runs repair and exports redacted diagnostics", async () => {
    const user = userEvent.setup();
    const client = new FakeQuireWireClient();
    renderApp(client);
    await screen.findByRole("heading", { name: "Ready to print" });
    await user.click(screen.getByRole("button", { name: /^Diagnostics/ }));
    await screen.findByText(/Protocol v7/);
    await user.click(screen.getByRole("button", { name: "Run safe repair" }));
    await waitFor(() => expect(client.calls).toContain("repair"));
    await user.click(screen.getByRole("button", { name: "Export report" }));
    expect(await screen.findByText(/diagnostics-fake\.json/)).toBeTruthy();
    expect(client.calls).toContain("exportDiagnostics");
  });

  it("offers system, light, and dark accessible theme controls without web storage", async () => {
    const user = userEvent.setup();
    renderApp();
    await screen.findByRole("heading", { name: "Ready to print" });
    await user.click(screen.getByRole("button", { name: /^Settings/ }));
    const dark = screen.getByRole("radio", { name: "Dark" });
    await user.click(dark);
    expect(document.documentElement.dataset.theme).toBe("dark");
    expect(screen.getByText(/No credentials or driver files are stored/)).toBeTruthy();
  });

  it("makes explicit exit stop the on-demand bridge", async () => {
    const user = userEvent.setup();
    const client = new FakeQuireWireClient();
    renderApp(client);
    await screen.findByRole("heading", { name: "Ready to print" });
    await user.click(screen.getByRole("button", { name: /^Settings/ }));
    expect(screen.getByRole("button", { name: "Stop engine" })).toBeTruthy();
    await user.click(screen.getByRole("button", { name: "Exit QuireWire" }));
    expect(client.calls).toContain("exitQuireWire");
    expect(client.calls).not.toContain("stop");
    expect(screen.getByRole("heading", { name: "Closing QuireWire…" })).toBeTruthy();
    expect(screen.getByText(/This window will close automatically/)).toBeTruthy();
  });

  it("returns from the closing state when shutdown fails", async () => {
    const user = userEvent.setup();
    const client = new FakeQuireWireClient();
    client.exitQuireWire = vi.fn(async () => {
      throw new ClientError({
        code: "shutdown_failed",
        message: "QuireWire could not finish shutting down",
        action: "Try Exit again.",
        retryable: true,
      });
    });
    renderApp(client);
    await screen.findByRole("heading", { name: "Ready to print" });
    await user.click(screen.getByRole("button", { name: /^Settings/ }));
    await user.click(screen.getByRole("button", { name: "Exit QuireWire" }));

    expect(await screen.findByRole("alert")).toBeTruthy();
    expect(screen.getByText("Try Exit again.")).toBeTruthy();
    expect(screen.queryByRole("heading", { name: "Closing QuireWire…" })).toBeNull();
  });

  it("shows an actionable error state when the agent is unavailable", async () => {
    const client = new FakeQuireWireClient();
    client.getStatus = vi.fn(async () => {
      throw new ClientError({
        code: "agent_unavailable",
        message: "Cannot reach the QuireWire agent",
        action: "Run the startup task and try again.",
        retryable: true,
      });
    });
    renderApp(client);
    expect(await screen.findByRole("alert")).toBeTruthy();
    expect(screen.getByText("Run the startup task and try again.")).toBeTruthy();
    expect(screen.getByText("Error code: agent_unavailable")).toBeTruthy();
  });

  it("keeps stop behind a confirmation prompt", async () => {
    const client = new FakeQuireWireClient();
    vi.spyOn(window, "confirm").mockReturnValue(false);
    renderApp(client);
    await screen.findByRole("heading", { name: "Ready to print" });
    fireEvent.click(screen.getByRole("button", { name: /^Settings/ }));
    fireEvent.click(screen.getByRole("button", { name: "Stop engine" }));
    expect(client.calls).not.toContain("stop");
  });
});
