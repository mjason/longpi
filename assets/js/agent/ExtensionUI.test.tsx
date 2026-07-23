import { describe, expect, it } from "vitest";

import { renderWithProviders, screen } from "../test/render";
import { ExtensionUI, parseExtensionUI } from "./ExtensionUI";
import { renderBuiltinResult } from "./BuiltinToolUI";

describe("parseExtensionUI", () => {
  it("recognizes a UI envelope and rejects plain results", () => {
    const node = { __longpi_ui__: true, type: "Text", props: {}, children: ["hi"] };
    expect(parseExtensionUI(JSON.stringify(node))).toMatchObject({ type: "Text" });

    expect(parseExtensionUI("just a string")).toBeNull();
    expect(parseExtensionUI(JSON.stringify({ matched: 9 }))).toBeNull();
    expect(parseExtensionUI(42)).toBeNull();
  });
});

describe("ExtensionUI", () => {
  it("renders a Table from a serializable node", () => {
    const node = {
      type: "Table",
      props: { columns: ["实体", "状态"], rows: [["温度", "unavailable"]] },
      children: [],
    };
    renderWithProviders(<ExtensionUI node={node} />);

    expect(screen.getByText("实体")).toBeInTheDocument();
    expect(screen.getByText("温度")).toBeInTheDocument();
    expect(screen.getByText("unavailable")).toBeInTheDocument();
  });

  it("degrades an unknown node type to its children", () => {
    const node = { type: "SomethingNew", props: {}, children: ["fallback text"] };
    renderWithProviders(<ExtensionUI node={node} />);
    expect(screen.getByText("fallback text")).toBeInTheDocument();
  });
});

describe("renderBuiltinResult", () => {
  it("renders bash output with an exit-code note", () => {
    const node = renderBuiltinResult("bash", "hello world\n(exit code: 1)");
    expect(node).not.toBeNull();
    renderWithProviders(<>{node}</>);
    expect(screen.getByText("hello world")).toBeInTheDocument();
    expect(screen.getByText("exit code: 1")).toBeInTheDocument();
  });

  it("renders ls entries with folders and files", () => {
    const node = renderBuiltinResult("ls", "src/\nREADME.md\n");
    renderWithProviders(<>{node}</>);
    expect(screen.getByText("src")).toBeInTheDocument();
    expect(screen.getByText("README.md")).toBeInTheDocument();
  });

  it("returns null for tools without a custom view", () => {
    expect(renderBuiltinResult("grep", "x")).toBeNull();
  });
});
