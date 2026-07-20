# longpi extensions

longpi's agent loop runs in Elixir, but its capabilities can be extended with
TypeScript, mirroring pi's extension model. A **Bun extension host**
(`host.ts`) is started per conversation for its working directory; it loads
your extensions and executes their tools, with the Elixir brain driving the
agent loop over an IPC boundary.

## Where extensions live

Discovered per session, project-local winning over global on name conflicts
(same precedence as pi):

- **Project:** `<cwd>/.longpi/extensions/` — extensions for one workspace.
- **Global:** `~/.longpi/extensions/` — shared across every conversation.

One level deep in an `extensions/` dir: a `*.ts` / `*.js` file, a subdirectory
with an `index.ts`, or a **package** subdirectory (a `package.json` with a
`"pi": { "extensions": [...] }` manifest — for multi-file extensions that pull
in dependencies).

Requires `bun` on the PATH. If Bun isn't installed, sessions run with just the
seven built-in tools.

## Packages (installed with Bun)

Extensions can also be distributed as packages and installed with `bun install`
(npm, git, or local). List them in `packages.json` — global
`~/.longpi/packages.json` and/or project `<cwd>/.longpi/packages.json`:

```json
{
  "packages": {
    "my-tools": "^1.2.0",
    "cool-ext": "github:someone/cool-ext",
    "local-ext": "file:/abs/path/to/pkg"
  }
}
```

Each entry is `"<local-name>": "<spec>"`. On session start the host runs
`bun install` into a managed dir (`~/.longpi/packages/` or `<cwd>/.longpi/packages/`,
re-installing only when the set changes), then loads each package's
`"pi": { "extensions": [...] }` manifest. Package tools have the **lowest**
precedence — a global- or project-dir extension of the same name overrides them.

## Writing an extension

An extension is a module with a **default-exported factory** that receives the
`pi` API and registers capabilities. MVP surface: `registerTool`.

```ts
// .longpi/extensions/weather.ts
export default function (pi) {
  pi.registerTool({
    name: "get_weather",
    label: "Weather",
    description: "Returns the current weather for a city.",
    // JSON Schema for the arguments the model must supply.
    parameters: {
      type: "object",
      properties: { city: { type: "string" } },
      required: ["city"],
    },
    // Runs in Bun — use any Bun/Node API (fetch, fs, spawn, ...).
    async execute(args, ctx) {
      // ctx.cwd is the session's working directory.
      const res = await fetch(`https://wttr.in/${args.city}?format=3`);
      return await res.text();
      // Or return { content: [{ type: "text", text: "..." }] } like pi.
    },
  });
}
```

The tool appears alongside the built-ins in the model's tool list; when the
model calls it, `execute` runs in the Bun host and its text is returned to the
model. An extension tool with the same name as a built-in **overrides** it.

## Self-evolution

The agent can write a new `.ts` file into `.longpi/extensions/` with its
built-in `write` tool, then a reload hot-loads it — the Bun host re-imports the
directory and the new tool becomes available with no restart.
