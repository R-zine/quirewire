import type { PrintBridgeClient } from "./client";
import type {
  AgentStatus,
  DeviceSummary,
  Diagnostics,
  OperationResult,
  TestPrintResult,
} from "./types";

const readyStatus = (): AgentStatus => ({
  desired: "running",
  overall: "ready",
  revision: 4,
  retry_after_ms: null,
  components: {
    hypervisor: { state: "ready", detail: "Oracle VirtualBox 7.2 available" },
    guest: { state: "ready", detail: "Headless guest is running" },
    usb: { state: "ready", detail: "Selected printer is attached" },
    cups: { state: "ready", detail: "CUPS is accepting jobs" },
    windows_queue: { state: "ready", detail: "Microsoft IPP Class Driver" },
    lan: { state: "ready", detail: "Available on explicitly approved LAN" },
  },
  startup: {
    registered: false,
    task_name: "\\PrintBridge\\Agent",
    logoff_behavior: "On-demand mode; no login task.",
  },
  lan: {
    enabled: true,
    interface_alias: "Ethernet",
    network_category: "private",
    address: "192.168.1.20",
    endpoint: "ipp://192.168.1.20:8644/printers/PrintBridge_DCP_L2600D",
    service_instance: "Brother via PrintBridge",
  },
});

export class FakePrintBridgeClient implements PrintBridgeClient {
  readonly calls: string[] = [];
  status: AgentStatus = readyStatus();
  devices: DeviceSummary[] = [
    {
      index: 2,
      vendor_id: "04f9",
      product_id: "0567",
      display_name: "Brother DCP-L2600D",
      serial_present: true,
      selected: true,
    },
  ];

  static notConfigured(): FakePrintBridgeClient {
    const client = new FakePrintBridgeClient();
    client.status = {
      ...readyStatus(),
      desired: "stopped",
      overall: "not_configured",
      revision: 0,
      components: {
        hypervisor: { state: "ready", detail: "Oracle VirtualBox 7.2 available" },
        guest: { state: "not_configured", detail: "Appliance setup is required" },
        usb: { state: "not_configured", detail: "Choose the USB printer" },
        cups: { state: "not_configured", detail: "Guest printing is not configured" },
        windows_queue: { state: "not_configured", detail: "Windows queue is not installed" },
        lan: { state: "not_configured", detail: "LAN sharing is not configured" },
      },
    };
    client.devices = client.devices.map((device) => ({ ...device, selected: false }));
    return client;
  }

  async getStatus() {
    this.calls.push("getStatus");
    return structuredClone(this.status);
  }
  async discoverDevices() {
    this.calls.push("discoverDevices");
    return structuredClone(this.devices);
  }
  async beginSetup(deviceIndex: number) {
    this.calls.push(`beginSetup:${deviceIndex}`);
    this.devices = this.devices.map((device) => ({
      ...device,
      selected: device.index === deviceIndex,
    }));
    this.status = readyStatus();
    return accepted("begin_setup", "Printer selected and setup reconciliation started");
  }
  async start() {
    this.calls.push("start");
    this.status = { ...this.status, desired: "running", overall: "ready" };
    return accepted("start", "Printing engine is running");
  }
  async stop() {
    this.calls.push("stop");
    this.status = { ...this.status, desired: "stopped", overall: "stopped" };
    return accepted("stop", "Printing engine stopped");
  }
  async restart() {
    this.calls.push("restart");
    return accepted("restart", "Bridge restart accepted");
  }
  async testPrint(): Promise<TestPrintResult> {
    this.calls.push("testPrint");
    return {
      correlation_id: "fake-test-1",
      spooler_job_id: 42,
      windows_spooler: "accepted",
      cups_processing: "not_observed",
      physical_output: "requires_owner_confirmation",
    };
  }
  async getDiagnostics(): Promise<Diagnostics> {
    this.calls.push("getDiagnostics");
    return {
      generated_at_unix_ms: Date.now(),
      protocol_version: 6,
      owner_sid: "redacted-in-preview",
      pipe_name: "PrintBridge owner-only pipe",
      process_id: 1000,
      state_path: "PrintBridge/state",
      log_path: "PrintBridge/agent.jsonl",
      status: structuredClone(this.status),
      recent_events: [
        { sequence: 7, unix_ms: Date.now(), level: "info", event: "ready", detail: "All components are ready" },
      ],
      notes: ["Physical output always requires confirmation."],
    };
  }
  async repair() {
    this.calls.push("repair");
    this.status = readyStatus();
    return accepted("repair", "Owned resources reconciled");
  }
  async exportDiagnostics() {
    this.calls.push("exportDiagnostics");
    return "Documents\\PrintBridge\\diagnostics-fake.json";
  }
  async exitPrintBridge() {
    this.calls.push("exitPrintBridge");
  }
}

function accepted(operation: string, detail: string): OperationResult {
  return { operation, accepted: true, detail };
}
