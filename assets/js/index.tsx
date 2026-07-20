import { createRoot } from "react-dom/client";
import ChatApp from "./agent/ChatApp";
import { ErrorBoundary } from "./components/ErrorBoundary";

// No React.StrictMode: its double-mount in dev makes the effect join, leave,
// then re-join the same Phoenix topic, which Phoenix rejects as a duplicate
// channel - leaving no active channel. The channel lifecycle is managed
// explicitly in agent/channel.ts.
createRoot(document.getElementById("app")!).render(
  <ErrorBoundary>
    <ChatApp />
  </ErrorBoundary>,
);
