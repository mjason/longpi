import { Check, Copy, Loader2, ShieldCheck, ShieldOff } from "lucide-react";
import { useEffect, useState } from "react";
import { Button } from "../../components/ui/button";
import { useI18n } from "../i18n";
import { type EmbedInfo, loadEmbedInfo } from "../settings";

/**
 * Management → Embed: everything a host app (e.g. dala) needs to iframe the
 * agent — the embed token, a ready-to-paste iframe snippet, and the parameter
 * reference.
 */
export function EmbedSection() {
  const { t } = useI18n();
  const [info, setInfo] = useState<EmbedInfo | null>(null);

  useEffect(() => {
    loadEmbedInfo().then((i) => i && setInfo(i));
  }, []);

  if (!info) return <Loader2 className="my-10 size-5 animate-spin text-muted-foreground" />;

  const tokenPart = info.authEnabled && info.embedToken ? `&token=${info.embedToken}` : "";
  const snippet = `<iframe\n  src="${info.baseUrl}/embed?cwd=/path/to/workspace&theme=dark${tokenPart}"\n  style="width:100%;height:100%;border:0"\n></iframe>`;

  return (
    <div className="space-y-8 py-4">
      <section className="space-y-2">
        <h2 className="text-sm font-semibold">{t("embedPage.status")}</h2>
        <p className="flex items-center gap-2 text-sm text-muted-foreground">
          {info.authEnabled ? (
            <ShieldCheck className="size-4 text-tool" />
          ) : (
            <ShieldOff className="size-4" />
          )}
          {info.authEnabled ? t("embedPage.authOn") : t("embedPage.authOff")}
        </p>
      </section>

      {info.embedToken && (
        <section className="space-y-2">
          <h2 className="text-sm font-semibold">{t("embedPage.token")}</h2>
          <CopyBlock text={info.embedToken} mono />
          <p className="text-xs text-muted-foreground">{t("embedPage.tokenHint")}</p>
        </section>
      )}

      <section className="space-y-2">
        <h2 className="text-sm font-semibold">{t("embedPage.snippet")}</h2>
        <CopyBlock text={snippet} mono pre />
        <p className="text-xs text-muted-foreground">{t("embedPage.snippetHint")}</p>
      </section>

      <section className="space-y-2">
        <h2 className="text-sm font-semibold">{t("embedPage.params")}</h2>
        <div className="divide-y divide-border rounded-lg text-sm ring-1 ring-black/[0.06] dark:ring-white/[0.08]">
          {(
            [
              ["cwd", t("embedPage.param.cwd")],
              ["theme", t("embedPage.param.theme")],
              ["model", t("embedPage.param.model")],
              ["token", t("embedPage.param.token")],
            ] as const
          ).map(([name, desc]) => (
            <div key={name} className="flex items-baseline gap-3 px-3 py-2">
              <code className="w-16 shrink-0 rounded bg-muted px-1.5 py-0.5 font-mono text-xs">
                {name}
              </code>
              <span className="text-muted-foreground">{desc}</span>
            </div>
          ))}
        </div>
      </section>
    </div>
  );
}

function CopyBlock({ text, mono, pre }: { text: string; mono?: boolean; pre?: boolean }) {
  const { t } = useI18n();
  const [copied, setCopied] = useState(false);

  async function copy() {
    try {
      await navigator.clipboard.writeText(text);
    } catch {
      // clipboard may be unavailable over plain HTTP; the fallback helper in
      // lib/clipboard covers the composer, but here we just no-op.
    }
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }

  return (
    <div className="relative rounded-lg bg-muted/50 ring-1 ring-black/[0.06] dark:ring-white/[0.08]">
      <div className={`overflow-x-auto p-3 pr-12 text-xs ${mono ? "font-mono" : ""}`}>
        {pre ? <pre className="whitespace-pre">{text}</pre> : <span className="break-all">{text}</span>}
      </div>
      <Button
        variant="ghost"
        size="icon"
        onClick={() => void copy()}
        aria-label={t("embedPage.copy")}
        className="absolute top-1.5 right-1.5 size-7 text-muted-foreground hover:text-foreground"
      >
        {copied ? <Check className="size-4 text-tool" /> : <Copy className="size-4" />}
      </Button>
    </div>
  );
}
