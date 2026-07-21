import { Loader2, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { buildCSRFHeaders, destroyConversation, listConversations } from "../../ash_rpc";
import { Button } from "../../components/ui/button";
import { Checkbox } from "../../components/ui/checkbox";
import { cn } from "../../lib/utils";

type Row = { id: string; title: string | null; cwd: string; model: string; insertedAt: string };

function label(row: Row): string {
  if (row.title) return row.title;
  const parts = row.cwd.split("/").filter(Boolean);
  return parts[parts.length - 1] ?? row.cwd;
}

export function ConversationsSection() {
  const [rows, setRows] = useState<Row[]>([]);
  const [loading, setLoading] = useState(true);
  const [selected, setSelected] = useState<Set<string>>(new Set());

  const refresh = () =>
    listConversations({
      fields: ["id", "title", "cwd", "model", "insertedAt"],
      sort: "-insertedAt",
      headers: buildCSRFHeaders(),
    }).then((r) => {
      if (r.success) setRows(r.data as Row[]);
    });

  useEffect(() => {
    refresh().then(() => setLoading(false));
  }, []);

  async function remove(ids: string[]) {
    if (!confirm(`Delete ${ids.length} conversation${ids.length === 1 ? "" : "s"}? This cannot be undone.`))
      return;
    await Promise.all(ids.map((id) => destroyConversation({ identity: id, headers: buildCSRFHeaders() })));
    setSelected(new Set());
    await refresh();
  }

  function toggle(id: string) {
    setSelected((s) => {
      const next = new Set(s);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  }

  if (loading) return <Loader2 className="my-10 size-5 animate-spin text-muted-foreground" />;

  const allSelected = rows.length > 0 && selected.size === rows.length;

  return (
    <div className="space-y-4 py-4">
      <div className="flex items-center gap-3">
        <p className="text-sm text-muted-foreground">
          {rows.length} conversation{rows.length === 1 ? "" : "s"}. The full message history is stored per
          conversation.
        </p>
        <div className="flex-1" />
        {selected.size > 0 && (
          <Button size="sm" variant="outline" onClick={() => remove([...selected])}>
            <Trash2 className="size-4 text-destructive" /> Delete {selected.size}
          </Button>
        )}
      </div>

      {rows.length === 0 ? (
        <p className="text-sm text-muted-foreground">No conversations yet.</p>
      ) : (
        <div className="overflow-hidden rounded-lg ring-1 ring-black/[0.06] dark:ring-white/[0.08]">
          <div className="flex items-center gap-3 border-b border-border bg-muted/40 px-3 py-2 text-xs font-medium text-muted-foreground">
            <Checkbox
              checked={allSelected}
              onCheckedChange={() =>
                setSelected(allSelected ? new Set() : new Set(rows.map((r) => r.id)))
              }
              aria-label="Select all"
            />
            <span className="flex-1">Conversation</span>
            <span className="w-48">Model</span>
            <span className="w-28">Created</span>
            <span className="w-8" />
          </div>
          {rows.map((row) => (
            <div
              key={row.id}
              className={cn(
                "flex items-center gap-3 border-b border-border px-3 py-2.5 text-sm last:border-0",
                selected.has(row.id) && "bg-accent/40",
              )}
            >
              <Checkbox
                checked={selected.has(row.id)}
                onCheckedChange={() => toggle(row.id)}
                aria-label="Select"
              />
              <div className="min-w-0 flex-1">
                <div className="truncate font-medium">{label(row)}</div>
                <div className="truncate font-mono text-xs text-muted-foreground">{row.cwd}</div>
              </div>
              <span className="w-48 truncate font-mono text-xs text-muted-foreground">{row.model}</span>
              <span className="w-28 text-xs text-muted-foreground">
                {new Date(row.insertedAt).toLocaleDateString()}
              </span>
              <button
                onClick={() => remove([row.id])}
                aria-label="Delete conversation"
                className="rounded-md p-1 text-muted-foreground hover:bg-background hover:text-destructive"
              >
                <Trash2 className="size-4" />
              </button>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
