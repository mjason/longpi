// Pure tree logic for the file panel (dala's fileDrawer/tree.ts semantics):
// the server returns one directory level at a time; the client folds the
// loaded levels + the expanded set into a flat row list that drives both
// rendering and keyboard navigation.

export type DirEntry = {
  name: string;
  type: "directory" | "file" | "other";
  symlink: boolean;
  size: number;
};

export type DirListing = {
  path: string;
  parent: string | null;
  entries: DirEntry[];
};

export type TreeRow =
  | { kind: "dir" | "file"; path: string; entry: DirEntry; depth: number; parentDir: string }
  | { kind: "note"; id: string; note: "hidden" | "empty"; count: number; depth: number };

export function joinPath(dir: string, name: string): string {
  return dir.endsWith("/") ? `${dir}${name}` : `${dir}/${name}`;
}

/**
 * Flattens the loaded tree into rows. Hidden (dot) entries are filtered
 * CLIENT-side so the toggle needs no refetch; a note row keeps the count
 * honest, and empty directories say so instead of rendering nothing.
 */
export function buildTreeRows(
  rootPath: string,
  listings: Map<string, DirListing>,
  expanded: Set<string>,
  showHidden: boolean,
): TreeRow[] {
  const rows: TreeRow[] = [];

  const walk = (dirPath: string, depth: number) => {
    const listing = listings.get(dirPath);
    if (!listing) return;

    const visible = listing.entries.filter((e) => showHidden || !e.name.startsWith("."));
    const hiddenCount = listing.entries.length - visible.length;

    for (const entry of visible) {
      const path = joinPath(dirPath, entry.name);
      const kind = entry.type === "directory" ? "dir" : "file";
      rows.push({ kind, path, entry, depth, parentDir: dirPath });
      if (kind === "dir" && expanded.has(path)) walk(path, depth + 1);
    }

    if (hiddenCount > 0) {
      rows.push({ kind: "note", id: `${dirPath}:hidden`, note: "hidden", count: hiddenCount, depth });
    } else if (listing.entries.length === 0) {
      rows.push({ kind: "note", id: `${dirPath}:empty`, note: "empty", count: 0, depth });
    }
  };

  walk(rootPath, 0);
  return rows;
}
