import { Check, KeyRound, Loader2, Plus, RotateCcw, Search, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "../components/ui/button";
import { Checkbox } from "../components/ui/checkbox";
import { Input } from "../components/ui/input";
import { Slider } from "../components/ui/slider";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "../components/ui/select";
import { Textarea } from "../components/ui/textarea";
import { cn } from "../lib/utils";
import {
  addModel,
  APPROVAL_LEVELS,
  discoverModels,
  loadDefaults,
  loadProviders,
  loadSettings,
  loadToolCatalog,
  PROVIDER_PRESETS,
  type ProviderRow,
  removeProvider,
  saveProvider,
  saveProviderKey,
  saveSetting,
  SETTING_KEYS,
  type ToolCatalogEntry,
  toolDescKey,
} from "./settings";

// The management UI (ManagementPanel + sections/*) renders these tab bodies
// directly — GeneralTab, ProvidersTab, ToolsTab. There is no standalone settings
// dialog or Models tab here anymore (models live in sections/ModelsSection).

function SaveButton({ onSave, label = "Save" }: { onSave: () => Promise<void>; label?: string }) {
  const [state, setState] = useState<"idle" | "saving" | "saved">("idle");
  return (
    <div className="flex items-center justify-end gap-3">
      {state === "saved" && (
        <span className="flex items-center gap-1.5 text-sm text-tool">
          <Check className="size-4" /> Saved
        </span>
      )}
      <Button
        disabled={state === "saving"}
        onClick={async () => {
          setState("saving");
          await onSave();
          setState("saved");
          setTimeout(() => setState("idle"), 1500);
        }}
      >
        {state === "saving" && <Loader2 className="animate-spin" />}
        {label}
      </Button>
    </div>
  );
}

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1.5">
      <label className="text-sm font-medium">{label}</label>
      {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
      {children}
    </div>
  );
}

export function GeneralTab() {
  const [systemPrompt, setSystemPrompt] = useState("");
  const [defaultModel, setDefaultModel] = useState("");
  const [defaultPrompt, setDefaultPrompt] = useState("");
  const [approvalLevel, setApprovalLevel] = useState("auto");
  const [compactionEnabled, setCompactionEnabled] = useState(true);
  const [compactionPct, setCompactionPct] = useState(80);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    Promise.all([loadSettings(), loadDefaults()]).then(([s, d]) => {
      // Show the effective prompt: the saved override, or the built-in default
      // so the editor is never an empty box.
      setSystemPrompt(s[SETTING_KEYS.systemPrompt] || d.systemPrompt);
      setDefaultPrompt(d.systemPrompt);
      setDefaultModel(s[SETTING_KEYS.defaultModel] ?? "");
      setApprovalLevel(s[SETTING_KEYS.approvalLevel] || "auto");
      setCompactionEnabled(s[SETTING_KEYS.compactionEnabled] !== "false");
      const ratio = parseFloat(s[SETTING_KEYS.compactionRatio] || "0.8");
      setCompactionPct(Number.isFinite(ratio) ? Math.round(ratio * 100) : 80);
      setLoading(false);
    });
  }, []);

  if (loading) return <Spinner />;

  const isDefault = systemPrompt.trim() === defaultPrompt.trim();

  return (
    <div className="space-y-5 py-4">
      <Field
        label="Approval level"
        hint="How much the agent may do without asking you first."
      >
        <div className="grid grid-cols-3 gap-2">
          {APPROVAL_LEVELS.map((lvl) => (
            <button
              key={lvl.id}
              onClick={async () => {
                setApprovalLevel(lvl.id);
                await saveSetting(SETTING_KEYS.approvalLevel, lvl.id);
              }}
              className={cn(
                "rounded-md px-3 py-2 text-left ring-1 transition-colors",
                approvalLevel === lvl.id
                  ? "bg-accent ring-primary"
                  : "ring-black/[0.06] hover:bg-accent/50 dark:ring-white/[0.08]",
              )}
            >
              <div className="text-sm font-medium">{lvl.label}</div>
              <div className="mt-0.5 text-[11px] leading-tight text-muted-foreground">{lvl.hint}</div>
            </button>
          ))}
        </div>
      </Field>

      <Field label="Default model" hint="Prefills new conversations.">
        <Input
          className="font-mono text-sm"
          placeholder="openai:gpt-5.4"
          value={defaultModel}
          onChange={(e) => setDefaultModel(e.target.value)}
        />
      </Field>
      <Field
        label="System prompt"
        hint="Sent at the start of every conversation. Edit freely; use {{cwd}} for the workspace path."
      >
        <div className="flex items-center gap-2">
          <span className="text-xs text-muted-foreground">
            {isDefault ? "Using the built-in default." : "Customized."}
          </span>
          {!isDefault && (
            <Button
              variant="ghost"
              size="sm"
              className="h-7 gap-1 px-2 text-xs text-muted-foreground hover:text-foreground"
              onClick={() => setSystemPrompt(defaultPrompt)}
            >
              <RotateCcw className="size-3" /> reset to default
            </Button>
          )}
        </div>
        <Textarea
          className="min-h-[220px] resize-y font-mono text-xs leading-relaxed"
          value={systemPrompt}
          onChange={(e) => setSystemPrompt(e.target.value)}
        />
      </Field>

      <Field
        label="Context compaction"
        hint="When a conversation nears the model's context window, older messages are summarized to make room. The full history stays stored."
      >
        <label className="flex items-center gap-2 text-sm">
          <Checkbox
            checked={compactionEnabled}
            onCheckedChange={(v: boolean | "indeterminate") => setCompactionEnabled(v === true)}
          />
          Enabled
        </label>
        <div className="flex items-center gap-3">
          <Slider
            min={50}
            max={95}
            step={5}
            value={[compactionPct]}
            disabled={!compactionEnabled}
            onValueChange={(value: number[]) => setCompactionPct(value[0])}
            className="flex-1"
          />
          <span className="w-28 text-xs text-muted-foreground">
            compact at {compactionPct}% of window
          </span>
        </div>
      </Field>

      <SaveButton
        onSave={async () => {
          // Storing the default is the same as clearing the override; keep the
          // db clean by saving blank when unchanged.
          const toStore = systemPrompt.trim() === defaultPrompt.trim() ? "" : systemPrompt;
          await Promise.all([
            saveSetting(SETTING_KEYS.systemPrompt, toStore),
            saveSetting(SETTING_KEYS.defaultModel, defaultModel),
            saveSetting(SETTING_KEYS.compactionEnabled, compactionEnabled ? "true" : "false"),
            saveSetting(SETTING_KEYS.compactionRatio, (compactionPct / 100).toFixed(2)),
          ]);
        }}
      />
    </div>
  );
}

