import type { AppendMessage } from "@assistant-ui/react";
import { describe, expect, it } from "vitest";
import { extractAttachments, itemsToMessages, toUiAttachments } from "./runtime";
import type { MessageAttachment, ThreadItem } from "./types";

// AppendMessage carries far more than the attachment shape these helpers read;
// this builder keeps the test data to just the parts under test.
function appendMessage(attachments: unknown[]): AppendMessage {
  return { attachments } as unknown as AppendMessage;
}

describe("extractAttachments", () => {
  it("parses an image data URL into wire format (media_type + base64 data)", () => {
    const msg = appendMessage([
      {
        name: "shot.png",
        content: [{ type: "image", image: "data:image/png;base64,AAA" }],
      },
    ]);
    expect(extractAttachments(msg)).toEqual([
      { type: "image", name: "shot.png", media_type: "image/png", data: "AAA" },
    ]);
  });

  it("maps a text part to a file attachment", () => {
    const msg = appendMessage([
      { name: "notes.txt", content: [{ type: "text", text: "hello" }] },
    ]);
    expect(extractAttachments(msg)).toEqual([
      { type: "file", name: "notes.txt", text: "hello" },
    ]);
  });

  it("skips malformed image data URLs", () => {
    const msg = appendMessage([
      { name: "bad.png", content: [{ type: "image", image: "not-a-data-url" }] },
    ]);
    expect(extractAttachments(msg)).toEqual([]);
  });

  it("returns [] when there are no attachments", () => {
    expect(extractAttachments(appendMessage([]))).toEqual([]);
    expect(extractAttachments({} as AppendMessage)).toEqual([]);
  });

  it("collects multiple parts across multiple attachments", () => {
    const msg = appendMessage([
      { name: "a.png", content: [{ type: "image", image: "data:image/jpeg;base64,ZZZ" }] },
      { name: "b.txt", content: [{ type: "text", text: "doc" }] },
    ]);
    expect(extractAttachments(msg)).toEqual([
      { type: "image", name: "a.png", media_type: "image/jpeg", data: "ZZZ" },
      { type: "file", name: "b.txt", text: "doc" },
    ]);
  });
});

describe("toUiAttachments", () => {
  it("rebuilds an image attachment with an inline data URL", () => {
    const list: MessageAttachment[] = [
      { type: "image", name: "shot.png", media_type: "image/png", data: "AAA" },
    ];
    expect(toUiAttachments(list)).toEqual([
      {
        id: "att-0",
        type: "image",
        name: "shot.png",
        contentType: "image/png",
        content: [{ type: "image", image: "data:image/png;base64,AAA" }],
        status: { type: "complete" },
      },
    ]);
  });

  it("rebuilds a file attachment as a text document tile", () => {
    const list: MessageAttachment[] = [{ type: "file", name: "notes.txt", text: "hello" }];
    expect(toUiAttachments(list)).toEqual([
      {
        id: "att-0",
        type: "document",
        name: "notes.txt",
        contentType: "text/plain",
        content: [{ type: "text", text: "hello" }],
        status: { type: "complete" },
      },
    ]);
  });

  it("indexes ids by position", () => {
    const list: MessageAttachment[] = [
      { type: "file", name: "a.txt", text: "1" },
      { type: "file", name: "b.txt", text: "2" },
    ];
    expect(toUiAttachments(list).map((a) => a.id)).toEqual(["att-0", "att-1"]);
  });
});

describe("itemsToMessages", () => {
  it("attaches a user item's attachments to its message", () => {
    const items: ThreadItem[] = [
      {
        kind: "user",
        text: "look",
        attachments: [{ type: "image", name: "s.png", media_type: "image/png", data: "AAA" }],
      },
    ];
    const [msg] = itemsToMessages(items);
    expect(msg.role).toBe("user");
    expect(msg.content).toEqual([{ type: "text", text: "look" }]);
    expect(msg.attachments).toEqual(toUiAttachments(items[0].kind === "user" ? items[0].attachments! : []));
  });

  it("omits the attachments key when a user item has none", () => {
    const items: ThreadItem[] = [{ kind: "user", text: "hi" }];
    const [msg] = itemsToMessages(items);
    expect("attachments" in msg).toBe(false);
  });

  it("groups consecutive assistant + tool items into one assistant message", () => {
    const items: ThreadItem[] = [
      { kind: "assistant", text: "working", streaming: false },
      {
        kind: "tool",
        id: "t1",
        name: "bash",
        args: { cmd: "ls" },
        content: "ok",
        error: false,
        running: false,
      },
    ];
    const messages = itemsToMessages(items);
    expect(messages).toHaveLength(1);
    expect(messages[0].role).toBe("assistant");
    const parts = messages[0].content as { type: string }[];
    expect(parts.map((p) => p.type)).toEqual(["text", "tool-call"]);
  });

  it("marks the message requires-action while a tool awaits approval", () => {
    const items: ThreadItem[] = [
      {
        kind: "tool",
        id: "t1",
        name: "bash",
        error: false,
        running: false,
        awaitingApproval: true,
      },
    ];
    const [msg] = itemsToMessages(items);
    expect(msg.status).toEqual({ type: "requires-action", reason: "tool-calls" });
  });
});
