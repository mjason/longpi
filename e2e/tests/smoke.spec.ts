import { test, expect } from "@playwright/test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, basename } from "node:path";

// A fresh workspace dir per run so the project tree is isolated from existing
// conversations. cwd isn't validated server-side, but a real dir keeps the
// extension host happy.
function freshWorkspace() {
  const dir = mkdtempSync(join(tmpdir(), "longpi-e2e-"));
  return { dir, name: basename(dir) };
}

async function createConversation(page, cwd: string) {
  await page.getByRole("button", { name: "New conversation" }).first().click();
  await page.getByPlaceholder("/path/to/workspace").fill(cwd);
  const model = page.getByPlaceholder("provider:model");
  if (!(await model.inputValue())) await model.fill("openai:gpt-5.4");
  await page.getByRole("button", { name: "Create" }).click();
}

test("sidebar shows the projects tree", async ({ page }) => {
  await page.goto("/");
  await expect(page.getByText("Longpi").first()).toBeVisible();
  await expect(page.getByText("PROJECTS")).toBeVisible();
});

test("create a conversation and it appears grouped under its project", async ({ page }) => {
  const ws = freshWorkspace();
  await page.goto("/");
  await createConversation(page, ws.dir);
  // Folder toggle carries title={cwd}; the project appears in the tree.
  await expect(page.locator(`button[title="${ws.dir}"]`)).toBeVisible();
});

test("delete a project persists across reload (cascade delete)", async ({ page }) => {
  const ws = freshWorkspace();
  await page.goto("/");
  await createConversation(page, ws.dir);

  const folder = page.locator(`button[title="${ws.dir}"]`);
  await expect(folder).toBeVisible();

  // Right-click the folder → context menu → Delete project (auto-accept confirm).
  page.on("dialog", (d) => d.accept());
  await folder.click({ button: "right" });
  await page.getByRole("button", { name: "Delete project" }).click();

  await expect(page.locator(`button[title="${ws.dir}"]`)).toHaveCount(0);

  // The real test: reload from the DB — a failed (non-persisted) delete would
  // bring the project back.
  await page.reload();
  await expect(page.locator(`button[title="${ws.dir}"]`)).toHaveCount(0);
});

test("composer model picker lists enabled models", async ({ page }) => {
  const ws = freshWorkspace();
  await page.goto("/");
  await createConversation(page, ws.dir);
  await page.locator('[data-slot="model-selector-trigger"]').click();
  const content = page.locator('[data-slot="model-selector-content"]');
  await expect(content).toBeVisible();
  await expect(content.getByText("gpt-5.4", { exact: false }).first()).toBeVisible();
});

test("providers management screen renders the editor", async ({ page }) => {
  await page.goto("/manage/providers");
  await expect(page.getByText("Providers").first()).toBeVisible();
  await expect(page.getByPlaceholder(/base URL/i).first()).toBeVisible();
});
