import { afterEach, describe, expect, it, vi } from "vitest";

const redirect = vi.hoisted(() => vi.fn());

vi.mock("next/navigation", () => ({
  redirect,
}));

import Home from "./page";

afterEach(() => {
  vi.clearAllMocks();
});

describe("home auth callback bridge", () => {
  it("forwards a PKCE code from the root URL to the internal callback", async () => {
    await Home({ searchParams: Promise.resolve({ code: "callback code&secret" }) });

    expect(redirect).toHaveBeenCalledWith("/auth/callback?code=callback+code%26secret");
  });

  it("forwards token-hash links without accepting an arbitrary destination", async () => {
    await Home({
      searchParams: Promise.resolve({
        token_hash: "token-hash",
        type: "magiclink",
        next: "https://evil.example/steal",
      }),
    });

    expect(redirect).toHaveBeenCalledWith("/auth/callback?token_hash=token-hash&type=magiclink");
    expect(redirect.mock.calls.flat().join(" ")).not.toContain("evil.example");
  });

  it("keeps the normal root route on workspace when no auth parameters exist", async () => {
    await Home({ searchParams: Promise.resolve({}) });

    expect(redirect).toHaveBeenCalledWith("/workspace");
  });
});
