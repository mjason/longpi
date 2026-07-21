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
import { useNavigate, useParams } from "react-router-dom";
import { Button } from "../components/ui/button";
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

/** The `/manage/:section` route: a full-screen management dashboard. */
export function ManagementRoute() {
  const { section } = useParams();
  const navigate = useNavigate();
  const active = (SECTIONS.some((s) => s.id === section) ? section : "general") as SectionId;

  return (
    <ManagementPanel
      active={active}
      onSelect={(id) => navigate(`/manage/${id}`)}
      onClose={() => navigate("/")}
    />
  );
}

/** Full-screen management dashboard: left-nav sections, right content. */
function ManagementPanel({
  active,
  onSelect,
  onClose,
}: {
  active: SectionId;
  onSelect: (id: SectionId) => void;
  onClose: () => void;
}) {
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
                    <Button
                      key={s.id}
                      variant={s.id === active ? "secondary" : "ghost"}
                      onClick={() => onSelect(s.id)}
                      className={cn(
                        "w-full justify-start gap-2.5 px-2.5 font-normal",
                        s.id === active
                          ? "font-medium"
                          : "text-muted-foreground hover:text-foreground",
                      )}
                    >
                      <s.icon className="size-4 shrink-0" />
                      {s.label}
                    </Button>
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
          <Button
            variant="ghost"
            size="sm"
            onClick={onClose}
            className="text-muted-foreground hover:text-foreground"
          >
            <X className="size-4" /> Close
          </Button>
        </header>

        <ScrollArea className="flex-1">
          <div className="mx-auto max-w-3xl px-8 pb-16">{section.render()}</div>
        </ScrollArea>
      </main>
    </div>
  );
}
