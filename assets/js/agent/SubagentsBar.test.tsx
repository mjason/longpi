import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { act, renderWithProviders, screen, within } from "../test/render";
import { SubagentsBar } from "./SubagentsBar";
import type { SubagentInfo } from "./channel";

// The elapsed-time chip reads the wall clock; freeze it so specs are stable.
const NOW = 1_000_000;

function agent(overrides: Partial<SubagentInfo> = {}): SubagentInfo {
  return {
    conversationId: "conv-123",
    role: "scout",
    status: "running",
    task: "map the codebase",
    startedAt: Math.floor(NOW / 1000) - 12, // 12s ago
    ...overrides,
  };
}

describe("SubagentsBar", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(NOW);
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  describe("given no subagents", () => {
    it("renders nothing", () => {
      const { container } = renderWithProviders(
        <SubagentsBar agents={{}} onOpen={() => {}} />,
      );
      expect(container).toBeEmptyDOMElement();
    });
  });

  describe("given one running subagent", () => {
    it("shows its handle and elapsed time", () => {
      renderWithProviders(
        <SubagentsBar agents={{ "scout-1": agent() }} onOpen={() => {}} />,
      );
      const chip = screen.getByRole("button", { name: /scout-1/ });
      expect(chip).toBeInTheDocument();
      expect(within(chip).getByText("12s")).toBeInTheDocument();
    });

    it("opens the child conversation when clicked", async () => {
      const onOpen = vi.fn();
      renderWithProviders(
        <SubagentsBar agents={{ "scout-1": agent() }} onOpen={onOpen} />,
      );
      // fireEvent (sync) rather than userEvent, which needs real timers.
      screen.getByRole("button", { name: /scout-1/ }).click();
      expect(onOpen).toHaveBeenCalledExactlyOnceWith("conv-123");
    });

    it("ticks the elapsed time forward while running", () => {
      renderWithProviders(
        <SubagentsBar agents={{ "scout-1": agent() }} onOpen={() => {}} />,
      );
      expect(screen.getByText("12s")).toBeInTheDocument();
      act(() => vi.advanceTimersByTime(3000));
      expect(screen.getByText("15s")).toBeInTheDocument();
    });

    it("formats elapsed over a minute as Xm0Ys", () => {
      renderWithProviders(
        <SubagentsBar
          agents={{ "scout-1": agent({ startedAt: Math.floor(NOW / 1000) - 125 }) }}
          onOpen={() => {}}
        />,
      );
      expect(screen.getByText("2m05s")).toBeInTheDocument();
    });
  });

  describe("given a finished subagent", () => {
    it("stops ticking (frozen elapsed)", () => {
      renderWithProviders(
        <SubagentsBar
          agents={{ "scout-1": agent({ status: "done" }) }}
          onOpen={() => {}}
        />,
      );
      expect(screen.getByText("12s")).toBeInTheDocument();
      act(() => vi.advanceTimersByTime(5000));
      // done → no interval, so the number does not advance
      expect(screen.getByText("12s")).toBeInTheDocument();
    });
  });

  describe("given several subagents", () => {
    it("renders one chip per handle", () => {
      renderWithProviders(
        <SubagentsBar
          agents={{
            "scout-1": agent(),
            "scout-2": agent({ status: "done" }),
            "worker-1": agent({ role: "worker", status: "failed" }),
          }}
          onOpen={() => {}}
        />,
      );
      expect(screen.getByRole("button", { name: /scout-1/ })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /scout-2/ })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /worker-1/ })).toBeInTheDocument();
    });
  });
});
