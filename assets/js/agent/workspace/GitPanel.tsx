// The git panel (dala's GitPanel on shadcn primitives): branch header,
// Changes tab (staged/unstaged rows with stage/unstage/discard, commit box
// with amend), History tab (recent commits → full patch), and a diff dialog
// that renders side-by-side via the vendored DiffViewer (both sides fetched
// through git_file_at, falling back to the unified patch for binary/huge).

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { GitBranch, Minus, Plus, RefreshCw, Undo2 } from "lucide-react";

import { Button } from "../../components/ui/button";
import { Checkbox } from "../../components/ui/checkbox";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "../../components/ui/dialog";
import { ScrollArea } from "../../components/ui/scroll-area";
import { Tabs, TabsList, TabsTrigger } from "../../components/ui/tabs";
import { Textarea } from "../../components/ui/textarea";
import { DiffViewer } from "../../components/assistant-ui/diff-viewer";
import { cn } from "../../lib/utils";
import { useI18n } from "../i18n";
import {
  gitCommit,
  gitDiff,
  gitDiscard,
  gitFileAt,
  gitLog,
  gitShow,
  gitStage,
  gitStatus as fetchGitStatus,
  gitUnstage,
  type GitCommit,
  type GitFile,
  type GitStatus,
} from "./api";
import { toneClass, toneFor } from "./gitDecorations";

const POLL_MS = 5_000;

/** Owns the status; shared with FilesPanel for tree decorations. */
export function useGitStatus(cwd: string) {
  const [status, setStatus] = useState<GitStatus | null>(null);
  // Replace state only when the payload actually changed — the 5s poll must
  // not cause render churn (dala's statusKey trick).
  const keyRef = useRef("");

  const refresh = useCallback(async () => {
    const next = await fetchGitStatus(cwd);
    if (!next) return;
    const key = JSON.stringify(next);
    if (key === keyRef.current) return;
    keyRef.current = key;
    setStatus(next);
  }, [cwd]);

  useEffect(() => {
    keyRef.current = "";
    setStatus(null);
    refresh();

    const timer = setInterval(() => {
      if (document.visibilityState === "visible") refresh();
    }, POLL_MS);

    return () => clearInterval(timer);
  }, [refresh]);

  return { status, refresh };
}

type DiffTarget =
  | { kind: "file"; file: GitFile; staged: boolean }
  | { kind: "commit"; commit: GitCommit };

