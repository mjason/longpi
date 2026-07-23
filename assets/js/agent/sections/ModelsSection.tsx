import { Loader2, Plus, Search, Trash2 } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { Button } from "../../components/ui/button";
import { Input } from "../../components/ui/input";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "../../components/ui/select";
import { Switch } from "../../components/ui/switch";
import { cn } from "../../lib/utils";
import { useI18n } from "../i18n";
import {
  addModel,
  BUILTIN_TIERS,
  loadModelAliases,
  loadModels,
  type ModelAliasRow,
  type ModelRow,
  removeModel,
  removeModelAlias,
  saveModelAlias,
  setModel,
  TIER_EFFORTS,
} from "../settings";

function providerOf(spec: string): string {
  const i = spec.indexOf(":");
  return i === -1 ? "other" : spec.slice(0, i);
}

function modelOf(spec: string): string {
  const i = spec.indexOf(":");
  return i === -1 ? spec : spec.slice(i + 1);
}

/**
 * Named model tiers (poker: J/Q/K + custom): subagent roles and tools say
 * "J", the mapping here decides which concrete model that is.
 */
function ModelTiers({ models }: { models: ModelRow[] }) {
  const { t } = useI18n();
  const [aliases, setAliases] = useState<ModelAliasRow[]>([]);
  const [customName, setCustomName] = useState("");

  const refresh = () => loadModelAliases().then(setAliases);
  useEffect(() => {
    refresh();
  }, []);

  const enabled = models.filter((m) => m.enabled);
  const byName = new Map(aliases.map((a) => [a.name.toUpperCase(), a] as const));
  const customs = aliases.filter((a) => !BUILTIN_TIERS.includes(a.name.toUpperCase() as never));

  async function assign(
    name: string,
    changes: { spec?: string; reasoningEffort?: string | null },
    current: ModelAliasRow | undefined,
    hint: string,
  ) {
    const spec = changes.spec ?? current?.spec;
    if (!spec) return;
    await saveModelAlias(name, spec, {
      note: current?.note ?? hint,
      reasoningEffort:
        changes.reasoningEffort !== undefined
          ? changes.reasoningEffort
          : (current?.reasoningEffort ?? null),
    });
    refresh();
  }

  async function unmap(alias: ModelAliasRow | undefined) {
    if (!alias) return;
    await removeModelAlias(alias.id);
    refresh();
  }

  const row = (name: string, hint: string, alias: ModelAliasRow | undefined) => (
    <div key={name} className="flex items-center gap-3 px-3 py-2 text-sm">
      <span className="w-8 text-center font-mono text-base font-semibold">{name}</span>
      <span className="flex-1 truncate text-xs text-muted-foreground">{hint}</span>
      <Select
        value={alias?.spec ?? ""}
        onValueChange={(spec: string) => assign(name, { spec }, alias, hint)}
      >
        <SelectTrigger className="h-8 w-56 font-mono text-xs">
          <SelectValue placeholder={t("tiers.unmapped")} />
        </SelectTrigger>
        <SelectContent>
          {enabled.map((m) => (
            <SelectItem key={m.id} value={m.spec} className="font-mono text-xs">
              {m.spec}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <Select
        value={alias?.reasoningEffort ?? ""}
        onValueChange={(effort: string) =>
          assign(name, { reasoningEffort: effort === "__auto__" ? null : effort }, alias, hint)
        }
        disabled={!alias}
      >
        <SelectTrigger className="h-8 w-28 text-xs">
          <SelectValue placeholder={t("reasoning.auto")} />
        </SelectTrigger>
        <SelectContent>
          {TIER_EFFORTS.map((effort) => (
            <SelectItem key={effort || "auto"} value={effort || "__auto__"} className="text-xs">
              {t(`reasoning.${effort || "auto"}`)}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      <Button
        variant="ghost"
        size="icon"
        onClick={() => unmap(alias)}
        disabled={!alias}
        aria-label="Unmap tier"
        className="size-7 text-muted-foreground hover:text-destructive"
      >
        <Trash2 className="size-4" />
      </Button>
    </div>
  );

  return (
    <div className="overflow-hidden rounded-lg ring-1 ring-black/[0.06] dark:ring-white/[0.08]">
      <div className="border-b border-border bg-muted/40 px-3 py-2">
        <span className="text-sm font-semibold">{t("tiers.title")}</span>
        <p className="mt-0.5 text-xs text-muted-foreground">{t("tiers.hint")}</p>
      </div>
      <div className="divide-y divide-border">
        {BUILTIN_TIERS.map((name) => row(name, t(`tiers.${name}`), byName.get(name)))}
        {customs.map((a) => row(a.name, a.note ?? "", a))}
      </div>
      <div className="flex items-center gap-2 border-t border-border px-3 py-2">
        <Input
          className="h-8 w-40 text-xs"
          placeholder={t("tiers.custom.placeholder")}
          value={customName}
          onChange={(e) => setCustomName(e.target.value)}
        />
        <Button
          size="sm"
          variant="outline"
          className="h-8"
          disabled={!customName.trim() || enabled.length === 0}
          onClick={async () => {
            await assign(customName.trim(), { spec: enabled[0].spec }, undefined, "");
            setCustomName("");
          }}
        >
          <Plus className="size-4" /> {t("tiers.add")}
        </Button>
      </div>
    </div>
  );
}

export function ModelsSection() {
  const [models, setModels] = useState<ModelRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [query, setQuery] = useState("");
  const [spec, setSpec] = useState("");

  const refresh = () => loadModels().then(setModels);

  useEffect(() => {
    refresh().then(() => setLoading(false));
  }, []);

  const groups = useMemo(() => {
    const q = query.trim().toLowerCase();
    const filtered = q ? models.filter((m) => m.spec.toLowerCase().includes(q)) : models;
    const byProvider = new Map<string, ModelRow[]>();
    for (const m of filtered) {
      const p = providerOf(m.spec);
      (byProvider.get(p) ?? byProvider.set(p, []).get(p)!).push(m);
    }
    return [...byProvider.entries()].sort(([a], [b]) => a.localeCompare(b));
  }, [models, query]);

  async function setEnabledForMany(rows: ModelRow[], enabled: boolean) {
    setModels((ms) => ms.map((m) => (rows.some((r) => r.id === m.id) ? { ...m, enabled } : m)));
    const results = await Promise.all(rows.map((m) => setModel(m.id, { enabled })));
    // Re-sync with the server if any write failed (undo the optimistic flips).
    if (results.some((r) => !r.success)) refresh();
  }

  async function removeMany(rows: ModelRow[]) {
    if (!confirm(`Remove ${rows.length} model${rows.length === 1 ? "" : "s"}?`)) return;
    await Promise.all(rows.map((m) => removeModel(m.id)));
    refresh();
  }

  async function add() {
    if (!spec.trim()) return;
    await addModel(spec.trim(), "", models.length);
    setSpec("");
    refresh();
  }

  if (loading) return <Loader2 className="my-10 size-5 animate-spin text-muted-foreground" />;

  return (
    <div className="space-y-4 py-4">
      <p className="text-sm text-muted-foreground">
        Models offered in the picker for new conversations, grouped by provider. Discover them from a
        provider's gateway (Providers tab), then enable the ones you want.
      </p>

      <ModelTiers models={models} />

      <div className="relative">
        <Search className="absolute left-2.5 top-2.5 size-4 text-muted-foreground" />
        <Input
          className="pl-8 text-sm"
          placeholder="Filter models…"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
      </div>

      {models.length === 0 && <p className="text-sm text-muted-foreground">No models yet.</p>}

      {groups.map(([provider, rows]) => {
        const enabledCount = rows.filter((r) => r.enabled).length;
        const allOn = enabledCount === rows.length;
        return (
          <div key={provider} className="overflow-hidden rounded-lg ring-1 ring-black/[0.06] dark:ring-white/[0.08]">
            <div className="flex items-center gap-2 border-b border-border bg-muted/40 px-3 py-2">
              <span className="font-mono text-sm font-semibold">{provider}</span>
              <span className="text-xs text-muted-foreground">
                {enabledCount}/{rows.length} enabled
              </span>
              <div className="flex-1" />
              <Button
                variant="ghost"
                size="sm"
                className="h-7 px-2 text-xs text-muted-foreground hover:text-foreground"
                onClick={() => setEnabledForMany(rows, !allOn)}
              >
                {allOn ? "Disable all" : "Enable all"}
              </Button>
              <Button
                variant="ghost"
                size="sm"
                className="h-7 px-2 text-xs text-muted-foreground hover:text-destructive"
                onClick={() => removeMany(rows)}
              >
                Remove all
              </Button>
            </div>
            <div className="divide-y divide-border">
              {rows.map((m) => (
                <div key={m.id} className="flex items-center gap-3 px-3 py-1.5 text-sm">
                  <Switch
                    checked={m.enabled}
                    onCheckedChange={async (next: boolean) => {
                      setModels((ms) =>
                        ms.map((x) => (x.id === m.id ? { ...x, enabled: next } : x)),
                      );
                      const res = await setModel(m.id, { enabled: next });
                      // Revert the optimistic flip if the server rejected it.
                      if (!res.success) {
                        setModels((ms) =>
                          ms.map((x) => (x.id === m.id ? { ...x, enabled: !next } : x)),
                        );
                      }
                    }}
                    aria-label="Enabled"
                  />
                  <span className={cn("flex-1 truncate font-mono", !m.enabled && "text-muted-foreground")}>
                    {modelOf(m.spec)}
                  </span>
                  <Button
                    variant="ghost"
                    size="icon"
                    onClick={() => removeMany([m])}
                    aria-label="Remove model"
                    className="size-7 text-muted-foreground hover:text-destructive"
                  >
                    <Trash2 className="size-4" />
                  </Button>
                </div>
              ))}
            </div>
          </div>
        );
      })}

      <div className="flex items-end gap-2 border-t border-border pt-4">
        <Input
          className="flex-1 font-mono text-sm"
          placeholder="provider:model (e.g. openai:gpt-5.4)"
          value={spec}
          onChange={(e) => setSpec(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && add()}
        />
        <Button onClick={add} disabled={!spec.trim()}>
          <Plus className="size-4" /> Add
        </Button>
      </div>
    </div>
  );
}
