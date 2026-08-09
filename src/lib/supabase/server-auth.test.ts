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

import {
  createServerMagicLinkGateway,
  createServerPasswordSignInGateway,
  createServerSupabaseClient,
} from "./server-auth";

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

    adapter?.cookies.setAll([{ name: "sb-session", value: "new-value", options: { httpOnly: true } }]);

    expect(adapter?.cookies.getAll()).toEqual([{ name: "existing", value: "value" }]);
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
    const rpc = vi.fn().mockResolvedValue({ data: true, error: null });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({ auth: { signInWithOtp }, rpc });

    const gateway = await createServerMagicLinkGateway();
    await expect(gateway.requestMagicLink({ email: "operator@voya.example", redirectTo: "https://app.voya.example/auth/callback" }))
      .resolves.toBe("sent");

    expect(signInWithOtp).toHaveBeenCalledWith({
      email: "operator@voya.example",
      options: { emailRedirectTo: "https://app.voya.example/auth/callback" },
    });
    expect(rpc).toHaveBeenCalledWith("consume_auth_rate_limit", {
      p_scope: "magic_link",
      p_key_hash: expect.stringMatching(/^[0-9a-f]{64}$/u),
    });
    expect(rpc.mock.calls[0]?.[1]).not.toHaveProperty("p_limit");
    expect(rpc.mock.calls[0]?.[1]).not.toHaveProperty("p_window_seconds");
  });

  it("surfaces a returned magic-link provider failure to the server action", async () => {
    const providerError = new Error("provider unavailable");
    const signInWithOtp = vi.fn().mockResolvedValue({ error: providerError });
    const rpc = vi.fn().mockResolvedValue({ data: true, error: null });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({ auth: { signInWithOtp }, rpc });

    const gateway = await createServerMagicLinkGateway();

    await expect(gateway.requestMagicLink({ email: "operator@voya.example", redirectTo: "https://app.voya.example/auth/callback" }))
      .rejects.toBe(providerError);
  });

  it("does not ask Supabase Auth for another link when the database bucket denies it", async () => {
    const signInWithOtp = vi.fn();
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({
      auth: { signInWithOtp },
      rpc: vi.fn().mockResolvedValue({ data: false, error: null }),
    });

    const gateway = await createServerMagicLinkGateway();

    await expect(gateway.requestMagicLink({
      email: "operator@voya.example",
      redirectTo: "https://app.voya.example/auth/callback",
    })).resolves.toBe("rate_limited");
    expect(signInWithOtp).not.toHaveBeenCalled();
  });
});

describe("createServerPasswordSignInGateway", () => {
  it("rate-limits with the fixed database policy, signs in, and bootstraps the verified workspace", async () => {
    const signInWithPassword = vi.fn().mockResolvedValue({ data: { user: { id: "user-a" } }, error: null });
    const rpc = vi.fn()
      .mockResolvedValueOnce({ data: true, error: null })
      .mockResolvedValueOnce({ data: [{ organization_id: "organization-a" }], error: null });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    const limit = vi.fn().mockResolvedValue({ data: [], error: null });
    const byStatus = vi.fn().mockReturnValue({ limit });
    const byUser = vi.fn().mockReturnValue({ eq: byStatus });
    runtime.createServerClient.mockReturnValue({
      auth: { signInWithPassword },
      rpc,
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
    });

    const gateway = await createServerPasswordSignInGateway();

    await expect(gateway.signIn({
      email: "operator@voya.example",
      password: "correct horse battery staple",
    })).resolves.toEqual({ status: "signed_in" });
    expect(rpc.mock.calls[0]).toEqual(["consume_auth_rate_limit", {
      p_scope: "password_sign_in",
      p_key_hash: expect.stringMatching(/^[0-9a-f]{64}$/u),
    }]);
    expect(signInWithPassword).toHaveBeenCalledWith({
      email: "operator@voya.example",
      password: "correct horse battery staple",
    });
    expect(rpc.mock.calls[1]?.[0]).toBe("bootstrap_personal_workspace");
    expect(rpc.mock.calls[1]?.[1]).toEqual({ p_request_id: expect.stringMatching(/^[0-9a-f-]{36}$/u) });
  });

  it("returns safe invalid-credential feedback and never bootstraps a failed session", async () => {
    const signInWithPassword = vi.fn().mockResolvedValue({
      data: { user: null },
      error: { code: "invalid_credentials", status: 400 },
    });
    const rpc = vi.fn().mockResolvedValue({ data: true, error: null });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({ auth: { signInWithPassword }, rpc });

    const gateway = await createServerPasswordSignInGateway();

    await expect(gateway.signIn({ email: "operator@voya.example", password: "incorrect password" }))
      .resolves.toEqual({ status: "invalid_credentials" });
    expect(rpc).toHaveBeenCalledTimes(1);
  });

  it("keeps an existing active membership without creating an unrelated personal workspace", async () => {
    const signInWithPassword = vi.fn().mockResolvedValue({ data: { user: { id: "user-a" } }, error: null });
    const rpc = vi.fn().mockResolvedValue({ data: true, error: null });
    const limit = vi.fn().mockResolvedValue({ data: [{ id: "membership-a" }], error: null });
    const byStatus = vi.fn().mockReturnValue({ limit });
    const byUser = vi.fn().mockReturnValue({ eq: byStatus });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({
      auth: { signInWithPassword },
      rpc,
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
    });

    const gateway = await createServerPasswordSignInGateway();

    await expect(gateway.signIn({
      email: "operator@voya.example",
      password: "correct horse battery staple",
    })).resolves.toEqual({ status: "signed_in" });
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(rpc).not.toHaveBeenCalledWith("bootstrap_personal_workspace", expect.anything());
  });
});
