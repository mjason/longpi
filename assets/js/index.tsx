import { createRoot } from "react-dom/client";
import { BrowserRouter, Route, Routes } from "react-router-dom";
import ChatApp from "./agent/ChatApp";
import { I18nProvider } from "./agent/i18n";
import MobileChat from "./agent/MobileChat";
import EmbedApp from "./agent/EmbedApp";
import { ManagementRoute } from "./agent/ManagementPanel";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { installClipboardFallback } from "./lib/clipboard";
import { installCsrfRetry } from "./rpc-csrf";

// Enables the copy button over plain-HTTP LAN addresses (see the module doc).
installClipboardFallback();

// Self-heal a stale CSRF token (open tab across a deploy) by refreshing + retrying
// a 403'd /rpc/ call, so the sidebar/data don't silently fail to load.
installCsrfRetry();

// No React.StrictMode: its double-mount in dev makes the effect join, leave,
// then re-join the same Phoenix topic, which Phoenix rejects as a duplicate
// channel - leaving no active channel. The channel lifecycle is managed
// explicitly in agent/channel.ts.
createRoot(document.getElementById("app")!).render(
  <ErrorBoundary>
    <I18nProvider>
    <BrowserRouter>
      <Routes>
        <Route path="/" element={<ChatApp />} />
        <Route path="/c/:conversationId" element={<ChatApp />} />
        <Route path="/manage" element={<ManagementRoute />} />
        <Route path="/manage/:section" element={<ManagementRoute />} />
        <Route path="/embed" element={<EmbedApp />} />
        <Route path="/m/c/:conversationId" element={<MobileChat />} />
      </Routes>
    </BrowserRouter>
    </I18nProvider>
  </ErrorBoundary>,
);
