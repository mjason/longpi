// Example longpi extension: a `web_search` tool backed by the Tavily API.
//
// Copy this to `<cwd>/.longpi/extensions/web-search.ts` (project-local) or
// `~/.longpi/extensions/web-search.ts` (global) — it hot-reloads automatically,
// no /reload needed. Add a TAVILY_API_KEY secret under Settings → Extensions →
// Secrets (stored in the app db and injected into the host on every call — no
// shell `export` needed).
//
// This is the canonical pattern for an extension that calls an external API
// with a secret key: read the key from `process.env`, fail clearly when it is
// missing, and return the result as text.

export default function (longpi) {
  longpi.registerTool({
    name: "web_search",
    label: "Web search",
    description:
      "Search the web and return relevant results (title, url, snippet) for a query. " +
      "Use for current events, documentation lookups, and facts not in the workspace.",
    parameters: {
      type: "object",
      properties: {
        query: { type: "string", description: "The search query." },
        max_results: {
          type: "integer",
          description: "How many results to return (1-10).",
          default: 5,
        },
      },
      required: ["query"],
    },
    async execute(args, _ctx) {
      const apiKey = process.env.TAVILY_API_KEY;
      if (!apiKey) {
        return "web_search is not configured: add a TAVILY_API_KEY secret in Settings → Extensions.";
      }

      const res = await fetch("https://api.tavily.com/search", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          api_key: apiKey,
          query: args.query,
          max_results: Math.min(Math.max(args.max_results ?? 5, 1), 10),
          search_depth: "basic",
        }),
      });

      if (!res.ok) {
        return `web_search failed: Tavily responded ${res.status} ${res.statusText}`;
      }

      const data = await res.json();
      const results = (data.results ?? []) as Array<{
        title: string;
        url: string;
        content: string;
      }>;

      if (results.length === 0) return `No results for "${args.query}".`;

      return results
        .map((r, i) => `${i + 1}. ${r.title}\n   ${r.url}\n   ${r.content}`)
        .join("\n\n");
    },
  });
}
