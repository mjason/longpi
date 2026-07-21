import {
  buildCSRFHeaders,
  clearProviderKey,
  createModel,
  destroyModel,
  destroyProvider,
  listModels,
  listProviders,
  listSettings,
  putProvider,
  putSetting,
  setProviderKey,
  updateModel,
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
  packages: Record<string, string>;
};

export async function loadGlobalExtensions(): Promise<GlobalExtensions> {
  const res = await fetch("/rpc/extensions", { headers: buildCSRFHeaders() });
  if (!res.ok) return { dir: "", extensions: [], packages: {} };
  return await res.json();
}

export async function saveGlobalPackages(packages: Record<string, string>): Promise<boolean> {
  const res = await fetch("/rpc/extensions/packages", {
    method: "POST",
    headers: { ...buildCSRFHeaders(), "content-type": "application/json" },
    body: JSON.stringify({ packages }),
  });
  return res.ok;
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
