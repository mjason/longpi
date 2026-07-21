import type { AppendMessage } from "@assistant-ui/react";
import { describe, expect, it } from "vitest";
import { extractAttachments, toUiAttachments } from "./runtime";
import type { MessageAttachment } from "./types";

// Sanity that the wire shape's key names (media_type / data) survive a full
// extract → toUi → extract cycle. toUiAttachments produces objects whose
// { name, content } are exactly what extractAttachments reads back.
describe("MessageAttachment wire round-trip", () => {
  it("preserves an image attachment through toUi and back", () => {
    const original: MessageAttachment = {
      type: "image",
      name: "diagram.png",
      media_type: "image/png",
      data: "QUJD",
    };

    const ui = toUiAttachments([original]);
    const roundTripped = extractAttachments({ attachments: ui } as unknown as AppendMessage);

    expect(roundTripped).toEqual([original]);
    // The key names are the load-bearing part of the contract.
    expect(roundTripped[0]).toHaveProperty("media_type", "image/png");
    expect(roundTripped[0]).toHaveProperty("data", "QUJD");
  });

  it("preserves a file attachment through toUi and back", () => {
    const original: MessageAttachment = { type: "file", name: "readme.txt", text: "hi there" };

    const ui = toUiAttachments([original]);
    const roundTripped = extractAttachments({ attachments: ui } as unknown as AppendMessage);

    expect(roundTripped).toEqual([original]);
  });
});
