import { Check, Loader2, Plus, RotateCcw, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "../components/ui/button";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "../components/ui/dialog";
import { Input } from "../components/ui/input";
import { cn } from "../lib/utils";
import {
  addModel,
  loadModels,
  loadSettings,
  loadToolCatalog,
  type ModelRow,
  removeModel,
  saveSetting,
  setModel,
  SETTING_KEYS,
  type ToolCatalogEntry,
  toolDescKey,
} from "./settings";

type Tab = "general" | "models" | "tools";

const TABS: { id: Tab; label: string }[] = [
  { id: "general", label: "General" },
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
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    loadSettings().then((s) => {
      setSystemPrompt(s[SETTING_KEYS.systemPrompt] ?? "");
      setDefaultModel(s[SETTING_KEYS.defaultModel] ?? "");
      setLoading(false);
    });
  }, []);

  if (loading) return <Spinner />;

  return (
    <div className="space-y-5 py-4">
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
        hint="Overrides the built-in prompt for every conversation. Blank = default. Use {{cwd}} for the workspace path."
      >
        <textarea
          className="min-h-[200px] w-full resize-y rounded-md border border-input bg-transparent px-3 py-2 font-mono text-xs leading-relaxed outline-none focus-visible:border-ring"
          placeholder="Leave blank to use the built-in default prompt…"
          value={systemPrompt}
          onChange={(e) => setSystemPrompt(e.target.value)}
        />
      </Field>
      <SaveButton
        onSave={async () => {
          await Promise.all([
            saveSetting(SETTING_KEYS.systemPrompt, systemPrompt),
            saveSetting(SETTING_KEYS.defaultModel, defaultModel),
          ]);
        }}
      />
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
