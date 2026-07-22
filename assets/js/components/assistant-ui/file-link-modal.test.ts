import { describe, expect, it } from "vitest";

import { hrefToPath, isLocalFileHref } from "./file-link-modal";

describe("isLocalFileHref", () => {
  it("treats absolute paths as local files", () => {
    expect(isLocalFileHref("/home/mj/dev/app/lib/foo.ex")).toBe(true);
  });

  it("treats URL-encoded absolute paths as local files", () => {
    expect(
      isLocalFileHref("/home/mj/dev/%E6%B5%AA%E6%B7%98%E6%B2%99/x_v1.py"),
    ).toBe(true);
  });

  it("treats relative paths as local files (resolved against cwd)", () => {
    expect(isLocalFileHref("lib/longpi/agent/session.ex")).toBe(true);
  });

  it("treats file:// URLs as local files", () => {
    expect(isLocalFileHref("file:///home/mj/notes.txt")).toBe(true);
  });

  it("does not intercept http(s), mailto, or anchors", () => {
    expect(isLocalFileHref("https://example.com/home/page")).toBe(false);
    expect(isLocalFileHref("http://example.com")).toBe(false);
    expect(isLocalFileHref("mailto:a@b.c")).toBe(false);
    expect(isLocalFileHref("#section")).toBe(false);
  });

  it("treats same-origin URLs as local files (sanitizer-resolved hrefs)", () => {
    expect(isLocalFileHref(`${window.location.origin}/lib/foo.ex`)).toBe(true);
  });
});

describe("hrefToPath", () => {
  it("decodes percent-encoded paths", () => {
    expect(hrefToPath("/home/mj/%E7%AD%96%E7%95%A5.py")).toBe("/home/mj/策略.py");
  });

  it("strips the file:// scheme", () => {
    expect(hrefToPath("file:///home/mj/notes.txt")).toBe("/home/mj/notes.txt");
  });

  it("leaves undecodable input untouched", () => {
    expect(hrefToPath("/tmp/100%_done.txt")).toBe("/tmp/100%_done.txt");
  });

  it("strips the page origin from sanitizer-resolved hrefs", () => {
    expect(hrefToPath(`${window.location.origin}/lib/foo.ex`)).toBe("/lib/foo.ex");
  });
});
