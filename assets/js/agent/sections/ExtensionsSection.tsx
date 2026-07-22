import { Check, FileCode, Folder, KeyRound, Loader2, Plus, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { Badge } from "../../components/ui/badge";
import { Button } from "../../components/ui/button";
import { Input } from "../../components/ui/input";
import {
  deleteExtensionSecret,
  type GlobalExtensions,
  loadExtensionSecretNames,
  loadGlobalExtensions,
  saveExtensionSecret,
} from "../settings";

export function ExtensionsSection() {
  const [data, setData] = useState<GlobalExtensions | null>(null);

  useEffect(() => {
    loadGlobalExtensions().then(setData);
  }, []);

  if (!data) return <Loader2 className="my-10 size-5 animate-spin text-muted-foreground" />;

  return (
    <div className="space-y-8 py-4">
      <section className="space-y-3">
        <div>
          <h2 className="text-sm font-semibold">Global extensions</h2>
          <p className="text-xs text-muted-foreground">
            Files in{" "}
            <code className="rounded bg-muted px-1 py-0.5 font-mono">{data.dir}</code>, loaded by every
            conversation. Add or edit files there; a conversation picks them up on{" "}
            <code className="rounded bg-muted px-1 py-0.5 font-mono">/reload</code>.
          </p>
        </div>
        {data.extensions.length === 0 ? (
          <p className="text-sm text-muted-foreground">No global extensions yet.</p>
        ) : (
          <div className="divide-y divide-border rounded-lg ring-1 ring-black/[0.06] dark:ring-white/[0.08]">
            {data.extensions.map((e) => (
              <div key={e.name} className="flex items-center gap-2.5 px-3 py-2 text-sm">
                {e["dir?"] ? (
                  <Folder className="size-4 text-muted-foreground" />
                ) : (
                  <FileCode className="size-4 text-muted-foreground" />
                )}
                <span className="font-mono">{e.name}</span>
                {e["dir?"] && (
                  <Badge variant="secondary" className="font-normal">
                    package
                  </Badge>
                )}
              </div>
            ))}
          </div>
        )}
      </section>

      <SecretsSection />
    </div>
  );
}

function SecretsSection() {
  const [names, setNames] = useState<string[] | null>(null);
  const [name, setName] = useState("");
  const [value, setValue] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    loadExtensionSecretNames().then(setNames);
  }, []);

  async function add() {
    const err = await saveExtensionSecret(name.trim(), value);
    if (err) {
      setError(err);
      return;
    }
    setError(null);
    setName("");
    setValue("");
    setNames(await loadExtensionSecretNames());
    setSaved(true);
    setTimeout(() => setSaved(false), 1500);
  }

  async function remove(n: string) {
    await deleteExtensionSecret(n);
    setNames(await loadExtensionSecretNames());
  }

  return (
    <section className="space-y-3">
      <div className="flex items-center gap-2">
        <div>
          <h2 className="text-sm font-semibold">Secrets</h2>
          <p className="text-xs text-muted-foreground">
            API keys and other secrets for your extensions, stored in the app database and injected
            into the extension host as <span className="font-mono">process.env</span> variables — so
            an extension can read <span className="font-mono">process.env.TAVILY_API_KEY</span> without
            you touching the machine's environment.
          </p>
        </div>
        <div className="flex-1" />
        {saved && (
          <span className="flex items-center gap-1 whitespace-nowrap text-xs text-tool">
            <Check className="size-3.5" /> Saved
          </span>
        )}
      </div>

      {names && names.length > 0 && (
        <div className="divide-y divide-border rounded-lg ring-1 ring-black/[0.06] dark:ring-white/[0.08]">
          {names.map((n) => (
            <div key={n} className="flex items-center gap-2.5 px-3 py-2 text-sm">
              <KeyRound className="size-4 text-muted-foreground" />
              <span className="font-mono font-medium">{n}</span>
              <span className="min-w-0 flex-1 truncate font-mono text-xs text-muted-foreground">
                ••••••••
              </span>
              <Button
                variant="ghost"
                size="icon"
                onClick={() => remove(n)}
                aria-label="Remove secret"
                className="size-7 text-muted-foreground hover:text-destructive"
              >
                <Trash2 className="size-4" />
              </Button>
            </div>
          ))}
        </div>
      )}

      <div className="flex items-end gap-2">
        <Input
          className="w-56 font-mono text-xs"
          placeholder="NAME (e.g. TAVILY_API_KEY)"
          value={name}
          onChange={(e) => setName(e.target.value)}
        />
        <Input
          className="flex-1 font-mono text-xs"
          type="password"
          placeholder="value"
          value={value}
          onChange={(e) => setValue(e.target.value)}
        />
        <Button disabled={!name.trim() || !value} onClick={() => void add()}>
          <Plus className="size-4" /> Add
        </Button>
      </div>
      {error && <p className="text-xs text-destructive">{error}</p>}
      <p className="text-xs text-muted-foreground">
        Applied on the next <span className="font-mono">/reload</span>. Values are write-only — they
        are never sent back to the browser.
      </p>
    </section>
  );
}
