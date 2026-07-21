import { Check, FileCode, Folder, Loader2, Package, Plus, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { Badge } from "../../components/ui/badge";
import { Button } from "../../components/ui/button";
import { Input } from "../../components/ui/input";
import { type GlobalExtensions, loadGlobalExtensions, saveGlobalPackages } from "../settings";

export function ExtensionsSection() {
  const [data, setData] = useState<GlobalExtensions | null>(null);
  const [packages, setPackages] = useState<[string, string][]>([]);
  const [name, setName] = useState("");
  const [spec, setSpec] = useState("");
  const [saved, setSaved] = useState(false);

  useEffect(() => {
    loadGlobalExtensions().then((d) => {
      setData(d);
      setPackages(Object.entries(d.packages));
    });
  }, []);

  if (!data) return <Loader2 className="my-10 size-5 animate-spin text-muted-foreground" />;

  async function persist(next: [string, string][]) {
    setPackages(next);
    const ok = await saveGlobalPackages(Object.fromEntries(next));
    if (!ok) {
      alert("Could not save packages. Please try again.");
      return;
    }
    setSaved(true);
    setTimeout(() => setSaved(false), 1500);
  }

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

      <section className="space-y-3">
        <div className="flex items-center gap-2">
          <div>
            <h2 className="text-sm font-semibold">Packages</h2>
            <p className="text-xs text-muted-foreground">
              npm / git / local packages installed with <span className="font-mono">bun install</span>{" "}
              and loaded via their <span className="font-mono">longpi.extensions</span> manifest.
            </p>
          </div>
          <div className="flex-1" />
          {saved && (
            <span className="flex items-center gap-1 text-xs text-tool">
              <Check className="size-3.5" /> Saved
            </span>
          )}
        </div>

        {packages.length > 0 && (
          <div className="divide-y divide-border rounded-lg ring-1 ring-black/[0.06] dark:ring-white/[0.08]">
            {packages.map(([n, s]) => (
              <div key={n} className="flex items-center gap-2.5 px-3 py-2 text-sm">
                <Package className="size-4 text-muted-foreground" />
                <span className="font-mono font-medium">{n}</span>
                <span className="min-w-0 flex-1 truncate font-mono text-xs text-muted-foreground">{s}</span>
                <button
                  onClick={() => persist(packages.filter(([k]) => k !== n))}
                  aria-label="Remove package"
                  className="rounded-md p-1 text-muted-foreground hover:text-destructive"
                >
                  <Trash2 className="size-4" />
                </button>
              </div>
            ))}
          </div>
        )}

        <div className="flex items-end gap-2">
          <Input
            className="w-40 font-mono text-xs"
            placeholder="name"
            value={name}
            onChange={(e) => setName(e.target.value)}
          />
          <Input
            className="flex-1 font-mono text-xs"
            placeholder="spec (^1.2.0 · github:user/repo · file:/path)"
            value={spec}
            onChange={(e) => setSpec(e.target.value)}
          />
          <Button
            disabled={!name.trim() || !spec.trim()}
            onClick={() => {
              persist([...packages.filter(([k]) => k !== name.trim()), [name.trim(), spec.trim()]]);
              setName("");
              setSpec("");
            }}
          >
            <Plus className="size-4" /> Add
          </Button>
        </div>
        <p className="text-xs text-muted-foreground">
          Saved to <code className="rounded bg-muted px-1 py-0.5 font-mono">~/.longpi/packages.json</code>;
          installed on the next <span className="font-mono">/reload</span>.
        </p>
      </section>
    </div>
  );
}
