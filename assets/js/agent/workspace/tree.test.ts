import { describe, expect, it } from "vitest";

import { buildTreeRows, joinPath, type DirListing } from "./tree";
import { buildGitDecorations } from "./gitDecorations";
import type { GitStatus } from "./api";

const entry = (name: string, type: "directory" | "file" = "file") => ({
  name,
  type,
  symlink: false,
  size: 1,
});

const listing = (path: string, entries: ReturnType<typeof entry>[]): DirListing => ({
  path,
  parent: "/",
  entries,
});

describe("buildTreeRows", () => {
  const root = "/w";
  const listings = new Map<string, DirListing>([
    ["/w", listing("/w", [entry("src", "directory"), entry(".env"), entry("a.txt")])],
    ["/w/src", listing("/w/src", [entry("main.ts")])],
  ]);

  it("renders only loaded+expanded levels, dirs indented by depth", () => {
    const collapsed = buildTreeRows(root, listings, new Set(), false);
    expect(collapsed.map((r) => (r.kind === "note" ? r.note : r.path))).toEqual([
      "/w/src",
      "/w/a.txt",
      "hidden",
    ]);

    const expanded = buildTreeRows(root, listings, new Set(["/w/src"]), false);
    const src = expanded.find((r) => r.kind === "file" && r.path === "/w/src/main.ts");
    expect(src && "depth" in src && src.depth).toBe(1);
  });

  it("hidden files are a client-side toggle with an honest count", () => {
    const shown = buildTreeRows(root, listings, new Set(), true);
    expect(shown.some((r) => r.kind === "file" && r.path === "/w/.env")).toBe(true);
    expect(shown.some((r) => r.kind === "note" && r.note === "hidden")).toBe(false);
  });

  it("an expanded empty directory says so", () => {
    const withEmpty = new Map(listings).set("/w/src", listing("/w/src", []));
    const rows = buildTreeRows(root, withEmpty, new Set(["/w/src"]), false);
    expect(rows.some((r) => r.kind === "note" && r.note === "empty")).toBe(true);
  });

  it("joinPath never doubles the separator", () => {
    expect(joinPath("/a/", "b")).toBe("/a/b");
    expect(joinPath("/a", "b")).toBe("/a/b");
  });
});

describe("buildGitDecorations", () => {
  const status: GitStatus = {
    repo: true,
    root: "/w",
    branch: "main",
    files: [
      { path: "src/deep/mod.ts", status: "M", staged: false, unstaged: true },
      { path: "src/added.ts", status: "A", staged: true, unstaged: false },
      { path: "gone.ts", status: "D", staged: false, unstaged: true },
      { path: "fresh.ts", status: "??", staged: false, unstaged: true },
    ],
  };

  it("labels files and colors ancestors with the STRONGEST descendant tone", () => {
    const map = buildGitDecorations(status);
    expect(map.get("/w/src/deep/mod.ts")).toEqual({ label: "M", tone: "modified" });
    expect(map.get("/w/fresh.ts")).toEqual({ label: "?", tone: "untracked" });
    // src contains an add (1) and a modification (3) — modification wins.
    expect(map.get("/w/src")?.tone).toBe("modified");
    expect(map.get("/w/src/deep")?.tone).toBe("modified");
    // Ancestors carry tone only, no letter.
    expect(map.get("/w/src")?.label).toBe("");
  });

  it("is empty outside a repository", () => {
    expect(buildGitDecorations({ repo: false, root: null, branch: null, files: [] }).size).toBe(0);
  });
});
