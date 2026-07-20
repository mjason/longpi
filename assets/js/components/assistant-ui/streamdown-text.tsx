import { StreamdownTextPrimitive } from "@assistant-ui/react-streamdown";
import { code } from "@streamdown/code";
import { math } from "@streamdown/math";
import { mermaid } from "@streamdown/mermaid";
import "katex/dist/katex.min.css";
import "streamdown/styles.css";

/**
 * Streaming-aware markdown for assistant message text, built on assistant-ui's
 * Streamdown. Unlike the plain react-markdown renderer it ships Shiki syntax
 * highlighting, KaTeX math, and Mermaid diagrams, and it renders cleanly while
 * tokens are still streaming (unclosed code fences, half-written tables, etc.).
 */
export const StreamdownText = () => (
  <StreamdownTextPrimitive
    plugins={{ code, math, mermaid }}
    shikiTheme={["github-light", "github-dark"]}
  />
);
