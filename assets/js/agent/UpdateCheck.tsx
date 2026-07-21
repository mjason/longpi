import { ArrowUpCircle, Loader2 } from "lucide-react";
import { useEffect, useState } from "react";
import { applyUpgrade, checkVersion, type VersionInfo } from "./settings";

/** The server version embedded in the page at load, shown before the check answers. */
function embeddedVersion(): string | null {
  const meta = document.querySelector('meta[name="longpi-version"]');
  return meta?.getAttribute("content")?.trim() || null;
}

/**
 * Offer the upgrade only when the server is an installed release that GitHub has
 * a newer, named version for. A dev/`mix` run reports `enabled: false`.
 */
export function shouldOfferUpdate(info: VersionInfo | null): boolean {
  return Boolean(info?.enabled && info?.updateAvailable && info?.latest);
}

/**
 * Sidebar-footer self-upgrade. On mount it asks the server whether GitHub has a
 * newer release; when one exists (installed releases only) it offers a one-click
 * upgrade. The daemon swaps its `current` symlink and restarts — the page waits
 * for it to answer again, then reloads onto the new version.
 */
export function UpdateCheck() {
  const [info, setInfo] = useState<VersionInfo | null>(null);
  const [state, setState] = useState<"idle" | "updating" | "restarting">("idle");
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    void checkVersion().then((v) => {
      if (!cancelled && v) setInfo(v);
    });
    return () => {
      cancelled = true;
    };
  }, []);

  const current = info?.current ?? embeddedVersion();
  if (!current) return null;

  const available = shouldOfferUpdate(info);

  async function update() {
    setState("updating");
    setError(null);
    const result = await applyUpgrade();
    if (!result.ok) {
      setState("idle");
      setError(result.error ?? "Update failed");
      return;
    }

    // The daemon restarts underneath us; reload once it answers again.
    setState("restarting");
    await new Promise((r) => setTimeout(r, 3000));
    for (let i = 0; i < 120; i++) {
      try {
        const res = await fetch("/", { cache: "no-store" });
        if (res.ok) break;
      } catch {
        // still restarting
      }
      await new Promise((r) => setTimeout(r, 1000));
    }
    location.reload();
  }

  return (
    <div className="shrink-0 border-t border-border px-3 py-2">
      <div className="flex items-center justify-between gap-2">
        <span className="font-mono text-[11px] text-muted-foreground" title="Server version">
          v{current}
        </span>

        {available && state === "idle" && (
          <button
            onClick={() => void update()}
            title={info?.notesUrl ? "See release notes" : undefined}
            className="inline-flex shrink-0 items-center gap-1 rounded-full bg-primary/10 px-2 py-0.5 font-mono text-[11px] font-medium text-primary ring-1 ring-primary/20 transition-colors hover:bg-primary/15"
          >
            <ArrowUpCircle className="size-3" />
            Update to v{info?.latest}
          </button>
        )}

        {state === "updating" && (
          <span className="inline-flex items-center gap-1 font-mono text-[11px] text-primary">
            <Loader2 className="size-3 animate-spin" />
            Updating…
          </span>
        )}
        {state === "restarting" && (
          <span className="inline-flex items-center gap-1 font-mono text-[11px] text-primary">
            <Loader2 className="size-3 animate-spin" />
            Restarting…
          </span>
        )}
      </div>
      {error && <div className="mt-1 text-[11px] text-destructive">{error}</div>}
    </div>
  );
}
