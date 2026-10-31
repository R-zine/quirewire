import { describe, expect, it } from "vitest";
import { TauriPrintBridgeClient } from "./client";
import type { Invoke } from "./client";
import type { AgentStatus } from "./types";

const status: AgentStatus = {
  desired: "running",
  overall: "ready",
  revision: 1,
  retry_after_ms: null,
  components: {
    hypervisor: { state: "ready", detail: "ready" },
    guest: { state: "ready", detail: "ready" },
    usb: { state: "ready", detail: "ready" },
    cups: { state: "ready", detail: "ready" },
    windows_queue: { state: "ready", detail: "ready" },
    lan: { state: "ready", detail: "ready" },
  },
  startup: { registered: false, task_name: "task", logoff_behavior: "on demand" },
  lan: {
    enabled: true,
    interface_alias: "Ethernet",
    network_category: "private",
    address: "192.168.1.20",
    endpoint: "ipp://192.168.1.20:8644/printers/PrintBridge_DCP_L2600D",
    service_instance: "Brother via PrintBridge",
  },
};

describe("TauriPrintBridgeClient", () => {
  it("maps the typed frontend contract to fixed Tauri commands", async () => {
    const calls: [string, Record<string, unknown> | undefined][] = [];
    const invoke: Invoke = async <T>(command: string, args?: Record<string, unknown>): Promise<T> => {
      calls.push([command, args]);
      if (command === "agent_get_status") return status as T;
      return { operation: command, accepted: true, detail: JSON.stringify(args ?? {}) } as T;
    };
    const client = new TauriPrintBridgeClient(invoke);

    expect((await client.getStatus()).overall).toBe("ready");
    await client.beginSetup(7);
    await client.restart();
    await client.repair();

    expect(calls).toEqual([
      ["agent_get_status", undefined],
      ["agent_begin_setup", { deviceIndex: 7 }],
      ["agent_restart", undefined],
      ["agent_repair", undefined],
    ]);
  });

  it("preserves actionable structured agent errors", async () => {
    const invoke: Invoke = async <T>(): Promise<T> => {
      throw { code: "usb_busy", message: "Printer is busy", action: "Close the other app.", retryable: true };
    };
    const client = new TauriPrintBridgeClient(invoke);

    await expect(client.getStatus()).rejects.toMatchObject({
      code: "usb_busy",
      message: "Printer is busy",
      action: "Close the other app.",
      retryable: true,
    });
  });
});
