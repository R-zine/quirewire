export type ComponentState =
  | "not_configured"
  | "stopped"
  | "starting"
  | "waiting"
  | "connecting"
  | "ready"
  | "degraded"
  | "error"
  | "stopping";

export interface ComponentStatus {
  state: ComponentState;
  detail: string;
}

export interface AgentStatus {
  desired: string;
  overall: string;
  revision: number;
  retry_after_ms: number | null;
  components: {
    hypervisor: ComponentStatus;
    guest: ComponentStatus;
    usb: ComponentStatus;
    cups: ComponentStatus;
    windows_queue: ComponentStatus;
    lan: ComponentStatus;
  };
  startup: {
    registered: boolean;
    task_name: string;
    logoff_behavior: string;
  };
  lan: {
    enabled: boolean;
    interface_alias: string | null;
    network_category: string | null;
    address: string | null;
    endpoint: string | null;
    service_instance: string | null;
  };
}

export interface DeviceSummary {
  index: number;
  vendor_id: string;
  product_id: string;
  display_name: string;
  serial_present: boolean;
  selected: boolean;
}

export interface OperationResult {
  operation: string;
  accepted: boolean;
  detail: string;
}

export interface TestPrintResult {
  correlation_id: string;
  spooler_job_id: number | null;
  windows_spooler: string;
  cups_processing: string;
  physical_output: string;
}

export interface AgentEvent {
  sequence: number;
  unix_ms: number;
  level: string;
  event: string;
  detail: string;
}

export interface Diagnostics {
  generated_at_unix_ms: number;
  protocol_version: number;
  owner_sid: string;
  pipe_name: string;
  process_id: number;
  state_path: string;
  log_path: string;
  status: AgentStatus;
  recent_events: AgentEvent[];
  notes: string[];
}

export interface ClientErrorShape {
  code: string;
  message: string;
  action?: string | null;
  retryable: boolean;
}

export class ClientError extends Error implements ClientErrorShape {
  readonly code: string;
  readonly action: string | null;
  readonly retryable: boolean;

  constructor(value: ClientErrorShape) {
    super(value.message);
    this.name = "ClientError";
    this.code = value.code;
    this.action = value.action ?? null;
    this.retryable = value.retryable;
  }
}

export type ScreenId = "dashboard" | "setup" | "activity" | "diagnostics" | "settings";
export type ThemePreference = "system" | "light" | "dark";
