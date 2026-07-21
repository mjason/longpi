import {
  buildCSRFHeaders,
  clearProviderKey,
  createModel,
  destroyModel,
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

export async function saveGlobalPackages(packages: Record<string, string>): Promise<void> {
  await fetch("/rpc/extensions/packages", {
    method: "POST",
    headers: { ...buildCSRFHeaders(), "content-type": "application/json" },
    body: JSON.stringify({ packages }),
  });
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
    label: "OpenAI-compatible gateway (OpenRouter, self-hosted, …)",
    name: "openai",
    baseUrl: "https://",
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

export async function clearKey(id: string) {
  return clearProviderKey({ identity: id, fields: ["id"], headers: buildCSRFHeaders() });
}
