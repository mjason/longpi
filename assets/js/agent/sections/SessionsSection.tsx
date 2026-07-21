import { Loader2, Power, RefreshCw } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "../../components/ui/button";
import { cn } from "../../lib/utils";
import { loadSessions, type SessionRow, stopSession } from "../settings";

function basename(cwd: string): string {
  const parts = cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? cwd;
}

export function SessionsSection() {
  const [rows, setRows] = useState<SessionRow[]>([]);
  const [loading, setLoading] = useState(true);

  const refresh = () =>
    loadSessions().then((s) => {
      setRows(s);
      setLoading(false);
    });

  useEffect(() => {
    refresh();
    // Live-ish: poll while the panel is open.
    const t = setInterval(refresh, 3000);
    return () => clearInterval(t);
  }, []);

  if (loading) return <Loader2 className="my-10 size-5 animate-spin text-muted-foreground" />;

  return (
    <div className="space-y-4 py-4">
      <div className="flex items-center gap-3">
        <p className="text-sm text-muted-foreground">
          {rows.length} live session{rows.length === 1 ? "" : "s"}. A session process runs per open
          conversation and outlives the browser tab.
        </p>
        <div className="flex-1" />
        <Button size="sm" variant="ghost" onClick={refresh}>
          <RefreshCw className="size-4" /> Refresh
        </Button>
      </div>

      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">No sessions running right now.</p>
      ) : (
        <div className="space-y-2">
          {rows.map((s) => (
            <div
              key={s.conversation_id}
              className="flex items-center gap-3 rounded-lg ring-1 ring-black/[0.06] dark:ring-white/[0.08] px-3 py-2.5"
            >
              <span
                className={cn(
                  "size-2 shrink-0 rounded-full",
                  s.status === "running"
                    ? "bg-primary animate-pulse"
                    : s.status === "idle"
                      ? "bg-emerald-500"
                      : "bg-amber-500",
                )}
                title={s.status}
              />
              <div className="min-w-0 flex-1">
                <div className="truncate text-sm font-medium">{basename(s.cwd)}</div>
                <div className="truncate font-mono text-xs text-muted-foreground">{s.cwd}</div>
              </div>
              <span className="w-40 truncate font-mono text-xs text-muted-foreground">{s.model}</span>
              <span className="w-32 text-xs text-muted-foreground">
                {s.tools} tools
                {s["extensions?"] ? ` · ${s.commands} cmds` : ""}
              </span>
              <span className="w-16 text-xs capitalize text-muted-foreground">{s.status}</span>
              <Button
                size="icon"
                variant="ghost"
                className="size-7"
                title="Stop session"
                onClick={async () => {
                  await stopSession(s.conversation_id);
                  refresh();
                }}
              >
                <Power className="size-4 text-destructive" />
              </Button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
