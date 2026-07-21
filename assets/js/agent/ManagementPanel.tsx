import {
  Blocks,
  Boxes,
  Cpu,
  KeyRound,
  MessagesSquare,
  SlidersHorizontal,
  Wrench,
  X,
} from "lucide-react";
import { useState } from "react";
import { ScrollArea } from "../components/ui/scroll-area";
import { cn } from "../lib/utils";
import { ConversationsSection } from "./sections/ConversationsSection";
import { ModelsSection } from "./sections/ModelsSection";
import { ExtensionsSection } from "./sections/ExtensionsSection";
import { SessionsSection } from "./sections/SessionsSection";
import { GeneralTab, ProvidersTab, ToolsTab } from "./SettingsDialog";

type SectionId =
  | "general"
  | "providers"
  | "models"
  | "tools"
  | "extensions"
  | "conversations"
  | "sessions";

type Section = {
  id: SectionId;
  label: string;
  description: string;
  icon: typeof SlidersHorizontal;
  group: string;
  render: () => React.ReactNode;
};

const SECTIONS: Section[] = [
  {
    id: "general",
    label: "General",
    description: "Approval, default model, system prompt, and context compaction.",
    icon: SlidersHorizontal,
    group: "Agent",
    render: () => <GeneralTab />,
  },
  {
    id: "providers",
    label: "Providers",
    description: "LLM provider credentials and OpenAI-compatible gateways.",
    icon: KeyRound,
    group: "Agent",
    render: () => <ProvidersTab />,
  },
  {
    id: "models",
    label: "Models",
    description: "The models available to new conversations.",
    icon: Cpu,
    group: "Agent",
    render: () => <ModelsSection />,
  },
  {
    id: "tools",
    label: "Prompts & Tools",
    description: "The description each built-in tool advertises to the model.",
    icon: Wrench,
    group: "Agent",
    render: () => <ToolsTab />,
  },
  {
    id: "extensions",
    label: "Extensions",
    description: "Global extensions and installed packages.",
    icon: Blocks,
    group: "Extend",
    render: () => <ExtensionsSection />,
  },
  {
    id: "conversations",
    label: "Conversations",
    description: "Every conversation, with usage and cleanup.",
    icon: MessagesSquare,
    group: "Data",
    render: () => <ConversationsSection />,
  },
  {
    id: "sessions",
    label: "Sessions",
    description: "Live agent processes running right now.",
    icon: Boxes,
    group: "Data",
    render: () => <SessionsSection />,
  },
];

const GROUPS = ["Agent", "Extend", "Data"];

/** Full-screen management dashboard: left-nav sections, right content. */
export function ManagementPanel({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [active, setActive] = useState<SectionId>("general");
  if (!open) return null;

  const section = SECTIONS.find((s) => s.id === active) ?? SECTIONS[0];

  return (
    <div className="fixed inset-0 z-40 flex bg-background text-foreground">
      <aside className="flex w-60 shrink-0 flex-col border-r border-border bg-card/30">
        <div className="flex items-center gap-2 px-5 py-4 font-semibold tracking-wide">
          <span className="text-primary">π</span> Management
        </div>
        <ScrollArea className="flex-1">
          <nav className="space-y-5 px-3 py-2">
            {GROUPS.map((group) => (
              <div key={group}>
                <div className="px-2 pb-1 text-[11px] font-medium uppercase tracking-wider text-muted-foreground/70">
                  {group}
                </div>
                <div className="space-y-0.5">
                  {SECTIONS.filter((s) => s.group === group).map((s) => (
                    <button
                      key={s.id}
                      onClick={() => setActive(s.id)}
                      className={cn(
                        "flex w-full items-center gap-2.5 rounded-md px-2.5 py-2 text-sm transition-colors",
                        s.id === active
                          ? "bg-accent font-medium text-foreground"
                          : "text-muted-foreground hover:bg-accent/50 hover:text-foreground",
                      )}
                    >
                      <s.icon className="size-4 shrink-0" />
                      {s.label}
                    </button>
                  ))}
                </div>
              </div>
            ))}
          </nav>
        </ScrollArea>
      </aside>

      <main className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-start gap-3 border-b border-border px-8 py-5">
          <div className="min-w-0">
            <h1 className="text-lg font-semibold">{section.label}</h1>
            <p className="mt-0.5 text-sm text-muted-foreground">{section.description}</p>
          </div>
          <div className="flex-1" />
          <button
            onClick={onClose}
            className="flex items-center gap-1.5 rounded-md px-2.5 py-1.5 text-sm text-muted-foreground transition-colors hover:bg-accent hover:text-foreground"
          >
            <X className="size-4" /> Close
          </button>
        </header>

        <ScrollArea className="flex-1">
          <div className="mx-auto max-w-3xl px-8 pb-16">{section.render()}</div>
        </ScrollArea>
      </main>
    </div>
  );
}
