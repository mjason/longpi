import { StreamdownTextPrimitive } from "@assistant-ui/react-streamdown";
import { code } from "@streamdown/code";
import { math } from "@streamdown/math";
import { mermaid } from "@streamdown/mermaid";
import "katex/dist/katex.min.css";
import "streamdown/styles.css";

import { LinkModal } from "@/components/assistant-ui/file-link-modal";

/**
 * Streaming-aware markdown for assistant message text, built on assistant-ui's
 * Streamdown. Unlike the plain react-markdown renderer it ships Shiki syntax
 * highlighting, KaTeX math, and Mermaid diagrams, and it renders cleanly while
 * tokens are still streaming (unclosed code fences, half-written tables, etc.).
 *
 * linkSafety.renderModal replaces Streamdown's built-in confirm: local file
 * paths open an in-app preview (download for binaries), external URLs get a
 * shadcn-styled, i18n'd confirm dialog.
 */
export const StreamdownText = () => (
  <StreamdownTextPrimitive
    plugins={{ code, math, mermaid }}
    shikiTheme={["github-light", "github-dark"]}
    // defaultOrigin lets relative hrefs (`[foo](lib/foo.ex)`) through the
    // harden sanitizer instead of rendering "[blocked]".
    security={{ defaultOrigin: window.location.origin }}
    linkSafety={{ enabled: true, renderModal: (props) => <LinkModal {...props} /> }}
  />
);
