import {
  buildCSRFHeaders,
  clearProviderKey,
  createModel,
  destroyModel,
  destroyModelAlias,
  destroyProvider,
  destroyScheduledTask,
  listModelAliases,
  listModels,
  listProviders,
  listScheduledTasks,
  listSettings,
  putModelAlias,
  putProvider,
  putSetting,
  setProviderKey,
  updateModel,
  updateScheduledTask,
} from "../ash_rpc";

export type SettingsMap = Record<string, string>;

export const SETTING_KEYS = {
  systemPrompt: "system_prompt",
  defaultModel: "default_model",
  approvalLevel: "approval_level",
  compactionEnabled: "compaction_enabled",
  compactionRatio: "compaction_ratio",
} as const;

export const APPROVAL_LEVELS = [
  { id: "read_only", label: "Read-only", hint: "Only reads run automatically; writes and commands ask." },
  { id: "auto", label: "Auto", hint: "Reads and file edits run; bash commands ask." },
  { id: "full", label: "Full access", hint: "Everything runs automatically — no prompts." },
] as const;

export const toolDescKey = (name: string) => `tool_desc:${name}`;

export type ModelRow = {
  id: string;
  spec: string;
  label: string | null;
  enabled: boolean;
  position: number;
};

export type ToolCatalogEntry = {
  name: string;
  default_description: string;
  description: string;
};

export async function loadSettings(): Promise<SettingsMap> {
  const result = await listSettings({ fields: ["key", "value"], headers: buildCSRFHeaders() });
  if (!result.success) return {};
  const map: SettingsMap = {};
  for (const row of result.data) if (row.value != null) map[row.key] = row.value;
  return map;
}

export async function saveSetting(key: string, value: string): Promise<boolean> {
  const result = await putSetting({
    input: { key, value },
    fields: ["key"],
    headers: buildCSRFHeaders(),
  });
  return result.success;
}

export async function loadModels(): Promise<ModelRow[]> {
  const result = await listModels({
    fields: ["id", "spec", "label", "enabled", "position"],
    headers: buildCSRFHeaders(),
  });
  return result.success ? (result.data as ModelRow[]) : [];
}

export async function addModel(spec: string, label: string, position: number) {
  return createModel({
    input: { spec, label: label || null, position },
    fields: ["id"],
    headers: buildCSRFHeaders(),
  });
}

export async function setModel(id: string, changes: Partial<Pick<ModelRow, "label" | "enabled">>) {
  return updateModel({ identity: id, input: changes, fields: ["id"], headers: buildCSRFHeaders() });
}

export async function removeModel(id: string) {
  return destroyModel({ identity: id, headers: buildCSRFHeaders() });
}

// ── Model tiers (aliases) ──────────────────────────────────────────────
// Named tiers (poker: J = light/fast, Q = balanced, K = strongest, plus
// user-defined ones) that subagent roles reference instead of model specs.

export type ModelAliasRow = {
  id: string;
  name: string;
  spec: string;
  note: string | null;
  reasoningEffort: string | null;
};

/** The built-in tier names, always shown in the admin UI even when unmapped. */
export const BUILTIN_TIERS = ["J", "Q", "K"] as const;

/** Reasoning levels a tier can bundle; "" = inherit the session's setting. */
export const TIER_EFFORTS = ["", "minimal", "low", "medium", "high"] as const;

export async function loadModelAliases(): Promise<ModelAliasRow[]> {
  const result = await listModelAliases({
    fields: ["id", "name", "spec", "note", "reasoningEffort"],
    headers: buildCSRFHeaders(),
  });
  return result.success ? (result.data as ModelAliasRow[]) : [];
}

export async function saveModelAlias(
  name: string,
  spec: string,
  opts: { note?: string | null; reasoningEffort?: string | null } = {},
) {
  return putModelAlias({
    input: {
      name,
      spec,
      note: opts.note ?? null,
      reasoningEffort: opts.reasoningEffort ?? null,
    },
    fields: ["id"],
    headers: buildCSRFHeaders(),
  });
}

export async function removeModelAlias(id: string) {
  return destroyModelAlias({ identity: id, headers: buildCSRFHeaders() });
}

// ── Scheduled tasks (cron) ─────────────────────────────────────────────

export type ScheduledTaskRow = {
  id: string;
  conversationId: string;
  cron: string;
  task: string;
  enabled: boolean;
  lastRunAt: string | null;
};

export async function loadScheduledTasks(): Promise<ScheduledTaskRow[]> {
  const result = await listScheduledTasks({
    fields: ["id", "conversationId", "cron", "task", "enabled", "lastRunAt"],
    headers: buildCSRFHeaders(),
  });
  return result.success ? (result.data as ScheduledTaskRow[]) : [];
}

