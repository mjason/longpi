/**
 * Provides `navigator.clipboard.writeText` in non-secure contexts.
 *
 * The Clipboard API is only exposed on HTTPS and localhost. When the app is
 * opened over a plain-HTTP LAN address (http://192.168.x.x) `navigator.clipboard`
 * is undefined, so assistant-ui's copy button silently rejects. This installs a
 * `document.execCommand("copy")` fallback, which still works over plain HTTP.
 */
export function installClipboardFallback() {
  if (typeof navigator === "undefined" || typeof document === "undefined") return;

  // In a secure context (HTTPS / localhost) the native API works - leave it.
  // Over plain-HTTP LAN it is either absent or rejects, so always override with
  // the execCommand fallback, which succeeds inside the button's click gesture.
  if (typeof window !== "undefined" && window.isSecureContext) return;

  const writeText = (text: string): Promise<void> =>
    new Promise((resolve, reject) => {
      const textarea = document.createElement("textarea");
      textarea.value = text;
      textarea.setAttribute("readonly", "");
      textarea.style.position = "fixed";
      textarea.style.top = "0";
      textarea.style.left = "0";
      textarea.style.width = "1px";
      textarea.style.height = "1px";
      textarea.style.opacity = "0";

      // Preserve whatever the user had selected before we hijack the selection.
      const selection = document.getSelection();
      const savedRange = selection && selection.rangeCount > 0 ? selection.getRangeAt(0) : null;

      document.body.appendChild(textarea);
      textarea.focus();
      textarea.select();
      textarea.setSelectionRange(0, text.length);

      try {
        const ok = document.execCommand("copy");
        ok ? resolve() : reject(new Error("Copy command was rejected"));
      } catch (error) {
        reject(error);
      } finally {
        document.body.removeChild(textarea);
        if (savedRange && selection) {
          selection.removeAllRanges();
          selection.addRange(savedRange);
        }
      }
    });

  try {
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { writeText },
    });
  } catch {
    // Some browsers expose a read-only accessor; fall back to a direct assign.
    try {
      (navigator as unknown as { clipboard: { writeText: typeof writeText } }).clipboard = {
        writeText,
      };
    } catch {
      // Nothing more we can do; copy stays unavailable.
    }
  }
}
