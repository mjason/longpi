# longpi extensions

longpi's agent loop runs in Elixir, but its capabilities can be extended with
JavaScript. Each conversation gets a **sandboxed WebAssembly extension host**
(QuickJS running under wasmtime, embedded in the app — nothing to install on
the machine); it loads your extensions and executes their tools, with the
Elixir brain driving the agent loop over a frame protocol.

## Where extensions live

Discovered per session, project-local winning over global on name conflicts
(same precedence as pi):

- **Project:** `<cwd>/.longpi/extensions/` — extensions for one workspace.
- **Global:** `~/.longpi/extensions/` — shared across every conversation.

One level deep in an `extensions/` dir: a `*.js` / `*.mjs` file, or a
subdirectory with an `index.js`. Newly written or edited files are picked up
automatically — the system handles reloading for you.

## The runtime (read this before writing code)

Extensions run in **QuickJS**, not Node or a browser. Write plain modern
JavaScript (ES2020+ syntax: modules, async/await, optional chaining are all
fine). What you have:

- `fetch(url, options)` — HTTP(S), brokered by the app (timeouts and size
  limits enforced outside the sandbox). `options`: `method`, `headers`,
  `body`. The response has `ok`, `status`, `headers.get(name)`,
  `await res.text()`, `await res.json()`.
- `process.env.<NAME>` — secrets stored under Settings → Extensions →
  Secrets, injected fresh on every call; keys belong there, code reads them
  from the environment.
- `longpi.run(cmd, args, opts)` — run a program installed on the machine
  (python3, a Go binary, git, …) and get `{ status, stdout, stderr }`.
  This is the escape hatch when JavaScript alone is not enough.
- `console.log(...)` — goes to the server log (stderr), for debugging.

That list is the complete runtime: plain QuickJS plus those four host
capabilities. Anything from the Node/npm world (`fs`, `Buffer`, `require`,
package imports), TypeScript type annotations, and timers live outside the
sandbox — when a task calls for them, delegate to a real program on the
system with `longpi.run`. A `.ts` filename loads as long as its content is
plain JavaScript.

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
