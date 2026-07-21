import { createRoot } from "react-dom/client";
import { BrowserRouter, Route, Routes } from "react-router-dom";
import ChatApp from "./agent/ChatApp";
import { ManagementRoute } from "./agent/ManagementPanel";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { installClipboardFallback } from "./lib/clipboard";

// Enables the copy button over plain-HTTP LAN addresses (see the module doc).
installClipboardFallback();

// No React.StrictMode: its double-mount in dev makes the effect join, leave,
// then re-join the same Phoenix topic, which Phoenix rejects as a duplicate
// channel - leaving no active channel. The channel lifecycle is managed
// explicitly in agent/channel.ts.
createRoot(document.getElementById("app")!).render(
  <ErrorBoundary>
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<ChatApp />} />
        <Route path="/c/:conversationId" element={<ChatApp />} />
        <Route path="/manage" element={<ManagementRoute />} />
        <Route path="/manage/:section" element={<ManagementRoute />} />
      </Routes>
    </BrowserRouter>
  </ErrorBoundary>,
);