export function GitPanel({
  cwd,
  status,
  refresh,
}: {
  cwd: string;
  status: GitStatus | null;
  refresh: () => Promise<void>;
}) {
  const { t } = useI18n();
  const [tab, setTab] = useState<"changes" | "history">("changes");
  const [message, setMessage] = useState("");
  const [amend, setAmend] = useState(false);
  // One busy key ("stage:path", "commit") disables only the button in flight.
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [commits, setCommits] = useState<GitCommit[] | null>(null);
  const [diffTarget, setDiffTarget] = useState<DiffTarget | null>(null);

  const staged = useMemo(() => (status?.files ?? []).filter((f) => f.staged), [status]);
  const unstaged = useMemo(() => (status?.files ?? []).filter((f) => f.unstaged), [status]);

  useEffect(() => {
    if (tab !== "history" || commits !== null) return;
    gitLog(cwd).then((result) => setCommits(result?.commits ?? []));
  }, [tab, commits, cwd]);

  // Status changes (our own mutations or external edits) invalidate history.
  useEffect(() => setCommits(null), [status]);

  const run = async (key: string, op: () => Promise<string | null>) => {
    setBusy(key);
    setError(null);
    const failure = await op();
    if (failure) setError(failure);
    await refresh();
    setBusy(null);
  };

  const eachFile = (files: GitFile[], op: (file: string) => Promise<string | null>) =>
    async () => {
      for (const f of files) {
        const failure = await op(f.path);
        if (failure) return failure;
      }
      return null;
    };

  if (!status || !status.repo) {
    return (
      <div className="flex min-h-0 flex-1 flex-col">
        <PanelHeader branch={null} onRefresh={refresh} />
        <p className="px-3 py-2 text-xs text-muted-foreground">
          {status ? t("ws.notARepo") : "…"}
        </p>
      </div>
    );
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <PanelHeader branch={status.branch} onRefresh={refresh} />

      <Tabs
        value={tab}
        onValueChange={(v: string) => setTab(v as "changes" | "history")}
        className="shrink-0 px-2 pb-1"
      >
        <TabsList className="h-8">
          <TabsTrigger value="changes" className="text-xs">
            {`${t("ws.changes")}${status.files.length ? ` · ${status.files.length}` : ""}`}
          </TabsTrigger>
          <TabsTrigger value="history" className="text-xs">
            {t("ws.history")}
          </TabsTrigger>
        </TabsList>
      </Tabs>

      {error && (
        <p className="mx-2 mb-1 rounded-md bg-destructive/10 px-2 py-1 text-xs break-all text-destructive">
          {error}
        </p>
      )}

      {tab === "changes" ? (
        <>
          <ScrollArea className="min-h-0 flex-1">
            {status.files.length === 0 && (
              <p className="px-3 py-2 text-xs text-muted-foreground">{t("ws.clean")}</p>
            )}

            {staged.length > 0 && (
              <FileGroup
                label={t("ws.staged")}
                action={{
                  label: t("ws.unstageAll"),
                  onClick: () => run("unstage-all", eachFile(staged, (f) => gitUnstage(cwd, f))),
                }}
              >
                {staged.map((file) => (
                  <FileRow
                    key={`s:${file.path}`}
                    file={file}
                    busy={busy}
                    onOpen={() => setDiffTarget({ kind: "file", file, staged: true })}
                    actions={[
                      {
                        key: `unstage:${file.path}`,
                        icon: <Minus className="size-3.5" />,
                        title: t("ws.unstage"),
                        onClick: () =>
                          run(`unstage:${file.path}`, () => gitUnstage(cwd, file.path)),
                      },
                    ]}
                  />
                ))}
              </FileGroup>
            )}

            {unstaged.length > 0 && (
              <FileGroup
                label={t("ws.changes")}
                action={{
                  label: t("ws.stageAll"),
                  onClick: () => run("stage-all", eachFile(unstaged, (f) => gitStage(cwd, f))),
                }}
              >
                {unstaged.map((file) => (
                  <FileRow
                    key={`u:${file.path}`}
                    file={file}
                    busy={busy}
                    onOpen={() => setDiffTarget({ kind: "file", file, staged: false })}
                    actions={[
                      {
                        key: `discard:${file.path}`,
                        icon: <Undo2 className="size-3.5" />,
                        title: t("ws.discard"),
                        onClick: () => {
                          if (!confirm(t("ws.discardConfirm", { file: file.path }))) return;
                          run(`discard:${file.path}`, () => gitDiscard(cwd, file.path));
                        },
                      },
                      {
                        key: `stage:${file.path}`,
                        icon: <Plus className="size-3.5" />,
                        title: t("ws.stage"),
                        onClick: () => run(`stage:${file.path}`, () => gitStage(cwd, file.path)),
                      },
                    ]}
                  />
                ))}
              </FileGroup>
            )}
          </ScrollArea>

          <div className="shrink-0 space-y-1.5 p-2">
            <Textarea
              value={message}
              onChange={(e) => setMessage(e.target.value)}
              placeholder={t("ws.commitPlaceholder")}
              className="max-h-32 min-h-16 text-sm"
            />
            <div className="flex items-center gap-2">
              <label className="flex items-center gap-1.5 text-xs text-muted-foreground select-none">
                <Checkbox checked={amend} onCheckedChange={(v: boolean | "indeterminate") => setAmend(v === true)} />
                {t("ws.amend")}
              </label>
              <div className="flex-1" />
              <Button
                size="sm"
                disabled={busy === "commit" || (!amend && (staged.length === 0 || !message.trim()))}
                onClick={() =>
                  run("commit", async () => {
                    const failure = await gitCommit(cwd, message.trim(), amend);
                    if (!failure) {
                      setMessage("");
                      setAmend(false);
                    }
                    return failure;
                  })
                }
              >
                {t("ws.commit", { count: staged.length })}
              </Button>
            </div>
          </div>
        </>
      ) : (
        <ScrollArea className="min-h-0 flex-1">
          {commits === null && <p className="px-3 py-2 text-xs text-muted-foreground">…</p>}
          {commits?.length === 0 && (
            <p className="px-3 py-2 text-xs text-muted-foreground">{t("ws.clean")}</p>
          )}
          {commits?.map((commit) => (
            <button
              key={commit.hash}
              type="button"
              onClick={() => setDiffTarget({ kind: "commit", commit })}
              className="flex w-full flex-col gap-0.5 px-3 py-1.5 text-left transition-colors hover:bg-accent/60"
            >
              <span className="truncate text-sm">{commit.subject}</span>
              <span className="font-mono text-[10px] text-muted-foreground">
                {commit.hash} · {commit.author} · {commit.date.slice(0, 10)}
              </span>
            </button>
          ))}
        </ScrollArea>
      )}

      {diffTarget && (
        <DiffDialog cwd={cwd} target={diffTarget} onClose={() => setDiffTarget(null)} />
      )}
    </div>
  );
}

function PanelHeader({ branch, onRefresh }: { branch: string | null; onRefresh: () => void }) {
  const { t } = useI18n();

  return (
    <div className="flex h-10 shrink-0 items-center gap-1.5 px-2">
      <span className="px-1 text-xs font-semibold tracking-wide text-muted-foreground uppercase">
        {t("ws.git")}
      </span>
      {branch && (
        <span className="flex min-w-0 items-center gap-1 rounded-md bg-muted/60 px-1.5 py-0.5 font-mono text-[11px] text-muted-foreground">
          <GitBranch className="size-3 shrink-0" />
          <span className="truncate">{branch}</span>
        </span>
      )}
      <div className="flex-1" />
      <Button
        variant="ghost"
        size="icon"
        className="size-7"
        aria-label={t("ws.refresh")}
        title={t("ws.refresh")}
        onClick={onRefresh}
      >
        <RefreshCw className="size-3.5" />
      </Button>
    </div>
  );
}

