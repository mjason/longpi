import {
  Blocks,
  Boxes,
  Cpu,
  Frame,
  KeyRound,
  MessagesSquare,
  SlidersHorizontal,
  UsersRound,
  Wrench,
  X,
} from "lucide-react";
import { useNavigate, useParams } from "react-router-dom";
import { Button } from "../components/ui/button";
import { ScrollArea } from "../components/ui/scroll-area";
import { cn } from "../lib/utils";
import { useI18n } from "./i18n";
import type { I18nKey } from "./i18n";
import { LanguageToggle } from "./LanguageToggle";
import { ThemeToggle } from "./ThemeToggle";
import { ConversationsSection } from "./sections/ConversationsSection";
import { EmbedSection } from "./sections/EmbedSection";
import { UsersSection } from "./sections/UsersSection";
import { ModelsSection } from "./sections/ModelsSection";
import { ExtensionsSection } from "./sections/ExtensionsSection";
import { SessionsSection } from "./sections/SessionsSection";
import { GeneralTab, ProvidersTab, ToolsTab } from "./SettingsDialog";

type SectionId =
  | "general"
  | "providers"
  | "models"
  | "tools"
  | "users"
  | "extensions"
  | "embed"
  | "conversations"
  | "sessions";

type Section = {
  id: SectionId;
  label: I18nKey;
  description: I18nKey;
  icon: typeof SlidersHorizontal;
  group: I18nKey;
  render: () => React.ReactNode;
};

const SECTIONS: Section[] = [
  {
    id: "general",
    label: "manage.general",
    description: "manage.general.desc",
    icon: SlidersHorizontal,
    group: "manage.group.agent",
    render: () => <GeneralTab />,
  },
  {
    id: "providers",
    label: "manage.providers",
    description: "manage.providers.desc",
    icon: KeyRound,
    group: "manage.group.agent",
    render: () => <ProvidersTab />,
  },
  {
    id: "models",
    label: "manage.models",
    description: "manage.models.desc",
    icon: Cpu,
    group: "manage.group.agent",
    render: () => <ModelsSection />,
  },
  {
    id: "tools",
    label: "manage.tools",
    description: "manage.tools.desc",
    icon: Wrench,
    group: "manage.group.agent",
    render: () => <ToolsTab />,
  },
  {
    id: "users",
    label: "manage.users",
    description: "manage.users.desc",
    icon: UsersRound,
    group: "manage.group.agent",
    render: () => <UsersSection />,
  },
  {
    id: "extensions",
    label: "manage.extensions",
    description: "manage.extensions.desc",
    icon: Blocks,
    group: "manage.group.extend",
    render: () => <ExtensionsSection />,
  },
  {
    id: "embed",
    label: "manage.embed",
    description: "manage.embed.desc",
    icon: Frame,
    group: "manage.group.extend",
    render: () => <EmbedSection />,
  },
  {
    id: "conversations",
    label: "manage.conversations",
    description: "manage.conversations.desc",
    icon: MessagesSquare,
    group: "manage.group.data",
    render: () => <ConversationsSection />,
  },
  {
    id: "sessions",
    label: "manage.sessions",
    description: "manage.sessions.desc",
    icon: Boxes,
    group: "manage.group.data",
    render: () => <SessionsSection />,
  },
];

const GROUPS: I18nKey[] = ["manage.group.agent", "manage.group.extend", "manage.group.data"];

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
  const { t } = useI18n();
  const section = SECTIONS.find((s) => s.id === active) ?? SECTIONS[0];

  return (
    <div className="fixed inset-0 z-40 flex bg-background text-foreground">
      <aside className="flex w-60 shrink-0 flex-col border-r border-border bg-card/30">
        <div className="flex items-center gap-2 px-5 py-4 font-semibold tracking-wide">
          <span className="text-primary">π</span> {t("manage.title")}
        </div>
        <ScrollArea className="flex-1">
          <nav className="space-y-5 px-3 py-2">
            {GROUPS.map((group) => (
              <div key={group}>
                <div className="px-2 pb-1 text-[11px] font-medium uppercase tracking-wider text-muted-foreground/70">
                  {t(group)}
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
                      {t(s.label)}
                    </Button>
                  ))}
                </div>
              </div>
            ))}
          </nav>
        </ScrollArea>
      </aside>

      <main className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-center gap-3 border-b border-border px-8 py-5">
          <div className="min-w-0">
            <h1 className="text-lg font-semibold">{t(section.label)}</h1>
            <p className="mt-0.5 text-sm text-muted-foreground">{t(section.description)}</p>
          </div>
          <div className="flex-1" />
          <div className="flex items-center gap-1">
            <LanguageToggle />
            <ThemeToggle />
            <Button
              variant="ghost"
              size="sm"
              onClick={onClose}
              className="text-muted-foreground hover:text-foreground"
            >
              <X className="size-4" /> {t("manage.close")}
            </Button>
          </div>
        </header>

        <ScrollArea className="flex-1">
          <div className="mx-auto max-w-3xl px-8 pb-16">{section.render()}</div>
        </ScrollArea>
      </main>
    </div>
  );
}
