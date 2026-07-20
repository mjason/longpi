import { Check, KeyRound, Loader2, Plus, RotateCcw, Search, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "../components/ui/button";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "../components/ui/dialog";
import { Input } from "../components/ui/input";
import { cn } from "../lib/utils";
import {
  addModel,
  APPROVAL_LEVELS,
  discoverModels,
  loadDefaults,
  loadModels,
  loadProviders,
  loadSettings,
  loadToolCatalog,
  type ModelRow,
  PROVIDER_PRESETS,
  type ProviderRow,
  removeModel,
  saveProvider,
  saveProviderKey,
  saveSetting,
  setModel,
  SETTING_KEYS,
  type ToolCatalogEntry,
  toolDescKey,
} from "./settings";

type Tab = "general" | "providers" | "models" | "tools";

const TABS: { id: Tab; label: string }[] = [
  { id: "general", label: "General" },
  { id: "providers", label: "Providers" },
  { id: "models", label: "Models" },
  { id: "tools", label: "Tools" },
];

export function SettingsDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (v: boolean) => void }) {
  const [tab, setTab] = useState<Tab>("general");

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-3xl">
        <DialogHeader>
          <DialogTitle>Settings</DialogTitle>
        </DialogHeader>

        <div className="flex gap-1 border-b border-border">
          {TABS.map((t) => (
            <button
              key={t.id}
              onClick={() => setTab(t.id)}
              className={cn(
                "-mb-px border-b-2 px-3 py-1.5 text-sm transition-colors",
                tab === t.id
                  ? "border-primary text-foreground"
                  : "border-transparent text-muted-foreground hover:text-foreground",
              )}
            >
              {t.label}
            </button>
          ))}
        </div>

        <div className="max-h-[60vh] overflow-y-auto pr-1">
          {open && tab === "general" && <GeneralTab />}
          {open && tab === "providers" && <ProvidersTab />}
          {open && tab === "models" && <ModelsTab />}
          {open && tab === "tools" && <ToolsTab />}
        </div>
      </DialogContent>
    </Dialog>
  );
}

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

function GeneralTab() {
  const [systemPrompt, setSystemPrompt] = useState("");
  const [defaultModel, setDefaultModel] = useState("");
  const [defaultPrompt, setDefaultPrompt] = useState("");
  const [approvalLevel, setApprovalLevel] = useState("auto");
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    Promise.all([loadSettings(), loadDefaults()]).then(([s, d]) => {
      // Show the effective prompt: the saved override, or the built-in default
      // so the editor is never an empty box.
      setSystemPrompt(s[SETTING_KEYS.systemPrompt] || d.systemPrompt);
      setDefaultPrompt(d.systemPrompt);
      setDefaultModel(s[SETTING_KEYS.defaultModel] ?? "");
      setApprovalLevel(s[SETTING_KEYS.approvalLevel] || "auto");
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
                "rounded-md border px-3 py-2 text-left transition-colors",
                approvalLevel === lvl.id
                  ? "border-primary bg-accent"
                  : "border-border hover:bg-accent/50",
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
            <button
              className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
              onClick={() => setSystemPrompt(defaultPrompt)}
            >
              <RotateCcw className="size-3" /> reset to default
            </button>
          )}
        </div>
        <textarea
          className="min-h-[220px] w-full resize-y rounded-md border border-input bg-transparent px-3 py-2 font-mono text-xs leading-relaxed outline-none focus-visible:border-ring"
          value={systemPrompt}
          onChange={(e) => setSystemPrompt(e.target.value)}
        />
      </Field>
      <SaveButton
        onSave={async () => {
          // Storing the default is the same as clearing the override; keep the
          // db clean by saving blank when unchanged.
          const toStore = systemPrompt.trim() === defaultPrompt.trim() ? "" : systemPrompt;
          await Promise.all([
            saveSetting(SETTING_KEYS.systemPrompt, toStore),
            saveSetting(SETTING_KEYS.defaultModel, defaultModel),
          ]);
        }}
      />
    </div>
  );
}

function ProvidersTab() {
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
        <select
          className="h-9 flex-1 rounded-md border border-input bg-transparent px-2 text-sm outline-none focus-visible:border-ring"
          value={presetId}
          onChange={(e) => setPresetId(e.target.value)}
        >
          {PROVIDER_PRESETS.map((p) => (
            <option key={p.id} value={p.id}>
              {p.label}
            </option>
          ))}
        </select>
        <Button onClick={addPreset}>
          <Plus className="size-4" /> Add provider
        </Button>
      </div>
    </div>
  );
}

