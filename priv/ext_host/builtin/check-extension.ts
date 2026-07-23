// Built-in extension: a syntax checker for extension files.
//
// It ships with the app and loads only when a host is already running for the
// user's own extensions (so it costs nothing in a session with no extensions).
// It also doubles as a minimal reference — a single default-exported factory
// that registers one tool and uses `longpi.run` + a host capability.

export default function (longpi: any) {
  longpi.registerTool({
    name: "check_extension",
    description:
      "Check an extension file's TypeScript/TSX syntax with the same parser that loads extensions. " +
      "Run it after writing or editing an extension to catch errors before relying on it.",
    parameters: {
      type: "object",
      properties: {
        path: {
          type: "string",
          description: "Path to the extension file (.ts or .tsx), relative to the workspace or absolute.",
        },
      },
      required: ["path"],
    },
    async execute(args: { path: string }) {
      const path = String(args.path || "").trim();
      if (!path) return "Provide the path to an extension file.";

      const { status, stdout, stderr } = await longpi.run("cat", [path]);
      if (status !== 0) return `Cannot read ${path}: ${String(stderr).trim() || `exit ${status}`}`;

      const jsx = path.endsWith(".tsx") || path.endsWith(".jsx");
      const result = longpi.checkSyntax(stdout, { jsx });
      if (result.ok) return `OK — ${path} parses cleanly.`;
      return `Syntax error in ${path}:\n${result.error}`;
    },
  });
}
