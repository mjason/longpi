import { describe, expect, it } from "vitest";

import { renderWithProviders, screen } from "../../test/render";
import { ToolDiff, isDiffTool } from "./tool-diff";

describe("isDiffTool", () => {
  it("covers edit, write, and apply_patch", () => {
    expect(isDiffTool("edit")).toBe(true);
    expect(isDiffTool("write")).toBe(true);
    expect(isDiffTool("apply_patch")).toBe(true);
    expect(isDiffTool("bash")).toBe(false);
  });
});

describe("ToolDiff collapse", () => {
  it("collapses a tall write behind a 'Show all' toggle", () => {
    const content = Array.from({ length: 60 }, (_, i) => `line ${i}`).join("\n");
    renderWithProviders(<ToolDiff toolName="write" args={{ path: "big.txt", content }} />);
    expect(screen.getByText("Show all 60 lines")).toBeInTheDocument();
  });

  it("leaves a short edit fully expanded (no toggle)", () => {
    renderWithProviders(
      <ToolDiff toolName="edit" args={{ path: "a.ex", old_string: "one", new_string: "two" }} />,
    );
    expect(screen.queryByText(/Show all/)).toBeNull();
  });
});

describe("ToolDiff apply_patch", () => {
  it("renders patch text with the changed lines", () => {
    const input = "*** Begin Patch\n*** Update File: a.ex\n@@\n-old line\n+new line\n*** End Patch";
    renderWithProviders(<ToolDiff toolName="apply_patch" args={{ input }} />);
    expect(screen.getByText("-old line")).toBeInTheDocument();
    expect(screen.getByText("+new line")).toBeInTheDocument();
  });
});
