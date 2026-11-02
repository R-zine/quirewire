import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { TauriQuireWireClient } from "./client";
import { FakeQuireWireClient } from "./fakeClient";
import "./styles.css";

const client = import.meta.env.MODE === "fake"
  ? FakeQuireWireClient.notConfigured()
  : new TauriQuireWireClient();

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App client={client} tauriEvents={import.meta.env.MODE !== "fake"} />
  </StrictMode>,
);
