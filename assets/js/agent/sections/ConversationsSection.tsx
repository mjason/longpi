import { Loader2, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { buildCSRFHeaders, destroyConversation, listConversations } from "../../ash_rpc";
import { Button } from "../../components/ui/button";
import { Checkbox } from "../../components/ui/checkbox";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "../../components/ui/table";

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
    const results = await Promise.all(
      ids.map((id) => destroyConversation({ identity: id, headers: buildCSRFHeaders() })),
    );
    if (results.some((r) => !r.success)) {
      alert("Some conversations couldn't be deleted. Please try again.");
    }
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
          <Table>
            <TableHeader>
              <TableRow className="bg-muted/40 hover:bg-muted/40">
                <TableHead className="w-8">
                  <Checkbox
                    checked={allSelected}
                    onCheckedChange={() =>
                      setSelected(allSelected ? new Set() : new Set(rows.map((r) => r.id)))
                    }
                    aria-label="Select all"
                  />
                </TableHead>
                <TableHead>Conversation</TableHead>
                <TableHead className="w-48">Model</TableHead>
                <TableHead className="w-28">Created</TableHead>
                <TableHead className="w-8" />
              </TableRow>
            </TableHeader>
            <TableBody>
              {rows.map((row) => (
                <TableRow key={row.id} data-state={selected.has(row.id) ? "selected" : undefined}>
                  <TableCell>
                    <Checkbox
                      checked={selected.has(row.id)}
                      onCheckedChange={() => toggle(row.id)}
                      aria-label="Select"
                    />
                  </TableCell>
                  <TableCell className="min-w-0">
                    <div className="truncate font-medium">{label(row)}</div>
                    <div className="truncate font-mono text-xs text-muted-foreground">
                      {row.cwd}
                    </div>
                  </TableCell>
                  <TableCell className="truncate font-mono text-xs text-muted-foreground">
                    {row.model}
                  </TableCell>
                  <TableCell className="text-xs text-muted-foreground">
                    {new Date(row.insertedAt).toLocaleDateString()}
                  </TableCell>
                  <TableCell>
                    <button
                      onClick={() => remove([row.id])}
                      aria-label="Delete conversation"
                      className="rounded-md p-1 text-muted-foreground hover:bg-background hover:text-destructive"
                    >
                      <Trash2 className="size-4" />
                    </button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
    </div>
  );
}
