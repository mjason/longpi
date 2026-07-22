import { Bot, CheckCircle2, Loader2, XCircle, CircleSlash } from "lucide-react";
import { useEffect, useState, type FC } from "react";

import { Button } from "../components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "../components/ui/tooltip";
import { cn } from "../lib/utils";
import type { SubagentInfo } from "./channel";
import { useI18n } from "./i18n";

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
