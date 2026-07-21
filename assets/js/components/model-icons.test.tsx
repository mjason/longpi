import { renderToStaticMarkup } from "react-dom/server";
import type { ReactElement } from "react";
import { describe, expect, it } from "vitest";
import { modelIcon } from "./model-icons";

/** Render a model icon to its inlined SVG string (or "" for none). */
function svg(spec: string, label?: string | null): string {
  const node = modelIcon(spec, label);
  if (node == null) return "";
  return renderToStaticMarkup(node as ReactElement);
}

describe("modelIcon", () => {
  // The vendor is inferred from the model NAME, not the provider prefix.
  const cases: [string, string][] = [
    ["gpt-5.4", "OpenAI"],
    ["deepseek-v4-pro", "DeepSeek"],
    ["doubao-seed-2.0-code", "Doubao"],
    ["glm-5.2", "ChatGLM"],
    ["minimax-m2", "Minimax"],
    ["kimi-k2", "Kimi"],
    ["gemini-x", "Gemini"],
    ["grok-x", "Grok"],
    ["llama-x", "Meta"],
    ["qwen-x", "Qwen"],
    ["claude-x", "Claude"],
  ];

  it.each(cases)("maps %s to the %s brand mark", (spec, brandTitle) => {
    const markup = svg(spec);
    expect(markup).toContain("<svg");
    expect(markup).toContain(`<title>${brandTitle}</title>`);
  });

  it("returns undefined for an unknown model family", () => {
    expect(modelIcon("totally-made-up-model")).toBeUndefined();
    expect(svg("totally-made-up-model")).toBe("");
  });

  it("infers the vendor from the name, ignoring an openai: gateway prefix", () => {
    // Everything is served via one OpenAI-compatible gateway, so a
    // "openai:claude-x" spec must still resolve to Claude, not OpenAI.
    expect(svg("openai:claude-x")).toContain("<title>Claude</title>");
    expect(svg("openai:deepseek-v4")).toContain("<title>DeepSeek</title>");
  });

  it("prefers the label over the spec when both are present", () => {
    // label wins: a claude label on a gpt spec resolves to Claude.
    expect(svg("openai:gpt-5.4", "claude-x")).toContain("<title>Claude</title>");
    // and vice versa — a gpt label on a claude spec resolves to OpenAI.
    expect(svg("anthropic:claude-x", "gpt-5.4")).toContain("<title>OpenAI</title>");
  });

  it("falls back to the spec when the label is null/empty", () => {
    expect(svg("openai:gpt-5.4", null)).toContain("<title>OpenAI</title>");
    expect(svg("openai:gpt-5.4", "")).toContain("<title>OpenAI</title>");
  });
});
