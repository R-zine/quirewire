import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { TauriPrintBridgeClient } from "./client";
import { FakePrintBridgeClient } from "./fakeClient";
import "./styles.css";

const client = import.meta.env.MODE === "fake"
  ? FakePrintBridgeClient.notConfigured()
  : new TauriPrintBridgeClient();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App client={client} tauriEvents={import.meta.env.MODE !== "fake"} />
  </StrictMode>,
);
