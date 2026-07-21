import { defineConfig, devices } from "@playwright/test";

// e2e runs against a running longpi dev server. Default targets the test
// server on PORT=4050 (never 4000/4004). Uses the system chromium to avoid
// downloading a Playwright browser build.
const BASE_URL = process.env.LONGPI_E2E_URL || "http://localhost:4050";

export default defineConfig({
  testDir: "./tests",
  timeout: 30_000,
  expect: { timeout: 8_000 },
  fullyParallel: false,
  workers: 1,
  retries: 0,
  use: {
    baseURL: BASE_URL,
    headless: true,
    launchOptions: {
      executablePath: process.env.CHROMIUM_BIN || "/usr/bin/chromium",
      args: ["--no-sandbox", "--disable-gpu"],
    },
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
});
