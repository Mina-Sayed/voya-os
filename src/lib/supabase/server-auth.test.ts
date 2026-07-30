import { afterEach, describe, expect, it, vi } from "vitest";

const runtime = vi.hoisted(() => ({
  createServerClient: vi.fn(),
  cookies: vi.fn(),
  readSupabasePublicConfig: vi.fn(),
}));

vi.mock("@supabase/ssr", () => ({
  createServerClient: runtime.createServerClient,
}));

vi.mock("next/headers", () => ({
  cookies: runtime.cookies,
}));

vi.mock("./public-config", () => ({
  readSupabasePublicConfig: runtime.readSupabasePublicConfig,
}));

import { createServerMagicLinkGateway, createServerSupabaseClient } from "./server-auth";

afterEach(() => {
  vi.clearAllMocks();
});

describe("createServerSupabaseClient", () => {
  it("keeps rendering when the response cookie store rejects session writes", async () => {
    const cookieStore = {
      getAll: vi.fn().mockReturnValue([{ name: "existing", value: "value" }]),
      set: vi.fn(() => { throw new Error("Server Component cannot set cookies"); }),
    };
    let adapter: { cookies: { getAll(): unknown; setAll(items: Array<{ name: string; value: string; options?: Record<string, unknown> }>): void } } | undefined;
    runtime.cookies.mockResolvedValue(cookieStore);
    runtime.readSupabasePublicConfig.mockReturnValue({
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });
    runtime.createServerClient.mockImplementation((_url, _key, options) => {
      adapter = options;
      return { auth: {} };
    });

    await createServerSupabaseClient();

    expect(adapter?.cookies.getAll()).toEqual([{ name: "existing", value: "value" }]);
    expect(() => adapter?.cookies.setAll([{ name: "sb-session", value: "new-value", options: { httpOnly: true } }]))
      .not.toThrow();
  });
});

describe("createServerMagicLinkGateway", () => {
  it("sends a magic-link request through the server-side client", async () => {
    const signInWithOtp = vi.fn().mockResolvedValue({ error: null });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({ auth: { signInWithOtp } });

    const gateway = await createServerMagicLinkGateway();
    await expect(gateway.requestMagicLink({ email: "operator@voya.example", redirectTo: "https://app.voya.example/auth/callback" }))
      .resolves.toBeUndefined();

    expect(signInWithOtp).toHaveBeenCalledWith({
      email: "operator@voya.example",
      options: { emailRedirectTo: "https://app.voya.example/auth/callback" },
    });
  });

  it("surfaces a returned magic-link provider failure to the server action", async () => {
    const providerError = new Error("provider unavailable");
    const signInWithOtp = vi.fn().mockResolvedValue({ error: providerError });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({ auth: { signInWithOtp } });

    const gateway = await createServerMagicLinkGateway();

    await expect(gateway.requestMagicLink({ email: "operator@voya.example", redirectTo: "https://app.voya.example/auth/callback" }))
      .rejects.toBe(providerError);
  });
});
