# longpi extensions

longpi's agent loop runs in Elixir, but its capabilities can be extended with
JavaScript or TypeScript. Each conversation gets an **embedded QuickJS host**
(native, via rquickjs — nothing to install on the machine); it loads your
extensions and runs their tools, with capabilities (`fetch`, `crypto`,
`console`, and `longpi.run`) provided as host functions.

## Where extensions live

Discovered per session, project-local winning over global on name conflicts
(same precedence as pi):

- **Project:** `<cwd>/.longpi/extensions/` — extensions for one workspace.
- **Global:** `~/.longpi/extensions/` — shared across every conversation.

One level deep in an `extensions/` dir: a `*.ts` / `*.js` / `*.mjs` file, or a
subdirectory with an `index.ts` / `index.js`. TypeScript is preferred (types are
stripped automatically); plain JavaScript works too. Newly written or edited
files are picked up automatically — the system handles reloading for you.

## The runtime (read this before writing code)

Each conversation gets an embedded **QuickJS** engine. Write modern TypeScript
(ES2020+: modules, async/await, optional chaining, classes) — type annotations
are stripped automatically before the code runs, so author in `.ts` for the
type hints. Plain JavaScript works too.

Available globals and host capabilities:

- `fetch(url, options)` — HTTP(S), brokered by the app (timeouts and size
  limits enforced outside the sandbox). `options`: `method`, `headers`, `body`
  (a string). The response has `ok`, `status`, `statusText`,
  `headers.get(name)`, `await res.text()`, `await res.json()`, and for binary
  payloads `await res.arrayBuffer()` / `await res.bytes()`.
- `process.env.<NAME>` — secrets stored under Settings → Extensions → Secrets,
  injected fresh on every call; keys belong there, code reads them from the
  environment.
- `await longpi.run(cmd, args, opts)` — run a program installed on the machine
  (python3, a Go binary, git, …) and get `{ status, stdout, stderr }`. It's
  async, so `await` it.
- `console.log(...)` / `console.error(...)` — go to the server log, for
  debugging.
- Standard globals are present: `crypto.randomUUID()`, `TextEncoder` /
  `TextDecoder`, `structuredClone`, `atob` / `btoa`, `setTimeout` /
  `setInterval` / `clearTimeout` / `queueMicrotask`.

Reach for `longpi.run` whenever a task needs the filesystem, an external
library, or a system tool: it delegates to a real program on the machine, which
is the escape hatch when JavaScript and the globals above are not enough.

## Writing an extension

An extension is a module with a **default-exported factory** that receives the
`longpi` API and registers capabilities:

```ts
export default function (longpi: any) {
  longpi.registerTool({
    name: "my_tool",                 // snake_case, unique
    description: "What the model reads to decide when to use this.",
    parameters: {                     // JSON Schema for the arguments
      type: "object",
      properties: { text: { type: "string", description: "Input text." } },
      required: ["text"],
    },
    async execute(args: { text: string }, ctx: { cwd: string }) {  // ctx.cwd = the workspace
      const res = await fetch("https://api.example.com", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ q: args.text }),
      });
      return await res.text();        // return a string (or {content:[{type:"text",text}]})
    },
  });

  longpi.registerCommand("hello", {
    description: "A /hello slash command",
    execute: (arg) => `hi: ${arg}`,
  });

  longpi.on("turn_start", (payload) => {
    // fire-and-forget lifecycle hook
  });
}
```

`longpi.on(event, handler)` observes agent activity (fire-and-forget; handlers
can be async). Available events:

- `turn_start` / `turn_end` — a turn began / finished (`turn_end` payload has `reason`).
- `tool_call` — a tool is being run: `{ id, name, args }`.
- `tool_result` — a tool finished: `{ id, name, content, error }`.

See `examples/web-search.ts` for the canonical API-with-secret pattern.

## Custom result UI (optional)

A tool can render a rich result instead of plain text — authored in **TSX**
(name the extension `.tsx`), compiled to a serializable tree the app renders
with its own components. Nothing runs in the browser; it's data mapped to a
fixed component whitelist.

Return `longpi.ui({ text, view })` — **both halves, explicitly**:

- `text` — what the **model** reads. Write the concise, authoritative summary
  yourself; the model never sees the UI tree.
- `view` — the JSX the **user** sees, rendered by the app.

```tsx
export default function (longpi: any) {
  longpi.registerTool({
    name: "home_status",
    description: "Show a home-status table.",
    parameters: { type: "object", properties: {} },
    execute() {
      const rows = [["温度", "unavailable"], ["湿度", "45%"]];
      return longpi.ui({
        text: `2 sensors — ${rows.map((r) => r.join(": ")).join("; ")}`,
        view: (
          <Card title="家庭状态">
            <Table columns={["实体", "状态"]} rows={rows} />
          </Card>
        ),
      });
    },
  });
}
```

The model reads `text` and the user sees `view`; the two are independent, so a
table can render richly for the user while the model gets a clean one-line
summary. (Return a plain string when you don't need a custom UI.)

Available `view` components (unknown components degrade to their inner text):

- `Stack` / `Row` (props: `gap` = sm|md|lg) — vertical / horizontal layout
- `Text` (props: `muted`, `bold`, `small`), `Heading`, `Code`
- `Badge` (props: `text`, `tone` = success|danger|warning)
- `Stat` (props: `label`, `value`) — a labeled number
- `Card` (props: `title`)
- `Table` (props: `columns: string[]`, `rows: string[][]`)

See `examples/ui-dashboard.tsx` for a complete UI tool (data + view, with an
error branch).

## Checklist for a good extension

1. One file, default-exported factory, tools registered with clear
   descriptions and JSON-Schema parameters.
2. Read secrets from `process.env`, and when one is missing return a short
   actionable message ("set FOO under Settings → Extensions → Secrets").
3. Return text. Keep outputs concise — they land in the model's context.
4. Errors: let exceptions propagate (the host reports them as tool errors)
   or return a clear failure string.
5. After writing or editing the file, run the `check_extension` tool on its
   path to confirm it parses before relying on it.
