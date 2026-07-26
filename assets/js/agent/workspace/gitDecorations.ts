// Git badges overlaid on the file tree (dala's gitDecorations.ts): each
// changed file gets a one-letter badge, and every ancestor directory up to
// the repo root inherits the STRONGEST descendant tone so a collapsed
// folder still signals what's inside.

import type { GitStatus } from "./api";

export type GitTone = "added" | "modified" | "deleted" | "renamed" | "untracked" | "conflict";

export type GitDecoration = { label: string; tone: GitTone };

// Strength order (dala's): a deletion outweighs a modification outweighs an
// add; conflicts trump everything.
const PRIORITY: Record<GitTone, number> = {
  added: 1,
  renamed: 2,
  untracked: 2,
  modified: 3,
  deleted: 4,
  conflict: 5,
};

/** A porcelain `XY` status → its badge letter + tone. Shared by the tree
 * decorations and the git-panel file rows so the mapping has one home. */
export function toneFor(status: string): GitDecoration {
  if (status.includes("U")) return { label: "U", tone: "conflict" };
  if (status === "??") return { label: "?", tone: "untracked" };
  if (status.includes("D")) return { label: "D", tone: "deleted" };
  if (status.includes("R")) return { label: "R", tone: "renamed" };
  if (status.includes("A")) return { label: "A", tone: "added" };
  return { label: "M", tone: "modified" };
}

/** Absolute path → decoration, for every changed file AND its ancestors. */
export function buildGitDecorations(status: GitStatus): Map<string, GitDecoration> {
  const map = new Map<string, GitDecoration>();
  if (!status.repo || !status.root) return map;

  for (const file of status.files) {
    const decoration = toneFor(file.status);
    const abs = `${status.root}/${file.path}`;
    map.set(abs, decoration);

    // Ancestors inherit the strongest descendant tone (no letter — the
    // letter is the file's own; ancestors show tone-colored names only).
    let dir = abs;
    while (dir.length > status.root.length) {
      dir = dir.slice(0, dir.lastIndexOf("/"));
      if (dir.length < status.root.length) break;
      const existing = map.get(dir);
      if (!existing || PRIORITY[decoration.tone] > PRIORITY[existing.tone]) {
        map.set(dir, { label: "", tone: decoration.tone });
      }
    }
  }

  return map;
}

/** Tailwind text color for a tone (soft palette, no hard reds on dark). */
export function toneClass(tone: GitTone): string {
  switch (tone) {
    case "added":
      return "text-emerald-600 dark:text-emerald-400";
    case "untracked":
      return "text-emerald-700 dark:text-emerald-300";
    case "renamed":
      return "text-sky-600 dark:text-sky-400";
    case "modified":
      return "text-amber-600 dark:text-amber-400";
    case "deleted":
      return "text-red-600 dark:text-red-400";
    case "conflict":
      return "text-fuchsia-600 dark:text-fuchsia-400";
  }
}
