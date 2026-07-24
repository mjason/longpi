import { describe, expect, it } from "vitest";

import { maskSecrets } from "./secrets";

describe("maskSecrets (optimistic display mirror of the server capture)", () => {
  it("masks a marker, keeping only the name", () => {
    expect(maskSecrets("token: @@HA_TOKEN=eyJabc123@@ done")).toBe(
      "token: [secret HA_TOKEN saved] done",
    );
  });

  it("masks multiple markers and multiline values", () => {
    expect(maskSecrets("@@A=1@@ @@B=x\ny=z@@")).toBe("[secret A saved] [secret B saved]");
  });

  it("masks an anonymous marker as received", () => {
    expect(maskSecrets("token: @@=eyJabc@@")).toBe("token: [secret received]");
  });

  it("leaves plain text and lowercase names alone", () => {
    expect(maskSecrets("email me @@ home")).toBe("email me @@ home");
    expect(maskSecrets("@@lower=v@@")).toBe("@@lower=v@@");
  });
});
