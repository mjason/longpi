import React from "react";
import { createRoot } from "react-dom/client";
import ChatApp from "./agent/ChatApp";

createRoot(document.getElementById("app")!).render(
  <React.StrictMode>
    <ChatApp />
  </React.StrictMode>,
);
