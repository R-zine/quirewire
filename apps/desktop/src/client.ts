import { invoke as tauriInvoke } from "@tauri-apps/api/core";
import type {
  AgentStatus,
  ClientErrorShape,
  DeviceSummary,
  Diagnostics,
  OperationResult,
  TestPrintResult,
} from "./types";
import { ClientError } from "./types";

export interface QuireWireClient {
  getStatus(): Promise<AgentStatus>;
  discoverDevices(): Promise<DeviceSummary[]>;
  beginSetup(deviceIndex: number): Promise<OperationResult>;
  start(): Promise<OperationResult>;
  stop(): Promise<OperationResult>;
  restart(): Promise<OperationResult>;
  testPrint(): Promise<TestPrintResult>;
  getDiagnostics(): Promise<Diagnostics>;
  repair(): Promise<OperationResult>;
  exportDiagnostics(): Promise<string>;
  openScanner(): Promise<void>;
  exitQuireWire(): Promise<void>;
}

export type Invoke = <T>(command: string, args?: Record<string, unknown>) => Promise<T>;

function normalizeError(error: unknown): ClientError {
  if (error instanceof ClientError) return error;
  if (typeof error === "object" && error !== null) {
    const value = error as Partial<ClientErrorShape>;
    if (typeof value.code === "string" && typeof value.message === "string") {
      return new ClientError({
        code: value.code,
        message: value.message,
        action: value.action,
        retryable: Boolean(value.retryable),
      });
    }
  }
  return new ClientError({
    code: "desktop_ipc_failed",
    message: error instanceof Error ? error.message : String(error),
    action: "Check that the QuireWire agent is running, then try again.",
    retryable: true,
  });
}

export class TauriQuireWireClient implements QuireWireClient {
  constructor(private readonly invoke: Invoke = tauriInvoke) {}

  private async call<T>(command: string, args?: Record<string, unknown>): Promise<T> {
    try {
      return await this.invoke<T>(command, args);
    } catch (error) {
      throw normalizeError(error);
    }
  }

  getStatus() { return this.call<AgentStatus>("agent_get_status"); }
  discoverDevices() { return this.call<DeviceSummary[]>("agent_discover_devices"); }
  beginSetup(deviceIndex: number) {
    return this.call<OperationResult>("agent_begin_setup", { deviceIndex });
  }
  start() { return this.call<OperationResult>("agent_start"); }
  stop() { return this.call<OperationResult>("agent_stop"); }
  restart() { return this.call<OperationResult>("agent_restart"); }
  testPrint() { return this.call<TestPrintResult>("agent_test_print"); }
  getDiagnostics() { return this.call<Diagnostics>("agent_get_diagnostics"); }
  repair() { return this.call<OperationResult>("agent_repair"); }
  exportDiagnostics() { return this.call<string>("export_diagnostics"); }
  openScanner() { return this.call<void>("open_scanner"); }
  exitQuireWire() { return this.call<void>("exit_quirewire"); }
}
