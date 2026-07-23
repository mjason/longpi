import { useEffect, useState } from "react";

// Syntax-highlighted read-only code view for the file preview dialog, powered
// by the same Shiki that Streamdown uses for markdown code fences. Loaded
// lazily (dynamic import + esbuild code splitting) so the main bundle stays
// lean; while loading — or for unknown languages — it falls back to the plain
// <pre> so content is always visible immediately.

/** File extension → Shiki language id. Anything else renders unhighlighted. */
const LANG_BY_EXT: Record<string, string> = {
  ts: "typescript",
  tsx: "tsx",
  js: "javascript",
  jsx: "jsx",
  mjs: "javascript",
  cjs: "javascript",
  ex: "elixir",
  exs: "elixir",
  heex: "elixir",
  eex: "elixir",
  rs: "rust",
  py: "python",
  rb: "ruby",
  go: "go",
  java: "java",
  c: "c",
  h: "c",
  cpp: "cpp",
  hpp: "cpp",
  cs: "csharp",
  php: "php",
  swift: "swift",
  kt: "kotlin",
  lua: "lua",
  json: "json",
  jsonc: "jsonc",
  yml: "yaml",
  yaml: "yaml",
  toml: "toml",
  xml: "xml",
  html: "html",
  css: "css",
  scss: "scss",
  md: "markdown",
  markdown: "markdown",
  sh: "shellscript",
  bash: "shellscript",
  zsh: "shellscript",
  fish: "fish",
  sql: "sql",
  graphql: "graphql",
  proto: "proto",
  dockerfile: "docker",
  diff: "diff",
  patch: "diff",
  vue: "vue",
  svelte: "svelte",
  zig: "zig",
  dart: "dart",
  tf: "terraform",
  nix: "nix",
  ini: "ini",
  conf: "ini",
};

export function langForFile(name: string): string | null {
  const base = name.toLowerCase().split("/").pop() ?? "";
  if (base === "dockerfile") return "docker";
  if (base === "makefile") return "make";
  const ext = base.includes(".") ? base.split(".").pop()! : "";
  return LANG_BY_EXT[ext] ?? null;
}

const plain = (content: string) => (
  <pre className="whitespace-pre-wrap break-all rounded-lg bg-muted/50 p-3 font-mono text-xs leading-relaxed">
    {content}
  </pre>
);

/** Highlights `content` for the file `name`; plain <pre> until ready / on miss. */
export function CodePreview({ name, content }: { name: string; content: string }) {
  const [html, setHtml] = useState<string | null>(null);
  const lang = langForFile(name);

  useEffect(() => {
    if (!lang) return;
    let cancelled = false;
    setHtml(null);
    import("shiki")
      .then(({ codeToHtml }) =>
        codeToHtml(content, {
          lang,
          themes: { light: "github-light", dark: "github-dark" },
        }),
      )
      .then((out) => !cancelled && setHtml(out))
      .catch(() => !cancelled && setHtml(null));
    return () => {
      cancelled = true;
    };
  }, [lang, content]);

  if (!lang || html === null) return plain(content);
  return (
    <div
      // Shiki emits its own <pre class="shiki"> with inline theme colors; the
      // dark-theme flip is handled in app.css via [data-theme=dark].
      className="code-preview overflow-x-auto rounded-lg text-xs leading-relaxed [&_pre]:whitespace-pre-wrap [&_pre]:break-all [&_pre]:rounded-lg [&_pre]:p-3"
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}
