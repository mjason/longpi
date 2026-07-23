import { CalendarClock, Loader2, Trash2 } from "lucide-react";
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";
import { buildCSRFHeaders, listConversations } from "../../ash_rpc";
import { Button } from "../../components/ui/button";
import { Switch } from "../../components/ui/switch";
import { cn } from "../../lib/utils";
import { useI18n } from "../i18n";
import {
  loadCronNexts,
  loadScheduledTasks,
  removeScheduledTask,
  type ScheduledTaskRow,
  setScheduledTask,
} from "../settings";

type ConversationInfo = { id: string; title: string | null };

/** Admin view over every conversation's cron schedules: toggle, inspect, delete. */
export function SchedulesSection() {
  const { t } = useI18n();
  const [tasks, setTasks] = useState<ScheduledTaskRow[]>([]);
  const [titles, setTitles] = useState<Map<string, string>>(new Map());
  const [nexts, setNexts] = useState<Record<string, string | null>>({});
  const [loading, setLoading] = useState(true);

  async function refresh() {
    const rows = await loadScheduledTasks();
    setTasks(rows);
    setNexts(await loadCronNexts([...new Set(rows.map((r) => r.cron))]));
  }

  useEffect(() => {
    Promise.all([
      refresh(),
      listConversations({ fields: ["id", "title"], headers: buildCSRFHeaders() }).then(
        (result) => {
          if (result.success) {
            const map = new Map<string, string>();
            for (const c of result.data as ConversationInfo[]) {
              map.set(c.id, c.title || c.id.slice(0, 8));
            }
            setTitles(map);
          }
        },
      ),
    ])
      .catch(() => {})
      // A failed load (server restarting) must not strand the spinner forever.
      .finally(() => setLoading(false));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  if (loading) return <Loader2 className="my-10 size-5 animate-spin text-muted-foreground" />;

  return (
    <div className="space-y-4 py-4">
      <p className="text-sm text-muted-foreground">{t("schedules.hint")}</p>

      {tasks.length === 0 && (
        <p className="text-sm text-muted-foreground">{t("schedules.empty")}</p>
      )}

      {tasks.length > 0 && (
        <div className="overflow-hidden rounded-lg ring-1 ring-black/[0.06] dark:ring-white/[0.08]">
          <div className="divide-y divide-border">
            {tasks.map((task) => (
              <div key={task.id} className="flex items-center gap-3 px-3 py-2 text-sm">
                <Switch
                  checked={task.enabled}
                  onCheckedChange={async (next: boolean) => {
                    setTasks((ts) =>
                      ts.map((x) => (x.id === task.id ? { ...x, enabled: next } : x)),
                    );
                    // Revert the optimistic flip on rejection OR thrown network
                    // error — a stuck switch would lie about the server state.
                    try {
                      const res = await setScheduledTask(task.id, { enabled: next });
                      if (!res.success) refresh();
                    } catch {
                      refresh();
                    }
                  }}
                  aria-label="Enabled"
                />
                <code
                  className={cn(
                    "shrink-0 rounded bg-muted/60 px-1.5 py-0.5 font-mono text-xs",
                    !task.enabled && "text-muted-foreground",
                  )}
                >
                  {task.cron}
                </code>
                <span className={cn("min-w-0 flex-1 truncate", !task.enabled && "text-muted-foreground")}>
                  {task.task}
                </span>
                <span className="hidden shrink-0 flex-col items-end text-[11px] text-muted-foreground sm:flex">
                  <Link to={`/c/${task.conversationId}`} className="hover:text-foreground hover:underline">
                    {titles.get(task.conversationId) ?? task.conversationId.slice(0, 8)}
                  </Link>
                  <span>
                    {task.enabled && nexts[task.cron]
                      ? `${t("schedules.next")} ${nexts[task.cron]}`
                      : task.lastRunAt
                        ? // lastRunAt is UTC; render it in the viewer's local time
                          // (next-run above is already server-local).
                          `${t("schedules.last")} ${new Date(task.lastRunAt).toLocaleString()}`
                        : t("schedules.never")}
                  </span>
                </span>
                <Button
                  variant="ghost"
                  size="icon"
                  onClick={async () => {
                    if (!confirm(t("schedules.confirmDelete"))) return;
                    try {
                      await removeScheduledTask(task.id);
                    } finally {
                      // Always re-sync: a failed destroy re-shows the row
                      // instead of silently pretending it's gone.
                      refresh();
                    }
                  }}
                  aria-label="Delete schedule"
                  className="size-7 text-muted-foreground hover:text-destructive"
                >
                  <Trash2 className="size-4" />
                </Button>
              </div>
            ))}
          </div>
        </div>
      )}

      <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
        <CalendarClock className="size-3.5" />
        {t("schedules.create.hint")}
      </p>
    </div>
  );
}
