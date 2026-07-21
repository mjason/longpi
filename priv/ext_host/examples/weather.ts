// Example longpi extension: a minimal `get_weather` tool with no API key.
//
// The smallest useful extension — a single tool that calls a public endpoint.
// Copy to `<cwd>/.longpi/extensions/weather.ts` or `~/.longpi/extensions/`,
// then run `/reload`.

export default function (longpi) {
  longpi.registerTool({
    name: "get_weather",
    label: "Weather",
    description: "Returns the current weather for a city.",
    parameters: {
      type: "object",
      properties: { city: { type: "string", description: "City name." } },
      required: ["city"],
    },
    async execute(args, _ctx) {
      const res = await fetch(`https://wttr.in/${encodeURIComponent(args.city)}?format=3`);
      return await res.text();
    },
  });

  // An optional slash command surfaces in the composer's "/" menu.
  longpi.registerCommand("weather-help", {
    description: "Explain the weather tool",
    execute() {
      return "Ask me the weather for any city, e.g. \"what's the weather in Tokyo?\".";
    },
  });
}
