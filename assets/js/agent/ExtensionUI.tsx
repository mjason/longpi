// Renders a serializable UI tree that an extension tool returned, mapping each
// node type to a vetted component from our design system. Nothing the extension
// sends is executed — it's plain data (produced by the sandbox's `h()` and
// oxc-compiled TSX) interpreted here into a fixed whitelist of components, so
// there's no code execution or arbitrary markup, only text into our own UI.
//
// Contract: a tool that called `longpi.ui({ text, view })` returns a string
// that parses to `{ __longpi_ui__: true, text, view }`, where `view` is a node
// `{ type, props, children }` (children are nodes or strings). We render `view`;
// `text` is what the model reads (handled server-side).

import type { ReactNode } from "react";

import { Badge } from "../components/ui/badge";
import { cn } from "../lib/utils";

const UI_ENVELOPE = "__longpi_ui__";

export type UINode = {
  type: string;
  props?: Record<string, unknown>;
  children?: Array<UINode | string | number | null>;
};

// Every thread re-render re-parses every tool result (both the "does this
// have a custom view?" probe and the actual render) — a big JSON.parse per
// result per frame. Results are immutable strings, so cache verdicts.
const parseCache = new Map<string, UINode | null>();
const PARSE_CACHE_MAX = 200;

/** Parses a tool-result string into a UI node, or null if it isn't a UI payload. */
export function parseExtensionUI(result: unknown): UINode | null {
  if (typeof result !== "string") return null;
  const trimmed = result.trim();
  if (!trimmed.startsWith("{") || !trimmed.includes(UI_ENVELOPE)) return null;

  const cached = parseCache.get(result);
  if (cached !== undefined) return cached;

  const node = parseUncached(trimmed);
  if (parseCache.size >= PARSE_CACHE_MAX) {
    const oldest = parseCache.keys().next().value;
    if (oldest !== undefined) parseCache.delete(oldest);
  }
  parseCache.set(result, node);
  return node;
}

function parseUncached(trimmed: string): UINode | null {
  try {
    const parsed = JSON.parse(trimmed);
    const view = parsed?.[UI_ENVELOPE] === true ? parsed.view : null;
    if (view && typeof view.type === "string") {
      return view as UINode;
    }
    return null;
  } catch {
    return null;
  }
}

// The tree is extension-authored data: a runaway generator can emit a huge or
// deeply recursive view. Cap both dimensions so one bad tool result can't
// freeze the tab (nodes past the caps degrade to a small notice).
const MAX_NODES = 500;
const MAX_DEPTH = 32;

export function ExtensionUI({ node }: { node: UINode }) {
  const budget = { nodes: MAX_NODES, truncated: false };
  const rendered = renderNode(node, "root", 0, budget);
  return (
    <>
      {rendered}
      {budget.truncated && (
        <div className="text-xs text-muted-foreground">(view truncated — too large)</div>
      )}
    </>
  );
}

type RenderBudget = { nodes: number; truncated: boolean };

function renderNode(
  node: UINode | string | number | null,
  key: string,
  depth: number,
  budget: RenderBudget,
): ReactNode {
  if (node === null || node === undefined) return null;
  if (typeof node === "string" || typeof node === "number") return node;

  if (budget.nodes <= 0 || depth >= MAX_DEPTH) {
    budget.truncated = true;
    return null;
  }
  budget.nodes -= 1;

  const renderer = REGISTRY[node.type];
  const children = (node.children ?? []).map((child, i) =>
    renderNode(child, `${key}.${i}`, depth + 1, budget),
  );
  const props = node.props ?? {};

  // An unknown type degrades to its children, so a newer extension still shows
  // its text on an older client instead of vanishing.
  if (!renderer) return <span key={key}>{children}</span>;
  return renderer(props, children, key);
}

type Renderer = (
  props: Record<string, unknown>,
  children: ReactNode[],
  key: string,
) => ReactNode;

const str = (v: unknown): string => (v == null ? "" : String(v));

const REGISTRY: Record<string, Renderer> = {
  Stack: (props, children, key) => (
    <div key={key} className={cn("flex flex-col", gap(props.gap))}>
      {children}
    </div>
  ),

  Row: (props, children, key) => (
    <div key={key} className={cn("flex flex-wrap items-center", gap(props.gap))}>
      {children}
    </div>
  ),

  Text: (props, children, key) => (
    <span
      key={key}
      className={cn(
        Boolean(props.muted) && "text-muted-foreground",
        Boolean(props.bold) && "font-medium",
        Boolean(props.small) && "text-xs",
      )}
    >
      {children}
    </span>
  ),

  Heading: (props, children, key) => (
    <div key={key} className="text-sm font-semibold text-foreground">
      {children}
    </div>
  ),

  Badge: (props, children, key) => {
    const tone = str(props.tone);
    const variant =
      tone === "success" || tone === "danger" || tone === "warning" ? "secondary" : "outline";
    return (
      <Badge
        key={key}
        variant={variant as "secondary" | "outline"}
        className={cn(
          "font-normal",
          tone === "success" && "text-emerald-600 dark:text-emerald-400",
          tone === "danger" && "text-red-600 dark:text-red-400",
          tone === "warning" && "text-amber-600 dark:text-amber-400",
        )}
      >
        {props.text != null ? str(props.text) : children}
      </Badge>
    );
  },

  Stat: (props, _children, key) => (
    <div
      key={key}
      className="rounded-lg px-3 py-2 ring-1 ring-black/[0.06] dark:ring-white/[0.08]"
    >
      <div className="text-lg font-semibold tabular-nums text-foreground">{str(props.value)}</div>
      <div className="mt-0.5 text-xs text-muted-foreground">{str(props.label)}</div>
    </div>
  ),

  Card: (props, children, key) => (
    <div
      key={key}
      className="space-y-2 rounded-lg p-3 ring-1 ring-black/[0.06] dark:ring-white/[0.08]"
    >
      {props.title != null && (
        <div className="text-sm font-medium text-foreground">{str(props.title)}</div>
      )}
      {children}
    </div>
  ),

  Code: (props, children, key) => (
    <pre
      key={key}
      className="overflow-x-auto rounded-md bg-muted/50 p-2.5 text-xs text-foreground/90"
    >
      <code>{children}</code>
    </pre>
  ),

  Table: (props, _children, key) => {
    const columns = Array.isArray(props.columns) ? (props.columns as unknown[]).map(str) : [];
    const rows = Array.isArray(props.rows) ? (props.rows as unknown[][]) : [];
    return (
      <div key={key} className="overflow-x-auto rounded-md ring-1 ring-black/[0.06] dark:ring-white/[0.08]">
        <table className="w-full text-xs">
          {columns.length > 0 && (
            <thead>
              <tr className="text-muted-foreground">
                {columns.map((col, i) => (
                  <th key={i} className="px-2.5 py-1.5 text-left font-medium">
                    {col}
                  </th>
                ))}
              </tr>
            </thead>
          )}
          <tbody>
            {rows.map((row, r) => (
              <tr key={r} className="border-t border-black/[0.05] dark:border-white/[0.06]">
                {(Array.isArray(row) ? row : [row]).map((cell, c) => (
                  <td key={c} className="px-2.5 py-1.5 align-top text-foreground/90">
                    {str(cell)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    );
  },
};

function gap(value: unknown): string {
  switch (value) {
    case "sm":
      return "gap-1.5";
    case "lg":
      return "gap-4";
    default:
      return "gap-2.5";
  }
}
