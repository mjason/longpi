import { Loader2, Plus, Search, Trash2 } from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import { Button } from "../../components/ui/button";
import { Input } from "../../components/ui/input";
import { Switch } from "../../components/ui/switch";
import { cn } from "../../lib/utils";
import { addModel, loadModels, type ModelRow, removeModel, setModel } from "../settings";

function providerOf(spec: string): string {
  const i = spec.indexOf(":");
  return i === -1 ? "other" : spec.slice(0, i);
}

function modelOf(spec: string): string {
  const i = spec.indexOf(":");
  return i === -1 ? spec : spec.slice(i + 1);
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
              <button
                className="text-xs text-muted-foreground hover:text-foreground"
                onClick={() => setEnabledForMany(rows, !allOn)}
              >
                {allOn ? "Disable all" : "Enable all"}
              </button>
              <span className="text-border">·</span>
              <button
                className="text-xs text-muted-foreground hover:text-destructive"
                onClick={() => removeMany(rows)}
              >
                Remove all
              </button>
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
                  <button
                    onClick={() => removeMany([m])}
                    aria-label="Remove model"
                    className="rounded p-1 text-muted-foreground hover:text-destructive"
                  >
                    <Trash2 className="size-3.5" />
                  </button>
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
