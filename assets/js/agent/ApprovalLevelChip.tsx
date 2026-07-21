import { Check, ChevronDown, Eye, Shield, ShieldAlert } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { cn } from "../lib/utils";
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
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    loadSettings().then((s) => setLevel(s[SETTING_KEYS.approvalLevel] || "auto"));
  }, []);

  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener("mousedown", onClick);
    return () => document.removeEventListener("mousedown", onClick);
  }, [open]);

  const current = APPROVAL_LEVELS.find((l) => l.id === level) ?? APPROVAL_LEVELS[1];
  const Icon = ICONS[current.id] ?? Shield;
  const isFull = current.id === "full";

  async function choose(id: string) {
    setLevel(id);
    setOpen(false);
    await saveSetting(SETTING_KEYS.approvalLevel, id);
  }

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className={cn(
          "flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs transition-colors hover:bg-accent",
          isFull ? "text-destructive" : "text-muted-foreground",
        )}
      >
        <Icon className="size-4" />
        <span>{current.label}</span>
        <ChevronDown className="size-3.5 opacity-60" />
      </button>

      {open && (
        <div className="absolute bottom-full left-0 z-50 mb-2 w-72 rounded-xl border-0 bg-popover p-1 shadow-[0_12px_40px_-8px_rgba(0,0,0,0.18),0_2px_10px_-2px_rgba(0,0,0,0.08)] ring-1 ring-black/[0.06] dark:shadow-[0_12px_40px_-8px_rgba(0,0,0,0.5)] dark:ring-white/[0.08]">
          {APPROVAL_LEVELS.map((lvl) => {
            const LvlIcon = ICONS[lvl.id] ?? Shield;
            const selected = lvl.id === level;
            return (
              <button
                key={lvl.id}
                type="button"
                onClick={() => choose(lvl.id)}
                className="flex w-full items-start gap-2.5 rounded-md px-2.5 py-2 text-left hover:bg-accent"
              >
                <LvlIcon
                  className={cn("mt-0.5 size-4 shrink-0", lvl.id === "full" ? "text-destructive" : "text-muted-foreground")}
                />
                <div className="min-w-0 flex-1">
                  <div className="flex items-center gap-1.5 text-sm font-medium">
                    {lvl.label}
                    {selected && <Check className="size-3.5 text-primary" />}
                  </div>
                  <div className="text-xs leading-tight text-muted-foreground">{lvl.hint}</div>
                </div>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}
