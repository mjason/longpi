import { describe, expect, it } from "vitest";
import { historyToItems } from "./channel";
import { itemsToMessages } from "./runtime";
import type { HistoryMessage } from "./types";

// Reproduces the real bug: forking the first AI reply cut off its final
// summary because item INDEXES were used as DB positions. Rows and items
// don't line up (empty-text assistant rows emit no item; tool result rows
// fill an existing item), so items must carry their true dbPos.
describe("fork position mapping", () => {
  const messages = [
    { role: "user", content: "有什么目录", attachments: [], tool_calls: [] },
    {
      role: "assistant",
      content: "", // empty text: yields NO assistant item
      tool_calls: [
        { id: "c1", name: "ls", args: {} },
        { id: "c2", name: "find", args: {} },
      ],
    },
    { role: "tool", content: "r1", tool_call_id: "c1", error: false },
    { role: "tool", content: "r2", tool_call_id: "c2", error: false },
    { role: "assistant", content: "最终总结", tool_calls: [] },
    { role: "user", content: "追问", attachments: [], tool_calls: [] },
  ] as unknown as HistoryMessage[];

  it("items carry the DB position that contains them", () => {
    const items = historyToItems(messages);
    expect(items.map((i) => [i.kind, (i as { dbPos?: number }).dbPos])).toEqual([
      ["user", 0],
      ["tool", 2], // result row, not the call's assistant row
      ["tool", 3],
      ["assistant", 4],
      ["user", 5],
    ]);
  });

  it("the merged AI reply forks at its LAST row — the summary comes along", () => {
    const uiMessages = itemsToMessages(historyToItems(messages));
    const custom = (m: (typeof uiMessages)[number]) =>
      (m.metadata?.custom ?? {}) as { lastItemIndex?: number; isLastUser?: boolean };

    expect(uiMessages).toHaveLength(3); // user, merged assistant, user
    expect(custom(uiMessages[0]).lastItemIndex).toBe(0);
    // The old index-based logic said 3 here and cut off row 4 (the summary).
    expect(custom(uiMessages[1]).lastItemIndex).toBe(4);
    expect(custom(uiMessages[2]).lastItemIndex).toBe(5);
    expect(custom(uiMessages[2]).isLastUser).toBe(true);
    expect(custom(uiMessages[0]).isLastUser).toBe(false);
  });
});