function ProviderRowEditor({ provider, onChange }: { provider: ProviderRow; onChange: () => void }) {
  const [baseUrl, setBaseUrl] = useState(provider.baseUrl ?? "");
  const [apiKey, setApiKey] = useState("");
  const [discovered, setDiscovered] = useState<string[] | null>(null);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [discovering, setDiscovering] = useState(false);
  const [discoverError, setDiscoverError] = useState<string | null>(null);

  async function discover() {
    setDiscovering(true);
    setDiscoverError(null);
    // Save base_url/key first so the server can reach the endpoint.
    await saveProvider(provider.name, baseUrl, provider.label ?? "");
    if (apiKey.trim()) {
      await saveProviderKey(provider.id, apiKey);
      setApiKey("");
      onChange();
    }
    const result = await discoverModels(provider.name);
    setDiscovering(false);
    if (result.error) setDiscoverError(result.error);
    else {
      setDiscovered(result.models ?? []);
      setSelected(new Set(result.models ?? []));
    }
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
    <div className="space-y-2 rounded-md border border-border p-3">
      <div className="flex items-center gap-2">
        <span className="text-sm font-semibold">{provider.label || provider.name}</span>
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
      </div>
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
            await saveProvider(provider.name, baseUrl, provider.label ?? "");
            if (apiKey.trim()) {
              await saveProviderKey(provider.id, apiKey);
              setApiKey("");
            }
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
        <div className="space-y-2 rounded-md border border-border bg-card/40 p-2">
          <p className="text-xs text-muted-foreground">
            {discovered.length} models found. Select the ones to add.
          </p>
          <div className="max-h-40 space-y-1 overflow-y-auto">
            {discovered.map((id) => (
              <label key={id} className="flex items-center gap-2 font-mono text-xs">
                <input
                  type="checkbox"
                  checked={selected.has(id)}
                  onChange={() =>
                    setSelected((s) => {
                      const next = new Set(s);
                      next.has(id) ? next.delete(id) : next.add(id);
                      return next;
                    })
                  }
                  className="size-3.5 accent-[var(--primary)]"
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

function ModelsTab() {
  const [models, setModels] = useState<ModelRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [spec, setSpec] = useState("");
  const [label, setLabel] = useState("");

  const refresh = () => loadModels().then(setModels);

  useEffect(() => {
    refresh().then(() => setLoading(false));
  }, []);

  async function add() {
    if (!spec.trim()) return;
    await addModel(spec.trim(), label.trim(), models.length);
    setSpec("");
    setLabel("");
    refresh();
  }

  if (loading) return <Spinner />;

  return (
    <div className="space-y-4 py-4">
      <p className="text-xs text-muted-foreground">
        Models available for new conversations. Disable one to hide it without deleting.
      </p>

      <div className="space-y-2">
        {models.length === 0 && <p className="text-sm text-muted-foreground">No models yet.</p>}
        {models.map((m) => (
          <div key={m.id} className="flex items-center gap-3 rounded-md border border-border px-3 py-2">
            <input
              type="checkbox"
              checked={m.enabled}
              onChange={async () => {
                await setModel(m.id, { enabled: !m.enabled });
                refresh();
              }}
              className="size-4 accent-[var(--primary)]"
              aria-label="Enabled"
            />
            <div className="min-w-0 flex-1">
              <div className="truncate font-mono text-sm">{m.spec}</div>
              {m.label && <div className="truncate text-xs text-muted-foreground">{m.label}</div>}
            </div>
            <Button
              variant="ghost"
              size="icon"
              className="size-7"
              aria-label="Remove model"
              onClick={async () => {
                await removeModel(m.id);
                refresh();
              }}
            >
              <Trash2 className="size-4 text-destructive" />
            </Button>
          </div>
        ))}
      </div>

      <div className="flex items-end gap-2 border-t border-border pt-4">
        <div className="flex-1 space-y-1.5">
          <Input
            className="font-mono text-sm"
            placeholder="provider:model (e.g. openai:gpt-5.4)"
            value={spec}
            onChange={(e) => setSpec(e.target.value)}
          />
          <Input
            className="text-sm"
            placeholder="Label (optional)"
            value={label}
            onChange={(e) => setLabel(e.target.value)}
          />
        </div>
        <Button onClick={add} disabled={!spec.trim()}>
          <Plus className="size-4" /> Add
        </Button>
      </div>
    </div>
  );
}

function ToolsTab() {
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
                <button
                  className="flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground"
                  onClick={() => setDrafts((d) => ({ ...d, [tool.name]: tool.default_description }))}
                >
                  <RotateCcw className="size-3" /> reset
                </button>
              )}
            </div>
            <textarea
              className="min-h-[64px] w-full resize-y rounded-md border border-input bg-transparent px-3 py-2 text-xs leading-relaxed outline-none focus-visible:border-ring"
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
