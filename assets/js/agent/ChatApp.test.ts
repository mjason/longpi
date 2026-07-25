import { describe, expect, it } from "vitest";
import { conversationLabel, folderName, groupByProject, mostUrgentKind, withOpenConversationSeen } from "./ChatApp";
import type { ConversationSummary } from "./types";

function conv(over: Partial<ConversationSummary> & { id: string }): ConversationSummary {
  return { title: null, cwd: "/home/me/proj", model: "openai:gpt-5.4", ...over };
}

describe("folderName", () => {
  it("returns the last path segment", () => {
    expect(folderName("/home/me/projects/longpi")).toBe("longpi");
  });

  it("ignores a trailing slash", () => {
    expect(folderName("/home/me/projects/longpi/")).toBe("longpi");
  });

  it("handles a single segment", () => {
    expect(folderName("/longpi")).toBe("longpi");
    expect(folderName("longpi")).toBe("longpi");
  });

  it("falls back to the raw value for the root path", () => {
    expect(folderName("/")).toBe("/");
  });
});

describe("conversationLabel", () => {
  it("uses the title when present", () => {
    expect(conversationLabel(conv({ id: "1", title: "Fix the bug", cwd: "/a/b" }))).toBe(
      "Fix the bug",
    );
  });

  it("falls back to the last cwd segment when there is no title", () => {
    expect(conversationLabel(conv({ id: "1", title: null, cwd: "/home/me/longpi" }))).toBe(
      "longpi",
    );
  });
});

describe("groupByProject", () => {
  it("groups conversations by cwd", () => {
    const groups = groupByProject([
      conv({ id: "1", cwd: "/a" }),
      conv({ id: "2", cwd: "/b" }),
      conv({ id: "3", cwd: "/a" }),
    ]);
    expect(groups.map((g) => g.cwd)).toEqual(["/a", "/b"]);
    expect(groups[0].conversations.map((c) => c.id)).toEqual(["1", "3"]);
    expect(groups[1].conversations.map((c) => c.id)).toEqual(["2"]);
  });

  it("keeps most-recent (first-seen) project ordering", () => {
    // Input is assumed newest-first, so the first cwd seen leads.
    const groups = groupByProject([
      conv({ id: "1", cwd: "/newest" }),
      conv({ id: "2", cwd: "/older" }),
    ]);
    expect(groups.map((g) => g.cwd)).toEqual(["/newest", "/older"]);
  });

  it("preserves order within a group", () => {
    const [group] = groupByProject([
      conv({ id: "1", cwd: "/a" }),
      conv({ id: "2", cwd: "/a" }),
      conv({ id: "3", cwd: "/a" }),
    ]);
    expect(group.conversations.map((c) => c.id)).toEqual(["1", "2", "3"]);
  });

  it("returns an empty list for no conversations", () => {
    expect(groupByProject([])).toEqual([]);
  });
});

describe("mostUrgentKind", () => {
  it("ranks approval > failed > done — a blue done never masks an amber approval", () => {
    expect(
      mostUrgentKind([
        conv({ id: "1", cwd: "/a", unseenKind: "done" }),
        conv({ id: "2", cwd: "/a", unseenKind: "approval" }),
        conv({ id: "3", cwd: "/a", unseenKind: "failed" }),
      ]),
    ).toBe("approval");
    expect(
      mostUrgentKind([
        conv({ id: "1", cwd: "/a", unseenKind: "done" }),
        conv({ id: "2", cwd: "/a", unseenKind: "failed" }),
      ]),
    ).toBe("failed");
  });

  it("is null when nothing is flagged", () => {
    expect(mostUrgentKind([conv({ id: "1", cwd: "/a" })])).toBeNull();
  });
});

describe("withOpenConversationSeen", () => {
  it("clears the dot ONLY on the open conversation", () => {
    const result = withOpenConversationSeen(
      [
        conv({ id: "open", cwd: "/a", unseenKind: "done" }),
        conv({ id: "other", cwd: "/a", unseenKind: "approval" }),
      ],
      "open",
    );
    expect(result.find((c) => c.id === "open")?.unseenKind).toBeNull();
    expect(result.find((c) => c.id === "other")?.unseenKind).toBe("approval");
  });

  it("returns the same array when there is nothing to clear (no render churn)", () => {
    const list = [conv({ id: "a", cwd: "/a" })];
    expect(withOpenConversationSeen(list, "a")).toBe(list);
    expect(withOpenConversationSeen(list, null)).toBe(list);
  });
});
