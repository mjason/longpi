import { buildCSRFHeaders, listSettings, putSetting } from "../ash_rpc";

export type SettingsMap = Record<string, string>;

export const SETTING_KEYS = {
  systemPrompt: "system_prompt",
  defaultModel: "default_model",
} as const;

export async function loadSettings(): Promise<SettingsMap> {
  const result = await listSettings({
    fields: ["key", "value"],
    headers: buildCSRFHeaders(),
  });
  if (!result.success) return {};
  const map: SettingsMap = {};
  for (const row of result.data) {
    if (row.value != null) map[row.key] = row.value;
  }
  return map;
}

export async function saveSetting(key: string, value: string): Promise<boolean> {
  const result = await putSetting({
    input: { key, value },
    fields: ["key", "value"],
    headers: buildCSRFHeaders(),
  });
  return result.success;
}
