// Shared render helper: wraps a component in the providers most UI needs
// (i18n + Radix tooltips), so component tests read as behavior specs rather
// than provider plumbing.
import type { ReactElement, ReactNode } from "react";
import { render, type RenderOptions } from "@testing-library/react";

import { I18nProvider } from "@/agent/i18n";
import { TooltipProvider } from "@/components/ui/tooltip";

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

export * from "@testing-library/react";
