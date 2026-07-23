import { beforeEach, describe, expect, it, vi } from "vitest";

// Behavior specs for the Schedules admin page: what an admin sees and can do.
// RPC modules are mocked at the boundary; assertions are on rendered behavior.

const settingsMock = vi.hoisted(() => ({
  loadScheduledTasks: vi.fn(),
  loadCronNexts: vi.fn(),
  setScheduledTask: vi.fn(),
  removeScheduledTask: vi.fn(),
}));

vi.mock("../settings", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../settings")>()),
  ...settingsMock,
}));

vi.mock("../../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  listConversations: vi.fn().mockResolvedValue({
    success: true,
    data: [{ id: "c-1", title: "部署调优" }],
  }),
}));

import { MemoryRouter } from "react-router-dom";
import { fireEvent, waitFor } from "@testing-library/react";
import { renderWithProviders, screen } from "../../test/render";
import { SchedulesSection } from "./SchedulesSection";

const nightly = {
  id: "s-1",
  conversationId: "c-1",
  cron: "0 23 * * *",
  task: "总结今天的对话和完成的工作",
  enabled: true,
  lastRunAt: null,
};

function renderPage() {
  return renderWithProviders(
    <MemoryRouter>
      <SchedulesSection />
    </MemoryRouter>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  settingsMock.loadCronNexts.mockResolvedValue({ "0 23 * * *": "2026-07-23 23:00:00" });
  settingsMock.setScheduledTask.mockResolvedValue({ success: true });
  settingsMock.removeScheduledTask.mockResolvedValue({ success: true });
});

describe("an admin opens the Schedules page", () => {
  it("with no schedules, explains how to create one in natural language", async () => {
    settingsMock.loadScheduledTasks.mockResolvedValue([]);
    renderPage();
    expect(await screen.findByText(/每天晚上11点总结当天工作/)).toBeInTheDocument();
  });

  it("shows each schedule with its cron, task, conversation, and next run", async () => {
    settingsMock.loadScheduledTasks.mockResolvedValue([nightly]);
    renderPage();

    expect(await screen.findByText("0 23 * * *")).toBeInTheDocument();
    expect(screen.getByText("总结今天的对话和完成的工作")).toBeInTheDocument();
    // Conversation title links into the conversation.
    expect(screen.getByText("部署调优")).toHaveAttribute("href", "/c/c-1");
    expect(screen.getByText(/2026-07-23 23:00:00/)).toBeInTheDocument();
  });
});

describe("an admin manages a schedule", () => {
  it("toggling the switch disables it via RPC", async () => {
    settingsMock.loadScheduledTasks.mockResolvedValue([nightly]);
    renderPage();

    fireEvent.click(await screen.findByRole("switch"));
    await waitFor(() =>
      expect(settingsMock.setScheduledTask).toHaveBeenCalledWith("s-1", { enabled: false }),
    );
  });

  it("deleting asks for confirmation first and honors a cancel", async () => {
    settingsMock.loadScheduledTasks.mockResolvedValue([nightly]);
    const confirmSpy = vi.spyOn(window, "confirm").mockReturnValue(false);
    renderPage();

    fireEvent.click(await screen.findByLabelText("Delete schedule"));
    expect(confirmSpy).toHaveBeenCalled();
    expect(settingsMock.removeScheduledTask).not.toHaveBeenCalled();

    confirmSpy.mockReturnValue(true);
    fireEvent.click(screen.getByLabelText("Delete schedule"));
    await waitFor(() => expect(settingsMock.removeScheduledTask).toHaveBeenCalledWith("s-1"));
  });
});
