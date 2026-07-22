import { Bot, CheckCircle2, Loader2, ShieldAlert, XCircle, CircleSlash } from "lucide-react";
import { useEffect, useState, type FC } from "react";

import { Button } from "../components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "../components/ui/tooltip";
import { cn } from "../lib/utils";
import type { SubagentApproval, SubagentInfo } from "./channel";
import { useI18n } from "./i18n";

/**
 * Approvals a subagent bubbled up for the user to answer here — the child runs
 * hidden, so its tool-approval prompts surface in the parent's view. Allow/Deny
 * routes back to the child via the shared permission_response path.
 */
export function SubagentApprovals({
  approvals,
  onRespond,
  onOpen,
}: {
  approvals: Record<string, SubagentApproval>;
  onRespond: (id: string, approved: boolean) => void;
  onOpen: (conversationId: string) => void;
}) {
  const { t } = useI18n();
  const entries = Object.values(approvals);
  if (entries.length === 0) return null;

  return (
    <div className="flex flex-col gap-2 border-b border-border bg-amber-500/5 px-4 py-2.5">
      {entries.map((a) => (
        <div key={a.id} className="flex flex-wrap items-center gap-x-3 gap-y-2 text-sm">
          <ShieldAlert className="size-4 shrink-0 text-amber-500" />
          <span className="min-w-0">
            <button
              type="button"
              className="font-medium underline-offset-2 hover:underline"
              onClick={() => onOpen(a.conversationId)}
            >
              {a.handle}
            </button>{" "}
            {t("subagentApproval.wants")}{" "}
            <code className="rounded bg-muted px-1.5 py-0.5 font-mono text-xs">{a.name}</code>
          </span>
          <div className="ml-auto flex items-center gap-2">
            <Button size="sm" variant="ghost" onClick={() => onRespond(a.id, false)}>
              {t("subagentApproval.deny")}
            </Button>
            <Button size="sm" onClick={() => onRespond(a.id, true)}>
              {t("subagentApproval.allow")}
            </Button>
          </div>
        </div>
      ))}
    </div>
  );
}

/**
 * Live strip of the subagents this conversation has spawned. One chip per
 * child — role, status, elapsed — clicking through to the child conversation
 * (a real conversation page streaming in real time).
 */
export function SubagentsBar({
  agents,
  onOpen,
}: {
  agents: Record<string, SubagentInfo>;
  onOpen: (conversationId: string) => void;
}) {
  const { t } = useI18n();
  const entries = Object.entries(agents);
  if (entries.length === 0) return null;

  return (
    <div className="flex flex-wrap items-center gap-2 border-b border-border bg-secondary/30 px-4 py-2">
      <span className="flex items-center gap-1.5 text-xs font-medium text-muted-foreground">
        <Bot className="size-3.5" />
        {t("subagents.title")}
      </span>
      {entries.map(([handle, info]) => (
        <AgentChip key={handle} handle={handle} info={info} onOpen={onOpen} />
      ))}
    </div>
  );
}

const STATUS_ICON: Record<SubagentInfo["status"], FC<{ className?: string }>> = {
  running: ({ className }) => (
    <Loader2 className={cn("animate-spin text-blue-500", className)} />
  ),
  done: ({ className }) => <CheckCircle2 className={cn("text-emerald-500", className)} />,
  failed: ({ className }) => <XCircle className={cn("text-red-500", className)} />,
  closed: ({ className }) => <CircleSlash className={cn("text-muted-foreground", className)} />,
};

function AgentChip({
  handle,
  info,
  onOpen,
}: {
  handle: string;
  info: SubagentInfo;
  onOpen: (conversationId: string) => void;
}) {
  const { t } = useI18n();
  const Icon = STATUS_ICON[info.status] ?? STATUS_ICON.closed;

  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <Button
          variant="ghost"
          size="sm"
          className="h-7 gap-1.5 rounded-full bg-background px-2.5 text-xs shadow-sm ring-1 ring-black/[0.06] dark:ring-white/[0.08]"
          onClick={() => onOpen(info.conversationId)}
        >
          <Icon className="size-3.5" />
          <span className="font-medium">{handle}</span>
          <Elapsed startedAt={info.startedAt} running={info.status === "running"} />
        </Button>
      </TooltipTrigger>
      <TooltipContent side="bottom" className="max-w-xs">
        <p className="font-medium">{info.task}</p>
        <p className="text-muted-foreground">{t(`subagents.status.${info.status}`)} · {t("subagents.clickToOpen")}</p>
      </TooltipContent>
    </Tooltip>
  );
}

/** "12s" / "3m05s", ticking while the agent runs. */
function Elapsed({ startedAt, running }: { startedAt: number; running: boolean }) {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));

  useEffect(() => {
    if (!running) return;
    const timer = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(timer);
  }, [running]);

  const seconds = Math.max(0, now - startedAt);
  const label =
    seconds < 60
      ? `${seconds}s`
      : `${Math.floor(seconds / 60)}m${String(seconds % 60).padStart(2, "0")}s`;

  return <span className="tabular-nums text-muted-foreground">{label}</span>;
}
