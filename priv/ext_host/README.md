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

One level deep in an `extensions/` dir: a `*.js` / `*.mjs` file, or a
subdirectory with an `index.js`. Newly written or edited files are picked up
automatically — the system handles reloading for you.

## The runtime (read this before writing code)

Each conversation gets an embedded **QuickJS** engine. Write modern JavaScript
or TypeScript (ES2020+: modules, async/await, optional chaining, classes).
TypeScript type annotations are stripped automatically before the code runs.

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

```js
export default function (longpi) {
  longpi.registerTool({
    name: "my_tool",                 // snake_case, unique
    description: "What the model reads to decide when to use this.",
    parameters: {                     // JSON Schema for the arguments
      type: "object",
      properties: { text: { type: "string", description: "Input text." } },
      required: ["text"],
    },
    async execute(args, ctx) {        // ctx.cwd = the conversation's workspace
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

See `examples/web-search.js` for the canonical API-with-secret pattern.

## Checklist for a good extension

1. One file, default-exported factory, tools registered with clear
   descriptions and JSON-Schema parameters.
2. Read secrets from `process.env`, and when one is missing return a short
   actionable message ("set FOO under Settings → Extensions → Secrets").
3. Return text. Keep outputs concise — they land in the model's context.
4. Errors: let exceptions propagate (the host reports them as tool errors)
   or return a clear failure string.
