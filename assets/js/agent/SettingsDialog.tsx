import { Check, Loader2 } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "../components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "../components/ui/dialog";
import { Input } from "../components/ui/input";
import { loadSettings, saveSetting, SETTING_KEYS } from "./settings";

const DEFAULT_MODEL = "openai:gpt-5.4";

export function SettingsDialog({ open, onOpenChange }: { open: boolean; onOpenChange: (v: boolean) => void }) {
  const [systemPrompt, setSystemPrompt] = useState("");
  const [defaultModel, setDefaultModel] = useState("");
  const [loading, setLoading] = useState(true);
  const [state, setState] = useState<"idle" | "saving" | "saved">("idle");

  useEffect(() => {
    if (!open) return;
    setLoading(true);
    setState("idle");
    loadSettings().then((s) => {
      setSystemPrompt(s[SETTING_KEYS.systemPrompt] ?? "");
      setDefaultModel(s[SETTING_KEYS.defaultModel] ?? "");
      setLoading(false);
    });
  }, [open]);

  async function save() {
    setState("saving");
    await Promise.all([
      saveSetting(SETTING_KEYS.systemPrompt, systemPrompt),
      saveSetting(SETTING_KEYS.defaultModel, defaultModel),
    ]);
    setState("saved");
    setTimeout(() => setState("idle"), 1500);
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-2xl">
        <DialogHeader>
          <DialogTitle>Settings</DialogTitle>
        </DialogHeader>

        {loading ? (
          <div className="flex justify-center py-10">
            <Loader2 className="size-5 animate-spin text-muted-foreground" />
          </div>
        ) : (
          <div className="space-y-5">
            <Field
              label="Default model"
              hint="Used to prefill new conversations."
            >
              <Input
                className="font-mono text-sm"
                placeholder={DEFAULT_MODEL}
                value={defaultModel}
                onChange={(e) => setDefaultModel(e.target.value)}
              />
            </Field>

            <Field
              label="System prompt"
              hint="Overrides the built-in prompt for every conversation. Leave blank to use the default. Use {{cwd}} for the workspace path."
            >
              <textarea
                className="min-h-[180px] w-full resize-y rounded-md border border-input bg-transparent px-3 py-2 font-mono text-xs leading-relaxed outline-none focus-visible:border-ring"
                placeholder="Leave blank to use the built-in default prompt…"
                value={systemPrompt}
                onChange={(e) => setSystemPrompt(e.target.value)}
              />
            </Field>

            <div className="flex items-center justify-end gap-3">
              {state === "saved" && (
                <span className="flex items-center gap-1.5 text-sm text-tool">
                  <Check className="size-4" /> Saved
                </span>
              )}
              <Button onClick={save} disabled={state === "saving"}>
                {state === "saving" && <Loader2 className="animate-spin" />}
                Save settings
              </Button>
            </div>
          </div>
        )}
      </DialogContent>
    </Dialog>
  );
}

function Field({ label, hint, children }: { label: string; hint: string; children: React.ReactNode }) {
  return (
    <div className="space-y-1.5">
      <label className="text-sm font-medium">{label}</label>
      <p className="text-xs text-muted-foreground">{hint}</p>
      {children}
    </div>
  );
}
