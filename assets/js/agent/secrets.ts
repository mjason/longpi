// Out-of-band secret markers: `@@NAME=value@@` in a message is stored
// server-side and replaced with a placeholder before anything (history, DB,
// model) sees it. The frontend mirrors that replacement for optimistic
// display, and highlights the marker while typing.

/** Matches a whole marker; group 1 = the env-style name. */
export const SECRET_MARKER_RE = /@@([A-Z][A-Z0-9_]*)?=.+?@@/gs;

/** The same replacement the server makes, for optimistic local display. */
export function maskSecrets(text: string): string {
  return text.replace(SECRET_MARKER_RE, (_m, name?: string) =>
    name ? `[secret ${name} saved]` : "[secret received]",
  );
}
