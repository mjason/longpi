import { describe, expect, it } from "vitest";
import { DICTIONARIES } from "./i18n";

describe("i18n dictionaries", () => {
  it("zh covers exactly the same keys as en", () => {
    const en = Object.keys(DICTIONARIES.en).sort();
    const zh = Object.keys(DICTIONARIES.zh).sort();
    expect(zh).toEqual(en);
  });

  it("no dictionary value is empty", () => {
    for (const lang of ["en", "zh"] as const) {
      for (const [key, value] of Object.entries(DICTIONARIES[lang])) {
        expect(value.trim(), `${lang}:${key}`).not.toBe("");
      }
    }
  });
});