export async function setScheduledTask(
  id: string,
  changes: Partial<Pick<ScheduledTaskRow, "enabled" | "cron" | "task">>,
) {
  return updateScheduledTask({
    identity: id,
    input: changes,
    fields: ["id"],
    headers: buildCSRFHeaders(),
  });
}

export async function removeScheduledTask(id: string) {
  return destroyScheduledTask({ identity: id, headers: buildCSRFHeaders() });
}

/** Server-computed next run time per cron expression (cron math is backend-only). */
export async function loadCronNexts(crons: string[]): Promise<Record<string, string | null>> {
  const res = await fetch("/rpc/cron-next", {
    method: "POST",
    headers: { "content-type": "application/json", ...buildCSRFHeaders() },
    body: JSON.stringify({ crons }),
  });
  if (!res.ok) return {};
  const body = await res.json();
  return body.nexts ?? {};
}

export async function loadToolCatalog(): Promise<ToolCatalogEntry[]> {
  const res = await fetch("/rpc/tool-catalog", { headers: buildCSRFHeaders() });
  if (!res.ok) return [];
  const body = await res.json();
  return body.tools ?? [];
}

export async function loadDefaults(): Promise<{ systemPrompt: string }> {
  const res = await fetch("/rpc/config-defaults", { headers: buildCSRFHeaders() });
  if (!res.ok) return { systemPrompt: "" };
  const body = await res.json();
  return { systemPrompt: body.system_prompt ?? "" };
}

export type SessionRow = {
  conversation_id: string;
  status: string;
  model: string;
  cwd: string;
  tools: number;
  commands: number;
  "extensions?": boolean;
};

export async function loadSessions(): Promise<SessionRow[]> {
  const res = await fetch("/rpc/sessions", { headers: buildCSRFHeaders() });
  if (!res.ok) return [];
  return (await res.json()).sessions ?? [];
}

export async function stopSession(conversationId: string): Promise<void> {
  await fetch("/rpc/sessions/stop", {
    method: "POST",
    headers: { ...buildCSRFHeaders(), "content-type": "application/json" },
    body: JSON.stringify({ conversation_id: conversationId }),
  });
}

export type GlobalExtensions = {
  dir: string;
  extensions: { name: string; "dir?": boolean }[];
};

export async function loadGlobalExtensions(): Promise<GlobalExtensions> {
  const res = await fetch("/rpc/extensions", { headers: buildCSRFHeaders() });
  if (!res.ok) return { dir: "", extensions: [] };
  return await res.json();
}


/** Names of the extension secrets stored in the app (values never leave the server). */
export async function loadExtensionSecretNames(): Promise<string[]> {
  const res = await fetch("/rpc/extensions/secrets", { headers: buildCSRFHeaders() });
  if (!res.ok) return [];
  return (await res.json()).names ?? [];
}

/** Store (upsert) an extension secret. Returns an error message, or null on success. */
export async function saveExtensionSecret(name: string, value: string): Promise<string | null> {
  const res = await fetch("/rpc/extensions/secrets", {
    method: "POST",
    headers: { ...buildCSRFHeaders(), "content-type": "application/json" },
    body: JSON.stringify({ name, value }),
  });
  if (res.ok) return null;
  const body = await res.json().catch(() => ({}));
  return body.error || `HTTP ${res.status}`;
}

export async function deleteExtensionSecret(name: string): Promise<boolean> {
  const res = await fetch("/rpc/extensions/secrets/delete", {
    method: "POST",
    headers: { ...buildCSRFHeaders(), "content-type": "application/json" },
    body: JSON.stringify({ name }),
  });
  return res.ok;
}

// ── Users & sign-in (management UI owns account management) ────────────────

export type AuthStatus = { enabled: boolean; forced: boolean; userCount: number };
export type UserRow = { id: string; email: string };

export async function loadAuthStatus(): Promise<AuthStatus | null> {
  const res = await fetch("/rpc/auth", { headers: buildCSRFHeaders(), cache: "no-store" });
  return res.ok ? await res.json() : null;
}

/** Returns an error message, or null on success. */
export async function setAuthEnabled(enabled: boolean): Promise<string | null> {
  const res = await fetch("/rpc/auth", {
    method: "POST",
    headers: { ...buildCSRFHeaders(), "content-type": "application/json" },
    body: JSON.stringify({ enabled }),
  });
  if (res.ok) return null;
  return (await res.json().catch(() => ({}))).error || `HTTP ${res.status}`;
}

export async function loadUsers(): Promise<UserRow[]> {
  const res = await fetch("/rpc/users", { headers: buildCSRFHeaders(), cache: "no-store" });
  if (!res.ok) return [];
  return (await res.json()).users ?? [];
}

/** Create, or reset the password of, an account. Error message or null. */
export async function putUser(email: string, password: string): Promise<string | null> {
  const res = await fetch("/rpc/users", {
    method: "POST",
    headers: { ...buildCSRFHeaders(), "content-type": "application/json" },
    body: JSON.stringify({ email, password }),
  });
  if (res.ok) return null;
  return (await res.json().catch(() => ({}))).error || `HTTP ${res.status}`;
}

