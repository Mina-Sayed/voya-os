import { afterEach, describe, expect, it, vi } from "vitest";

const runtime = vi.hoisted(() => ({
  createServerClient: vi.fn(),
  cookies: vi.fn(),
  readSupabasePublicConfig: vi.fn(),
}));

const TestSupabaseConfigurationError = vi.hoisted(() => class extends Error {});

vi.mock("@supabase/ssr", () => ({
  createServerClient: runtime.createServerClient,
}));

vi.mock("next/headers", () => ({
  cookies: runtime.cookies,
}));

vi.mock("./public-config", () => ({
  readSupabasePublicConfig: runtime.readSupabasePublicConfig,
  SupabaseConfigurationError: TestSupabaseConfigurationError,
}));

import { createServerGoogleSignInGateway, createServerPasswordGateway, createServerPasswordSignUpGateway, createServerSupabaseClient, createServiceRoleSupabaseClient } from "./server-auth";

afterEach(() => {
  vi.clearAllMocks();
  delete process.env.SUPABASE_SERVICE_ROLE_KEY;
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
    expect((adapter?.cookies as { encode?: string }).encode).toBe("tokens-only");
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

describe("createServiceRoleSupabaseClient", () => {
  it("fails closed when the server-only key is not configured", () => {
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    expect(() => createServiceRoleSupabaseClient()).toThrow(TestSupabaseConfigurationError);
  });

  it("does not expose a persistent session for server-only provider calls", () => {
    process.env.SUPABASE_SERVICE_ROLE_KEY = "server-only-key";
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    const client = createServiceRoleSupabaseClient();
    expect(client.auth).toBeDefined();
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

describe("createServerPasswordSignUpGateway", () => {
  it("creates a password account without creating a personal workspace", async () => {
    const signUp = vi.fn().mockResolvedValue({ data: { session: null }, error: null });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({ auth: { signUp } });

    const gateway = await createServerPasswordSignUpGateway();
    await expect(gateway.signUp({ email: "operator@voya.example", password: "safe-password", redirectTo: "https://app.voya.example/auth/callback" })).resolves.toEqual({ sessionAvailable: false });
    expect(signUp).toHaveBeenCalledWith({ email: "operator@voya.example", password: "safe-password", options: { emailRedirectTo: "https://app.voya.example/auth/callback" } });
  });
});

describe("createServerGoogleSignInGateway", () => {
  it("returns the provider URL without exposing provider details", async () => {
    const signInWithOAuth = vi.fn().mockResolvedValue({ data: { url: "https://accounts.google.example/oauth" }, error: null });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({ auth: { signInWithOAuth } });

    const gateway = await createServerGoogleSignInGateway();
    await expect(gateway.signInWithGoogle({ redirectTo: "https://app.voya.example/auth/callback" })).resolves.toBe("https://accounts.google.example/oauth");
    expect(signInWithOAuth).toHaveBeenCalledWith({ provider: "google", options: { redirectTo: "https://app.voya.example/auth/callback" } });
  });
});
