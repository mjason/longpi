// The right-hand workspace sidebar shell: hosts the file tree or the git
// panel (mutually exclusive, dala's layout), docked column on md+ and a
// right-side sheet on mobile. Git status is fetched HERE so the file tree's
// badges and the git panel share one poller.

import { useEffect, useState } from "react";

import { Sheet, SheetContent, SheetTitle } from "../../components/ui/sheet";
import { useI18n } from "../i18n";
import { FilesPanel } from "./FilesPanel";
import { GitPanel, useGitStatus } from "./GitPanel";

export type WorkspaceTab = "files" | "git";

const STORAGE_KEY = "longpi:workspace-panel";

export function loadWorkspaceTab(): WorkspaceTab | null {
  try {
    const stored = localStorage.getItem(STORAGE_KEY);
    return stored === "files" || stored === "git" ? stored : null;
  } catch {
    return null;
  }
}

export function storeWorkspaceTab(tab: WorkspaceTab | null) {
  try {
    if (tab) localStorage.setItem(STORAGE_KEY, tab);
    else localStorage.removeItem(STORAGE_KEY);
  } catch {
    // sandboxed iframe — the choice just won't persist
  }
}

export function WorkspacePanel({
  cwd,
  tab,
  onClose,
}: {
  cwd: string;
  tab: WorkspaceTab;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const { status, refresh } = useGitStatus(cwd);
  const mobile = useIsMobile();

  const body =
    tab === "files" ? (
      <FilesPanel cwd={cwd} gitStatus={status} />
    ) : (
      <GitPanel cwd={cwd} status={status} refresh={refresh} />
    );

  // One rendering per breakpoint — an always-open Sheet on desktop would
  // leave its dim overlay over the whole app (the left drawer had this bug).
  if (!mobile) {
    return (
      <aside className="flex w-80 shrink-0 flex-col border-l border-border bg-card/20 lg:w-96">
        {body}
      </aside>
    );
  }

  return (
    <Sheet open onOpenChange={(open: boolean) => !open && onClose()}>
      <SheetContent side="right" className="w-[85vw] max-w-96 gap-0 p-0">
        <SheetTitle className="sr-only">
          {tab === "files" ? t("ws.files") : t("ws.git")}
        </SheetTitle>
        <div className="flex h-full min-h-0 flex-col pt-[env(safe-area-inset-top)]">{body}</div>
      </SheetContent>
    </Sheet>
  );
}

function useIsMobile(): boolean {
  const [mobile, setMobile] = useState(
    () => typeof window !== "undefined" && window.matchMedia("(max-width: 767px)").matches,
  );

  useEffect(() => {
    const mq = window.matchMedia("(max-width: 767px)");
    const onChange = () => setMobile(mq.matches);
    mq.addEventListener("change", onChange);
    return () => mq.removeEventListener("change", onChange);
  }, []);

  return mobile;
}
