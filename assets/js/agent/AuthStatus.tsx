import { LogOut } from "lucide-react";

/**
 * Signed-in identity + sign-out link in the sidebar footer. Renders nothing
 * while auth is disabled (the default), so the zero-config install is
 * unchanged. Values come from the meta tags the server layout embeds.
 */
export function AuthStatus() {
  const enabled =
    document.querySelector('meta[name="auth-enabled"]')?.getAttribute("content") === "true";
  const email = document.querySelector('meta[name="user-email"]')?.getAttribute("content");
  if (!enabled || !email) return null;

  return (
    <div className="flex shrink-0 items-center justify-between gap-2 border-t border-border px-3 py-2">
      <span className="truncate text-xs text-muted-foreground" title={email}>
        {email}
      </span>
      <a
        href="/sign-out"
        className="inline-flex shrink-0 items-center gap-1 text-xs text-muted-foreground transition-colors hover:text-foreground"
      >
        <LogOut className="size-3" />
        Sign out
      </a>
    </div>
  );
}
