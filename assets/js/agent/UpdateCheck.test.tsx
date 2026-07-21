import { afterEach, describe, expect, it, vi } from "vitest";
import { shouldOfferUpdate } from "./UpdateCheck";
import { applyUpgrade, checkVersion, type VersionInfo } from "./settings";

const base: VersionInfo = {
  enabled: true,
  current: "0.1.2",
  latest: "0.1.3",
  tag: "v0.1.3",
  updateAvailable: true,
  notesUrl: null,
};

describe("shouldOfferUpdate", () => {
  it("offers when enabled, an update is available and a version is named", () => {
    expect(shouldOfferUpdate(base)).toBe(true);
  });

  it("stays quiet on a dev/mix run (not enabled)", () => {
    expect(shouldOfferUpdate({ ...base, enabled: false })).toBe(false);
  });

  it("stays quiet when already current", () => {
    expect(shouldOfferUpdate({ ...base, updateAvailable: false })).toBe(false);
  });

  it("stays quiet without a named latest version", () => {
    expect(shouldOfferUpdate({ ...base, latest: null })).toBe(false);
  });

  it("stays quiet with no info yet", () => {
    expect(shouldOfferUpdate(null)).toBe(false);
  });
});

describe("checkVersion", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("returns the parsed version info", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify(base), { status: 200 })),
    );
    expect(await checkVersion()).toEqual(base);
  });

  it("returns null on a non-ok response", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("nope", { status: 500 })));
    expect(await checkVersion()).toBeNull();
  });

  it("returns null when fetch throws", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new Error("offline");
      }),
    );
    expect(await checkVersion()).toBeNull();
  });
});

describe("applyUpgrade", () => {
  afterEach(() => vi.unstubAllGlobals());

  it("reports success on a 200", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("{}", { status: 200 })));
    expect(await applyUpgrade()).toEqual({ ok: true });
  });

  it("surfaces the server error message on failure", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(JSON.stringify({ error: "already up to date" }), { status: 422 })),
    );
    expect(await applyUpgrade()).toEqual({ ok: false, error: "already up to date" });
  });
});
