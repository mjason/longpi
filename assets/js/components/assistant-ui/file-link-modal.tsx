"use client";

import {
  createContext,
  useContext,
  useEffect,
  useState,
  type FC,
} from "react";
import type { LinkSafetyModalProps } from "@assistant-ui/react-streamdown";
import {
  CheckIcon,
  CopyIcon,
  DownloadIcon,
  ExternalLinkIcon,
  FileIcon,
} from "lucide-react";

import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { useI18n } from "@/agent/i18n";
import { cn } from "@/lib/utils";

/**
 * Local-file links in chat messages open an in-app preview instead of the
 * browser treating `/home/...` as a site URL. Provided by ConversationPane so
 * relative paths resolve against the conversation's workspace.
 */
export const WorkspaceCwdContext = createContext<string | null>(null);

/**
 * A markdown href with no URL scheme (and not an anchor) is a file path.
 * Same-origin URLs count too: the markdown sanitizer resolves path hrefs
 * against the page origin, so `[x](/abs/file)` and `[x](rel/file)` both reach
 * us as `http://<origin>/...` — and this app serves no such content routes.
 */
export function isLocalFileHref(href: string): boolean {
  if (/^file:\/\//i.test(href)) return true;
  if (href.startsWith("#")) return false;
  if (!/^[a-z][a-z0-9+.-]*:/i.test(href)) return true;
  return (
    typeof window !== "undefined" && href.startsWith(`${window.location.origin}/`)
  );
}

/** Decode a markdown href back into a filesystem path. */
export function hrefToPath(href: string): string {
  let bare = href.replace(/^file:\/\//i, "");
  if (typeof window !== "undefined" && bare.startsWith(`${window.location.origin}/`)) {
    bare = bare.slice(window.location.origin.length);
  }
  try {
    return decodeURIComponent(bare);
  } catch {
    return bare;
  }
}

type Preview =
  | { state: "loading" }
  | { state: "notFound" }
  | {
      state: "loaded";
      kind: "text" | "image" | "binary";
      name: string;
      path: string;
      size: number;
      content?: string;
      truncated?: boolean;
    };

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function fileQuery(path: string, cwd: string | null): string {
  const params = new URLSearchParams({ path });
  if (cwd) params.set("cwd", cwd);
  return params.toString();
}

const CopyButton: FC<{ text: string; label: string }> = ({ text, label }) => {
  const [copied, setCopied] = useState(false);
  return (
    <Button
      variant="outline"
      size="sm"
      onClick={() => {
        navigator.clipboard?.writeText(text).then(() => {
          setCopied(true);
          setTimeout(() => setCopied(false), 2000);
        });
      }}
    >
      {copied ? <CheckIcon className="size-3.5" /> : <CopyIcon className="size-3.5" />}
      {label}
    </Button>
  );
};

/** In-app viewer for a local file path: text inline, images inline, else download. */
const FilePreviewDialog: FC<LinkSafetyModalProps> = ({ url, isOpen, onClose }) => {
  const { t } = useI18n();
  const cwd = useContext(WorkspaceCwdContext);
  const path = hrefToPath(url);
  const [preview, setPreview] = useState<Preview>({ state: "loading" });

  useEffect(() => {
    if (!isOpen) return;
    let cancelled = false;
    setPreview({ state: "loading" });
    fetch(`/rpc/file?${fileQuery(path, cwd)}`)
      .then(async (res) => {
        if (cancelled) return;
        if (!res.ok) return setPreview({ state: "notFound" });
        const body = await res.json();
        if (!cancelled) setPreview({ state: "loaded", ...body });
      })
      .catch(() => !cancelled && setPreview({ state: "notFound" }));
    return () => {
      cancelled = true;
    };
  }, [isOpen, path, cwd]);

  const rawUrl = `/rpc/file/raw?${fileQuery(path, cwd)}`;
  const loaded = preview.state === "loaded" ? preview : null;

  return (
    <Dialog open={isOpen} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="flex max-h-[85vh] flex-col sm:max-w-2xl">
        <DialogHeader className="min-w-0">
          <DialogTitle className="flex items-center gap-2 truncate">
            <FileIcon className="size-4 shrink-0 text-muted-foreground" />
            <span className="truncate">{loaded?.name ?? path.split("/").pop()}</span>
            {loaded && (
              <span className="shrink-0 text-xs font-normal text-muted-foreground">
                {formatSize(loaded.size)}
              </span>
            )}
          </DialogTitle>
          <DialogDescription className="break-all font-mono text-xs">
            {loaded?.path ?? path}
          </DialogDescription>
        </DialogHeader>

        <div className="min-h-0 flex-1 overflow-y-auto">
          {preview.state === "loading" && (
            <div className="space-y-2 py-1">
              <Skeleton className="h-4 w-full" />
              <Skeleton className="h-4 w-5/6" />
              <Skeleton className="h-4 w-2/3" />
            </div>
          )}
          {preview.state === "notFound" && (
            <p className="py-4 text-sm text-muted-foreground">{t("file.notFound")}</p>
          )}
          {loaded?.kind === "text" && (
            <>
              <pre className="whitespace-pre-wrap break-all rounded-lg bg-muted/50 p-3 font-mono text-xs leading-relaxed">
                {loaded.content}
              </pre>
              {loaded.truncated && (
                <p className="pt-2 text-xs text-muted-foreground">{t("file.truncated")}</p>
              )}
            </>
          )}
          {loaded?.kind === "image" && (
            <img
              src={rawUrl}
              alt={loaded.name}
              className="mx-auto max-h-[60vh] max-w-full rounded-lg"
            />
          )}
          {loaded?.kind === "binary" && (
            <p className="py-4 text-sm text-muted-foreground">{t("file.binary")}</p>
          )}
        </div>

        <DialogFooter className="gap-2 sm:justify-between">
          <CopyButton text={loaded?.path ?? path} label={t("file.copyPath")} />
          <Button variant="default" size="sm" asChild>
            <a href={`${rawUrl}&download=1`} download>
              <DownloadIcon className="size-3.5" />
              {t("file.download")}
            </a>
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

/** shadcn-styled (and i18n'd) replacement for Streamdown's external-link confirm. */
const ExternalLinkDialog: FC<LinkSafetyModalProps> = ({
  url,
  isOpen,
  onClose,
  onConfirm,
}) => {
  const { t } = useI18n();
  return (
    <Dialog open={isOpen} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2">
            <ExternalLinkIcon className="size-4" />
            {t("link.openExternal")}
          </DialogTitle>
          <DialogDescription>{t("link.externalWarning")}</DialogDescription>
        </DialogHeader>
        <div
          className={cn(
            "break-all rounded-lg bg-muted/50 p-3 font-mono text-xs",
            url.length > 200 && "max-h-32 overflow-y-auto",
          )}
        >
          {url}
        </div>
        <DialogFooter className="gap-2 sm:justify-between">
          <CopyButton text={url} label={t("link.copy")} />
          <Button
            size="sm"
            onClick={() => {
              onConfirm();
              onClose();
            }}
          >
            <ExternalLinkIcon className="size-3.5" />
            {t("link.open")}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
};

/**
 * Router for Streamdown's linkSafety.renderModal: local paths get the file
 * preview, real URLs get the external-link confirm.
 */
export const LinkModal: FC<LinkSafetyModalProps> = (props) =>
  isLocalFileHref(props.url) ? (
    <FilePreviewDialog {...props} />
  ) : (
    <ExternalLinkDialog {...props} />
  );
