import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { installCsrfRetry } from "./rpc-csrf";

describe("installCsrfRetry", () => {
  const realFetch = window.fetch;

  beforeEach(() => {
    document.head.innerHTML = `<meta name="csrf-token" content="stale-token" />`;
  });

  afterEach(() => {
    window.fetch = realFetch;
    vi.restoreAllMocks();
  });

  function metaToken() {
    return document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
  }

  it("refreshes the token and retries once on a 403 from /rpc/*", async () => {
    const calls: Array<{ url: string; token?: string }> = [];

    window.fetch = vi.fn(async (input: any, init?: any) => {
      const url = String(input);
      const token = new Headers(init?.headers).get("X-CSRF-Token") ?? undefined;
      calls.push({ url, token });

      if (url === "/rpc/csrf") {
        return new Response(JSON.stringify({ token: "fresh-token" }), { status: 200 });
      }
      // First /rpc/run (stale token) fails; the retry (fresh token) succeeds.
      if (token === "fresh-token") return new Response("{}", { status: 200 });
      return new Response("forbidden", { status: 403 });
    }) as any;

    installCsrfRetry();

    const res = await window.fetch("/rpc/run", {
      method: "POST",
      headers: { "X-CSRF-Token": "stale-token" },
    });

    expect(res.status).toBe(200);
    expect(calls.map((c) => c.url)).toEqual(["/rpc/run", "/rpc/csrf", "/rpc/run"]);
    expect(metaToken()).toBe("fresh-token"); // meta updated for later calls
  });

  it("does not retry non-/rpc 403s or loop", async () => {
    let hits = 0;
    window.fetch = vi.fn(async () => {
      hits += 1;
      return new Response("no", { status: 403 });
    }) as any;

    installCsrfRetry();

    const res = await window.fetch("/some/other/path", { method: "POST" });
    expect(res.status).toBe(403);
    expect(hits).toBe(1); // no refresh, no retry
  });
});
