import { Check, ChevronDown, Eye, Shield, ShieldAlert } from "lucide-react";
import { useEffect, useState } from "react";
import { cn } from "../lib/utils";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "../components/ui/dropdown-menu";
import { APPROVAL_LEVELS, loadSettings, saveSetting, SETTING_KEYS } from "./settings";

const ICONS: Record<string, typeof Shield> = {
  read_only: Eye,
  auto: Shield,
  full: ShieldAlert,
};

/**
 * Codex-style approval-level switch in the composer: shows the current level
 * and lets the user change it inline. The level is a global setting the
 * Session reads live, so changes apply to the next tool call immediately.
 */
export function ApprovalLevelChip() {
  const [level, setLevel] = useState("auto");

  useEffect(() => {
    loadSettings().then((s) => setLevel(s[SETTING_KEYS.approvalLevel] || "auto"));
  }, []);

  const current = APPROVAL_LEVELS.find((l) => l.id === level) ?? APPROVAL_LEVELS[1];
  const Icon = ICONS[current.id] ?? Shield;
  const isFull = current.id === "full";

  async function choose(id: string) {
    setLevel(id);
    await saveSetting(SETTING_KEYS.approvalLevel, id);
  }

  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <button
          type="button"
          className={cn(
            "flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs transition-colors hover:bg-accent",
            isFull ? "text-destructive" : "text-muted-foreground",
          )}
        >
          <Icon className="size-4" />
          <span>{current.label}</span>
          <ChevronDown className="size-3.5 opacity-60" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent side="top" align="start" className="w-72">
        {APPROVAL_LEVELS.map((lvl) => {
          const LvlIcon = ICONS[lvl.id] ?? Shield;
          const selected = lvl.id === level;
          return (
            <DropdownMenuItem
              key={lvl.id}
              onSelect={() => choose(lvl.id)}
              className="items-start gap-2.5 py-2"
            >
              <LvlIcon
                className={cn(
                  "mt-0.5 size-4 shrink-0",
                  lvl.id === "full" ? "text-destructive" : "text-muted-foreground",
                )}
              />
              <div className="min-w-0 flex-1">
                <div className="flex items-center gap-1.5 text-sm font-medium">
                  {lvl.label}
                  {selected && <Check className="size-3.5 text-primary" />}
                </div>
                <div className="text-xs leading-tight text-muted-foreground">{lvl.hint}</div>
              </div>
            </DropdownMenuItem>
          );
        })}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
