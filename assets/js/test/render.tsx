// Shared render helper: wraps a component in the providers most UI needs
// (i18n + Radix tooltips), so component tests read as behavior specs rather
// than provider plumbing.
import type { ReactElement, ReactNode } from "react";
import { render, type RenderOptions } from "@testing-library/react";

import { I18nProvider } from "@/agent/i18n";
import { TooltipProvider } from "@/components/ui/tooltip";
import {
  ConversationStoreProvider,
  createConversationStore,
  type ConversationStore,
} from "@/agent/store";

function AllProviders({ children }: { children: ReactNode }) {
  return (
    <I18nProvider>
      <TooltipProvider delayDuration={0}>{children}</TooltipProvider>
    </I18nProvider>
  );
}

export function renderWithProviders(ui: ReactElement, options?: RenderOptions) {
  return render(ui, { wrapper: AllProviders, ...options });
}

/**
 * Render inside a fresh conversation store (plus the base providers) — for
 * components that read `useConversationStore`. `seed` primes store state, e.g.
 * `{ cwd: "/proj" }`.
 */
export function renderWithStore(
  ui: ReactElement,
  seed?: Partial<{ cwd: string; workspaceFiles: string[] }>,
  options?: RenderOptions,
) {
  const store: ConversationStore = createConversationStore();
  if (seed?.cwd != null) store.getState().setWorkspace(seed.cwd, seed.workspaceFiles ?? []);

  function Wrapper({ children }: { children: ReactNode }) {
    return (
      <ConversationStoreProvider value={store}>
        <AllProviders>{children}</AllProviders>
      </ConversationStoreProvider>
    );
  }
  return { store, ...render(ui, { wrapper: Wrapper, ...options }) };
}

export * from "@testing-library/react";
