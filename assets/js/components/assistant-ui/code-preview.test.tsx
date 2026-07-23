import { describe, expect, it } from "vitest";

import { langForFile } from "./code-preview";

describe("langForFile", () => {
  it("maps common source extensions", () => {
    expect(langForFile("home-assistant.tsx")).toBe("tsx");
    expect(langForFile("host.ex")).toBe("elixir");
    expect(langForFile("lib.rs")).toBe("rust");
    expect(langForFile("config.jsonc")).toBe("jsonc");
    expect(langForFile("run.sh")).toBe("shellscript");
    expect(langForFile("Dockerfile")).toBe("docker");
  });

  it("returns null for unknown files (falls back to plain text)", () => {
    expect(langForFile("notes.xyzabc")).toBeNull();
    expect(langForFile("no_extension")).toBeNull();
  });
});
