import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

// Minimal vitest setup for the frontend. The project's .tsx is transformed
// with the automatic JSX runtime (matching tsconfig's "jsx": "react-jsx"),
// which vitest applies to .tsx out of the box. Aliases mirror tsconfig paths
// so imported modules resolve the same way the esbuild bundle does. jsdom is
// the default env because a few units render React to a string (model icons)
// or transitively import component trees.
export default defineConfig({
  resolve: {
    alias: {
      "@/": `${fileURLToPath(new URL("./js/", import.meta.url))}`,
      phoenix: fileURLToPath(
        new URL("../deps/phoenix/assets/js/phoenix/index.js", import.meta.url),
      ),
    },
  },
  test: {
    environment: "jsdom",
    include: ["js/**/*.test.{ts,tsx}"],
    setupFiles: ["./js/test/setup.ts"],
    globals: false,
  },
});
