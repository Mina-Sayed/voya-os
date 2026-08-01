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

import { createServerMagicLinkGateway, createServerPasswordGateway, createServerSupabaseClient } from "./server-auth";

afterEach(() => {
  vi.clearAllMocks();
});

describe("createServerSupabaseClient", () => {
  it("forwards refreshed session cookies to a writable response store", async () => {
    const cookieStore = {
      getAll: vi.fn().mockReturnValue([{ name: "existing", value: "value" }]),
      set: vi.fn(),
    };
    let adapter: { cookies: { getAll(): unknown; setAll(items: Array<{ name: string; value: string; options?: Record<string, unknown> }>): void } } | undefined;
    let authOptions: unknown;
    runtime.cookies.mockResolvedValue(cookieStore);
    runtime.readSupabasePublicConfig.mockReturnValue({
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });
    runtime.createServerClient.mockImplementation((_url, _key, options) => {
      adapter = options;
      authOptions = options.auth;
      return { auth: {} };
    });

    await createServerSupabaseClient();

    adapter?.cookies.setAll([{ name: "sb-session", value: "new-value", options: { httpOnly: true } }]);

    expect(adapter?.cookies.getAll()).toEqual([{ name: "existing", value: "value" }]);
    expect(authOptions).toEqual({ flowType: "pkce" });
    expect(cookieStore.set).toHaveBeenCalledWith("sb-session", "new-value", { httpOnly: true });
  });

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
    expect(cookieStore.set).toHaveBeenCalledWith("sb-session", "new-value", { httpOnly: true });
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

describe("createServerPasswordGateway", () => {
  it("signs in through the server-side client", async () => {
    const signInWithPassword = vi.fn().mockResolvedValue({ error: null });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({ auth: { signInWithPassword } });

    const gateway = await createServerPasswordGateway();
    await expect(gateway.signInWithPassword({ email: "operator@voya.example", password: "safe-password" }))
      .resolves.toBeUndefined();

    expect(signInWithPassword).toHaveBeenCalledWith({ email: "operator@voya.example", password: "safe-password" });
  });

  it("surfaces a returned password provider failure to the pure contract", async () => {
    const providerError = Object.assign(new Error("invalid"), { status: 400 });
    const signInWithPassword = vi.fn().mockResolvedValue({ error: providerError });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({ auth: { signInWithPassword } });

    const gateway = await createServerPasswordGateway();

    await expect(gateway.signInWithPassword({ email: "operator@voya.example", password: "wrong" }))
      .rejects.toBe(providerError);
  });
});
