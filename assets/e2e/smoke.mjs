// E2E smoke: launch a real browser against a running server and assert the
// app actually works — the layer unit tests can't see (join wire shape,
// layout height chain, uncaught page errors). Run:
//   BASE_URL=http://127.0.0.1:4050 node e2e/smoke.mjs
import { chromium } from "playwright";

const BASE = process.env.BASE_URL ?? "http://127.0.0.1:4050";
const failures = [];
const note = (ok, label) => {
  console.log(`${ok ? "✓" : "✗"} ${label}`);
  if (!ok) failures.push(label);
};

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });

// Any uncaught page error or console.error fails the smoke — this is exactly
// how the v0.1.67 "(s ?? []) is not iterable" join crash would have been caught.
const pageErrors = [];
page.on("pageerror", (err) => pageErrors.push(`pageerror: ${err.message}`));
page.on("console", (msg) => {
  if (msg.type() === "error") pageErrors.push(`console.error: ${msg.text()}`);
});

await page.goto(BASE, { waitUntil: "networkidle" });
await page.waitForTimeout(2000);

note((await page.title()).includes("Longpi"), "page title");
note(await page.locator("textarea").first().isVisible().catch(() => false), "composer visible");

for (const [w, h, label] of [[1440, 900, "desktop"], [390, 844, "mobile"]]) {
  await page.setViewportSize({ width: w, height: h });
  await page.waitForTimeout(500);
  const m = await page.evaluate(() => ({
    v: document.documentElement.scrollHeight <= window.innerHeight + 2,
    h: document.documentElement.scrollWidth <= window.innerWidth + 2,
  }));
  note(m.v, `${label}: no page-level vertical scroll`);
  note(m.h, `${label}: no page-level horizontal scroll`);
}

note(pageErrors.length === 0, `no page errors (${pageErrors.length})`);
for (const e of pageErrors.slice(0, 5)) console.log("   " + e);

await browser.close();
if (failures.length > 0) {
  console.error(`\nSMOKE FAILED: ${failures.length} check(s)`);
  process.exit(1);
}
console.log("\nSMOKE OK");
