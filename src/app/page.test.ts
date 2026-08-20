import { afterEach, describe, expect, it, vi } from "vitest";

const navigation = vi.hoisted(() => ({ redirect: vi.fn() }));

vi.mock("next/navigation", () => ({ redirect: navigation.redirect }));

import Home from "./page";

afterEach(() => vi.clearAllMocks());

describe("root route", () => {
  it("preserves a Supabase callback code instead of dropping it during routing", async () => {
    await Home({ searchParams: Promise.resolve({ code: "code/with spaces" }) });

    expect(navigation.redirect).toHaveBeenCalledWith("/auth/callback?code=code%2Fwith%20spaces");
  });

  it("routes ordinary visits through the protected workspace boundary", async () => {
    await Home({ searchParams: Promise.resolve({}) });

    expect(navigation.redirect).toHaveBeenCalledWith("/workspace");
  });
});