export async function deleteUser(id: string): Promise<string | null> {
  const res = await fetch("/rpc/users/delete", {
    method: "POST",
    headers: { ...buildCSRFHeaders(), "content-type": "application/json" },
    body: JSON.stringify({ id }),
  });
  if (res.ok) return null;
  return (await res.json().catch(() => ({}))).error || `HTTP ${res.status}`;
}

/** Workspace files (relative paths) for the composer's "@" mentions. */
export async function loadWorkspaceFiles(cwd: string): Promise<string[]> {
  const res = await fetch(`/rpc/files?cwd=${encodeURIComponent(cwd)}`, {
    headers: buildCSRFHeaders(),
  });
  if (!res.ok) return [];
  return (await res.json()).files ?? [];
}

export type ForkResult = { id: string; cwd: string; model: string; title: string | null };

/** New conversation seeded with this one's history up to `position` (inclusive). */
export async function forkConversation(
  conversationId: string,
  position: number,
): Promise<ForkResult | null> {
  const res = await fetch("/rpc/conversations/fork", {
    method: "POST",
    headers: { ...buildCSRFHeaders(), "content-type": "application/json" },
    body: JSON.stringify({ conversation_id: conversationId, position }),
  });
  return res.ok ? await res.json() : null;
}

export type EmbedInfo = { authEnabled: boolean; embedToken: string | null; baseUrl: string };

export async function loadEmbedInfo(): Promise<EmbedInfo | null> {
  const res = await fetch("/rpc/embed-info", { headers: buildCSRFHeaders(), cache: "no-store" });
  return res.ok ? await res.json() : null;
}

export type VersionInfo = {
  enabled: boolean;
  current: string;
  latest: string | null;
  tag: string | null;
  updateAvailable: boolean;
  notesUrl: string | null;
  error?: string;
};

/** Ask the server what it runs and whether GitHub has a newer release. */
export async function checkVersion(): Promise<VersionInfo | null> {
  try {
    const res = await fetch("/rpc/version", { headers: buildCSRFHeaders(), cache: "no-store" });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}

/** Trigger the in-app upgrade. The server restarts underneath us on success. */
export async function applyUpgrade(): Promise<{ ok: boolean; error?: string }> {
  try {
    const res = await fetch("/rpc/version/upgrade", { method: "POST", headers: buildCSRFHeaders() });
    if (res.ok) return { ok: true };
    const body = await res.json().catch(() => ({}));
    return { ok: false, error: body.error || `HTTP ${res.status}` };
  } catch (e) {
    return { ok: false, error: e instanceof Error ? e.message : "network error" };
  }
}

export type ProviderRow = {
  id: string;
  name: string;
  label: string | null;
  baseUrl: string | null;
  configured: boolean | null;
};

/** Preset provider types shown in the picker. `name` is the routing key. */
export const PROVIDER_PRESETS = [
  { id: "openai", label: "OpenAI", name: "openai", baseUrl: "", compatible: false },
  { id: "anthropic", label: "Anthropic", name: "anthropic", baseUrl: "", compatible: false },
  { id: "google", label: "Google Gemini", name: "google", baseUrl: "", compatible: false },
  {
    id: "compatible",
    label: "OpenAI-compatible gateway",
    name: "openai",
    baseUrl: "",
    compatible: true,
  },
] as const;

export async function loadProviders(): Promise<ProviderRow[]> {
  const result = await listProviders({
    fields: ["id", "name", "label", "baseUrl", "configured"],
    headers: buildCSRFHeaders(),
  });
  return result.success ? (result.data as ProviderRow[]) : [];
}

export async function saveProvider(name: string, baseUrl: string, label: string) {
  return putProvider({
    input: { name, baseUrl: baseUrl || null, label: label || null },
    fields: ["id"],
    headers: buildCSRFHeaders(),
  });
}

export async function discoverModels(providerName: string): Promise<{ models?: string[]; error?: string }> {
  const res = await fetch("/rpc/discover-models", {
    method: "POST",
    headers: { ...buildCSRFHeaders(), "content-type": "application/json" },
    body: JSON.stringify({ provider: providerName }),
  });
  const body = await res.json();
  return res.ok ? { models: body.models } : { error: body.error ?? "discovery failed" };
}

export async function saveProviderKey(id: string, apiKey: string) {
  return setProviderKey({ identity: id, input: { apiKey }, fields: ["id"], headers: buildCSRFHeaders() });
}

export async function removeProvider(id: string) {
  return destroyProvider({ identity: id, headers: buildCSRFHeaders() });
}

export async function clearKey(id: string) {
  return clearProviderKey({ identity: id, fields: ["id"], headers: buildCSRFHeaders() });
}
