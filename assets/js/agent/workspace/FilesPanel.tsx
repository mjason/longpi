// The workspace file tree (dala's FileDrawer, rebuilt on shadcn primitives):
// lazy per-directory loading, expand/collapse, hidden-file toggle, git
// letter badges with ancestor tones, and click-to-preview via the existing
// LinkModal. Rooted at the conversation's cwd.

import { useCallback, useEffect, useMemo, useState } from "react";
import { ChevronRight, Eye, EyeOff, File as FileIcon, Folder, FolderOpen, RefreshCw } from "lucide-react";

import { Button } from "../../components/ui/button";
import { ScrollArea } from "../../components/ui/scroll-area";
import { LinkModal } from "../../components/assistant-ui/file-link-modal";
import { cn } from "../../lib/utils";
import { useI18n } from "../i18n";
import { listDir, type GitStatus } from "./api";
import { buildTreeRows, joinPath, type DirListing, type TreeRow } from "./tree";
import { buildGitDecorations, toneClass } from "./gitDecorations";

function humanBytes(size: number): string {
  if (size < 1024) return `${size}`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(0)}K`;
  return `${(size / 1024 / 1024).toFixed(1)}M`;
}

export function FilesPanel({ cwd, gitStatus }: { cwd: string; gitStatus: GitStatus | null }) {
  const { t } = useI18n();
  const [listings, setListings] = useState<Map<string, DirListing>>(new Map());
  const [expanded, setExpanded] = useState<Set<string>>(new Set());
  const [showHidden, setShowHidden] = useState(false);
  const [previewPath, setPreviewPath] = useState<string | null>(null);
  const [loading, setLoading] = useState<Set<string>>(new Set());

  const fetchDir = useCallback(async (path: string) => {
    setLoading((prev) => new Set(prev).add(path));
    const listing = await listDir(path);
    setLoading((prev) => {
      const next = new Set(prev);
      next.delete(path);
      return next;
    });
    if (!listing) return;
    setListings((prev) => new Map(prev).set(listing.path, listing));
  }, []);

  // Root follows the conversation's cwd; switching conversations resets the
  // tree (per-root snapshots are a later nicety).
  useEffect(() => {
    setListings(new Map());
    setExpanded(new Set());
    fetchDir(cwd);
  }, [cwd, fetchDir]);

  const refreshAll = useCallback(() => {
    fetchDir(cwd);
    for (const dir of expanded) fetchDir(dir);
  }, [cwd, expanded, fetchDir]);

  const toggleDir = (path: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(path)) {
        next.delete(path);
      } else {
        next.add(path);
        if (!listings.has(path)) fetchDir(path);
      }
      return next;
    });
  };

  const rows = useMemo(
    () => buildTreeRows(cwd, listings, expanded, showHidden),
    [cwd, listings, expanded, showHidden],
  );

  const decorations = useMemo(
    () => (gitStatus ? buildGitDecorations(gitStatus) : new Map()),
    [gitStatus],
  );

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex h-10 shrink-0 items-center gap-1 px-2">
        <span className="px-1 text-xs font-semibold tracking-wide text-muted-foreground uppercase">
          {t("ws.files")}
        </span>
        <div className="flex-1" />
        <Button
          variant="ghost"
          size="icon"
          className="size-7"
          aria-label={t("ws.showHidden")}
          title={t("ws.showHidden")}
          onClick={() => setShowHidden((v) => !v)}
        >
          {showHidden ? <Eye className="size-3.5" /> : <EyeOff className="size-3.5" />}
        </Button>
        <Button
          variant="ghost"
          size="icon"
          className="size-7"
          aria-label={t("ws.refresh")}
          title={t("ws.refresh")}
          onClick={refreshAll}
        >
          <RefreshCw className="size-3.5" />
        </Button>
      </div>

      <ScrollArea className="min-h-0 flex-1">
        <div className="pb-2" role="tree">
          {rows.map((row) => (
            <TreeRowView
              key={row.kind === "note" ? row.id : row.path}
              row={row}
              loading={row.kind === "dir" && loading.has(row.path)}
              expanded={row.kind === "dir" && expanded.has(row.path)}
              decoration={row.kind === "note" ? undefined : decorations.get(row.path)}
              onActivate={() =>
                row.kind === "dir"
                  ? toggleDir(row.path)
                  : row.kind === "file" && setPreviewPath(row.path)
              }
            />
          ))}
          {rows.length === 0 && (
            <p className="px-3 py-2 text-xs text-muted-foreground">{t("ws.empty")}</p>
          )}
        </div>
      </ScrollArea>

      {previewPath && (
        <LinkModal
          url={previewPath}
          isOpen
          onClose={() => setPreviewPath(null)}
          onConfirm={() => setPreviewPath(null)}
        />
      )}
    </div>
  );
}

function TreeRowView({
  row,
  expanded,
  loading,
  decoration,
  onActivate,
}: {
  row: TreeRow;
  expanded: boolean;
  loading: boolean;
  decoration?: { label: string; tone: Parameters<typeof toneClass>[0] };
  onActivate: () => void;
}) {
  const { t } = useI18n();

  if (row.kind === "note") {
    return (
      <div
        className="py-0.5 text-xs text-muted-foreground/70 italic"
        style={{ paddingLeft: 12 + row.depth * 14 + 18 }}
      >
        {row.note === "hidden" ? t("ws.hidden", { count: row.count }) : t("ws.emptyDir")}
      </div>
    );
  }

  const isDir = row.kind === "dir";

  return (
    <button
      type="button"
      data-path={row.path}
      onClick={onActivate}
      title={row.path}
      className="group flex w-full items-center gap-1.5 py-1 pr-2 text-left text-sm transition-colors hover:bg-accent/60"
      style={{ paddingLeft: 12 + row.depth * 14 }}
    >
      <span className="flex size-4 shrink-0 items-center justify-center text-muted-foreground">
        {isDir &&
          (loading ? (
            <RefreshCw className="size-3 animate-spin" />
          ) : (
            <ChevronRight className={cn("size-3.5 transition-transform", expanded && "rotate-90")} />
          ))}
      </span>
      {isDir ? (
        expanded ? (
          <FolderOpen className="size-4 shrink-0 text-muted-foreground" />
        ) : (
          <Folder className="size-4 shrink-0 text-muted-foreground" />
        )
      ) : (
        <FileIcon className="size-4 shrink-0 text-muted-foreground/70" />
      )}
      <span
        className={cn(
          "min-w-0 flex-1 truncate",
          decoration && toneClass(decoration.tone),
        )}
      >
        {row.entry.name}
        {row.entry.symlink && <span className="ml-1 text-muted-foreground">⇢</span>}
      </span>
      {decoration?.label && (
        <span className={cn("shrink-0 font-mono text-[10px]", toneClass(decoration.tone))}>
          {decoration.label}
        </span>
      )}
      {!isDir && (
        <span className="shrink-0 font-mono text-[10px] text-muted-foreground/60 group-hover:text-muted-foreground">
          {humanBytes(row.entry.size)}
        </span>
      )}
    </button>
  );
}