export function ProvidersTab() {
  const [providers, setProviders] = useState<ProviderRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [presetId, setPresetId] = useState<string>(PROVIDER_PRESETS[0].id);
  const refresh = () => loadProviders().then(setProviders);

  useEffect(() => {
    refresh().then(() => setLoading(false));
  }, []);

  async function addPreset() {
    const preset = PROVIDER_PRESETS.find((p) => p.id === presetId)!;
    await saveProvider(preset.name, preset.baseUrl, preset.label);
    refresh();
  }

  if (loading) return <Spinner />;

  return (
    <div className="space-y-4 py-4">
      <p className="text-xs text-muted-foreground">
        API credentials per provider. Keys are write-only — once saved they never leave the server.
        For an OpenAI-compatible gateway, set the base URL and discover its models with one click.
      </p>

      {providers.length === 0 && (
        <p className="text-sm text-muted-foreground">
          No providers yet. Falls back to environment variables until you add one.
        </p>
      )}

      {providers.map((p) => (
        <ProviderRowEditor key={p.id} provider={p} onChange={refresh} />
      ))}

      <div className="flex items-end gap-2 border-t border-border pt-4">
        <Select value={presetId} onValueChange={setPresetId}>
          <SelectTrigger className="flex-1">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {PROVIDER_PRESETS.map((p) => (
              <SelectItem key={p.id} value={p.id}>
                {p.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
        <Button onClick={addPreset}>
          <Plus className="size-4" /> Add provider
        </Button>
      </div>
    </div>
  );
}

function ProviderRowEditor({ provider, onChange }: { provider: ProviderRow; onChange: () => void }) {
  const [label, setLabel] = useState(provider.label ?? "");
  const [baseUrl, setBaseUrl] = useState(provider.baseUrl ?? "");
  const [apiKey, setApiKey] = useState("");
  const [discovered, setDiscovered] = useState<string[] | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [discovering, setDiscovering] = useState(false);
  const [discoverError, setDiscoverError] = useState<string | null>(null);

  async function persist() {
    await saveProvider(provider.name, baseUrl, label);
    if (apiKey.trim()) {
      await saveProviderKey(provider.id, apiKey);
      setApiKey("");
    }
  }

  async function discover() {
    setDiscovering(true);
    setDiscoverError(null);
    // Save base_url/key first so the server can reach the endpoint.
    await persist();
    onChange();
    const result = await discoverModels(provider.name);
    setDiscovering(false);
    if (result.error) setDiscoverError(result.error);
    else {
      setDiscovered(result.models ?? []);
      setSelected(new Set(result.models ?? []));
    }
  }

  async function remove() {
    if (!confirm(`Remove provider "${label || provider.name}"? Saved models keep working only if another provider serves them.`))
      return;
    await removeProvider(provider.id);
    onChange();
  }

  async function addSelected() {
    let i = 0;
    for (const id of selected) {
      await addModel(`${provider.name}:${id}`, id, i++);
    }
    setDiscovered(null);
    setSelected(new Set());
  }

  return (
    <div className="space-y-2 rounded-md p-3 ring-1 ring-black/[0.06] dark:ring-white/[0.08]">
      <div className="flex items-center gap-2">
        <span className="font-mono text-xs text-muted-foreground">{provider.name}</span>
        <div className="flex-1" />
        <span
          className={cn(
            "flex items-center gap-1 text-xs",
            provider.configured ? "text-tool" : "text-muted-foreground",
          )}
        >
          <KeyRound className="size-3" />
          {provider.configured ? "key set" : "no key"}
        </span>
        <Button
          variant="ghost"
          size="icon"
          onClick={remove}
          aria-label="Remove provider"
          className="size-7 text-muted-foreground hover:text-destructive"
        >
          <Trash2 className="size-4" />
        </Button>
      </div>
      <Input
        placeholder="display name (e.g. listenai)"
        value={label}
        onChange={(e) => setLabel(e.target.value)}
      />
      <Input
        className="font-mono text-xs"
        placeholder="base URL (e.g. https://openrouter.listenai.com/v1)"
        value={baseUrl}
        onChange={(e) => setBaseUrl(e.target.value)}
      />
      <Input
        type="password"
        className="font-mono text-xs"
        placeholder={provider.configured ? "•••••••• (leave blank to keep)" : "api key"}
        value={apiKey}
        onChange={(e) => setApiKey(e.target.value)}
      />
      <div className="flex items-center gap-2">
        <SaveButton
          label="Save"
          onSave={async () => {
            await persist();
            onChange();
          }}
        />
        <Button variant="outline" onClick={discover} disabled={discovering || !baseUrl.trim()}>
          {discovering ? <Loader2 className="animate-spin" /> : <Search className="size-4" />}
          Discover models
        </Button>
      </div>

      {discoverError && <p className="text-xs text-destructive">{discoverError}</p>}

      {discovered && (
        <div className="space-y-2 rounded-md bg-card/40 p-2 ring-1 ring-black/[0.06] dark:ring-white/[0.08]">
          <p className="text-xs text-muted-foreground">
            {discovered.length} models found. Select the ones to add.
          </p>
          <div className="max-h-40 space-y-1 overflow-y-auto">
            {discovered.map((id) => (
              <label key={id} className="flex items-center gap-2 font-mono text-xs">
                <Checkbox
                  checked={selected.has(id)}
                  onCheckedChange={() =>
                    setSelected((s) => {
                      const next = new Set(s);
                      next.has(id) ? next.delete(id) : next.add(id);
                      return next;
                    })
                  }
                />
                {id}
              </label>
            ))}
          </div>
          <Button size="sm" onClick={addSelected} disabled={selected.size === 0}>
            Add {selected.size} to Models
          </Button>
        </div>
      )}
    </div>
  );
}

export function ToolsTab() {
  const [tools, setTools] = useState<ToolCatalogEntry[]>([]);
  const [drafts, setDrafts] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    loadToolCatalog().then((t) => {
      setTools(t);
      setDrafts(Object.fromEntries(t.map((x) => [x.name, x.description])));
      setLoading(false);
    });
  }, []);

  if (loading) return <Spinner />;

  return (
    <div className="space-y-5 py-4">
      <p className="text-xs text-muted-foreground">
        The description each tool advertises to the model. Reset restores the built-in text.
      </p>
      {tools.map((tool) => {
        const value = drafts[tool.name] ?? "";
        const isDefault = value === tool.default_description;
        return (
          <div key={tool.name} className="space-y-1.5">
            <div className="flex items-center gap-2">
              <span className="font-mono text-sm font-semibold">{tool.name}</span>
              {!isDefault && (
                <Button
                  variant="ghost"
                  size="sm"
                  className="h-6 gap-1 px-1.5 text-xs text-muted-foreground hover:text-foreground"
                  onClick={() => setDrafts((d) => ({ ...d, [tool.name]: tool.default_description }))}
                >
                  <RotateCcw className="size-3" /> reset
                </Button>
              )}
            </div>
            <Textarea
              className="min-h-[64px] resize-y text-xs leading-relaxed"
              value={value}
              onChange={(e) => setDrafts((d) => ({ ...d, [tool.name]: e.target.value }))}
            />
          </div>
        );
      })}
      <SaveButton
        label="Save tool descriptions"
        onSave={async () => {
          await Promise.all(
            tools.map((tool) => saveSetting(toolDescKey(tool.name), drafts[tool.name] ?? "")),
          );
        }}
      />
    </div>
  );
}

function Spinner() {
  return (
    <div className="flex justify-center py-10">
      <Loader2 className="size-5 animate-spin text-muted-foreground" />
    </div>
  );
}
