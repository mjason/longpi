import {
  buildCSRFHeaders,
  createModel,
  destroyModel,
  listModels,
  listSettings,
  putSetting,
  updateModel,
} from "../ash_rpc";

export type SettingsMap = Record<string, string>;

export const SETTING_KEYS = {
  systemPrompt: "system_prompt",
  defaultModel: "default_model",
} as const;

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