function FileGroup({
  label,
  action,
  children,
}: {
  label: string;
  action: { label: string; onClick: () => void };
  children: React.ReactNode;
}) {
  return (
    <div className="pb-1">
      <div className="flex items-center px-3 pt-2 pb-0.5">
        <span className="text-[10px] font-semibold tracking-wide text-muted-foreground uppercase">
          {label}
        </span>
        <div className="flex-1" />
        <button
          type="button"
          onClick={action.onClick}
          className="text-[10px] text-muted-foreground underline-offset-2 hover:text-foreground hover:underline"
        >
          {action.label}
        </button>
      </div>
      {children}
    </div>
  );
}

function FileRow({
  file,
  busy,
  onOpen,
  actions,
}: {
  file: GitFile;
  busy: string | null;
  onOpen: () => void;
  actions: { key: string; icon: React.ReactNode; title: string; onClick: () => void }[];
}) {
  const { label: badge, tone } = toneFor(file.status);

  return (
    <div className="group flex items-center gap-1.5 py-0.5 pr-1.5 pl-3 transition-colors hover:bg-accent/60">
      <span className={cn("w-3 shrink-0 text-center font-mono text-[10px]", toneClass(tone))}>
        {badge}
      </span>
      <button
        type="button"
        onClick={onOpen}
        title={file.path}
        className="min-w-0 flex-1 truncate text-left text-sm"
      >
        {file.path}
      </button>
      <span className="hidden shrink-0 items-center gap-0.5 group-hover:flex">
        {actions.map((action) => (
          <Button
            key={action.key}
            variant="ghost"
            size="icon"
            className="size-6"
            title={action.title}
            aria-label={action.title}
            disabled={busy === action.key}
            onClick={action.onClick}
          >
            {action.icon}
          </Button>
        ))}
      </span>
    </div>
  );
}

// ── Diff dialog ─────────────────────────────────────────────────────────

type DiffState =
  | { state: "loading" }
  | { state: "sides"; oldContent: string; newContent: string }
  | { state: "patch"; text: string; truncated: boolean; binary: boolean };

function DiffDialog({
  cwd,
  target,
  onClose,
}: {
  cwd: string;
  target: DiffTarget;
  onClose: () => void;
}) {
  const { t } = useI18n();
  const [diff, setDiff] = useState<DiffState>({ state: "loading" });

  useEffect(() => {
    let cancelled = false;

    (async () => {
      if (target.kind === "commit") {
        const shown = await gitShow(cwd, target.commit.hash);
        if (cancelled) return;
        setDiff({
          state: "patch",
          text: shown?.text ?? "",
          truncated: shown?.truncated ?? false,
          binary: false,
        });
        return;
      }

      // dala's upgrade path: fetch both full sides and let the diff viewer
      // do the alignment; binary/truncated falls back to the unified patch.
      const { file, staged } = target;
      const [oldRev, newRev] = staged ? ["HEAD", ":0"] : [":0", "WORKTREE"];
      const [oldSide, newSide] = await Promise.all([
        gitFileAt(cwd, oldRev, file.path),
        gitFileAt(cwd, newRev, file.path),
      ]);
      if (cancelled) return;

      if (oldSide && newSide && !oldSide.binary && !newSide.binary && !oldSide.truncated && !newSide.truncated) {
        setDiff({ state: "sides", oldContent: oldSide.content, newContent: newSide.content });
      } else {
        const patch = await gitDiff(cwd, file.path, staged);
        if (cancelled) return;
        setDiff({
          state: "patch",
          text: patch?.diff ?? "",
          truncated: patch?.truncated ?? false,
          binary: patch?.binary ?? false,
        });
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [cwd, target]);

  const title =
    target.kind === "commit"
      ? `${target.commit.hash} · ${target.commit.subject}`
      : target.file.path;

  return (
    <Dialog open onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="flex max-h-[85vh] flex-col sm:max-w-4xl">
        <DialogHeader>
          <DialogTitle className="truncate font-mono text-sm">{title}</DialogTitle>
        </DialogHeader>
        <div className="min-h-0 flex-1 overflow-auto">
          {diff.state === "loading" && (
            <p className="py-4 text-center text-xs text-muted-foreground">…</p>
          )}
          {diff.state === "sides" && (
            <DiffViewer
              oldFile={{
                content: diff.oldContent,
                name: target.kind === "file" ? target.file.path : undefined,
              }}
              newFile={{
                content: diff.newContent,
                name: target.kind === "file" ? target.file.path : undefined,
              }}
              variant="muted"
              size="sm"
            />
          )}
          {diff.state === "patch" && (
            <div>
              {diff.binary ? (
                <p className="py-1 text-xs text-muted-foreground">{t("ws.binaryDiff")}</p>
              ) : (
                <DiffViewer patch={diff.text} viewMode="unified" variant="muted" size="sm" />
              )}
              {diff.truncated && (
                <p className="py-1 text-xs text-muted-foreground">{t("ws.diffTruncated")}</p>
              )}
            </div>
          )}
        </div>
      </DialogContent>
    </Dialog>
  );
}
