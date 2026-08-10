import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const runtime = vi.hoisted(() => ({
  createClient: vi.fn(),
  createServerClient: vi.fn(),
  cookies: vi.fn(),
  headers: vi.fn(),
  readSupabasePublicConfig: vi.fn(),
}));

vi.mock("@supabase/supabase-js", () => ({
  createClient: runtime.createClient,
}));

vi.mock("@supabase/ssr", () => ({
  createServerClient: runtime.createServerClient,
}));

vi.mock("next/headers", () => ({
  cookies: runtime.cookies,
  headers: runtime.headers,
}));

vi.mock("./public-config", () => ({
  readSupabasePublicConfig: runtime.readSupabasePublicConfig,
}));

import {
  createServerMagicLinkGateway,
  createServerPasswordSignInGateway,
  createServerSupabaseClient,
} from "./server-auth";

beforeEach(() => {
  vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key");
  vi.stubEnv("VERCEL", "1");
  runtime.headers.mockResolvedValue({
    get: vi.fn((name: string) => name === "x-forwarded-for" ? "203.0.113.9" : null),
  });
});

afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
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
  it("fails closed before limiter or provider access when the server secret is missing", async () => {
    const signInWithOtp = vi.fn();
    const cookieClientRpc = vi.fn();
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "");
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({ auth: { signInWithOtp }, rpc: cookieClientRpc });

    const gateway = await createServerMagicLinkGateway();

    await expect(gateway.requestMagicLink({
      email: "operator@voya.example",
      redirectTo: "https://app.voya.example/auth/callback",
    })).rejects.toThrow();
    expect(runtime.createClient).not.toHaveBeenCalled();
    expect(cookieClientRpc).not.toHaveBeenCalled();
    expect(signInWithOtp).not.toHaveBeenCalled();
  });

  it("consumes an address-bound limiter through a server-only service-role client", async () => {
    const signInWithOtp = vi.fn().mockResolvedValue({ error: null });
    const cookieClientRpc = vi.fn().mockResolvedValue({ data: true, error: null });
    const limiterRpc = vi.fn().mockResolvedValue({ data: true, error: null });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({ auth: { signInWithOtp }, rpc: cookieClientRpc });
    runtime.createClient.mockReturnValue({ rpc: limiterRpc });

    const gateway = await createServerMagicLinkGateway();
    await expect(gateway.requestMagicLink({ email: "operator@voya.example", redirectTo: "https://app.voya.example/auth/callback" }))
      .resolves.toBe("sent");

    expect(signInWithOtp).toHaveBeenCalledWith({
      email: "operator@voya.example",
      options: { emailRedirectTo: "https://app.voya.example/auth/callback" },
    });
    expect(runtime.createClient).toHaveBeenCalledWith(
      "https://project.supabase.co",
      "service-role-key",
      { auth: { autoRefreshToken: false, persistSession: false } },
    );
    expect(limiterRpc).toHaveBeenCalledWith("consume_auth_rate_limit", {
      p_scope: "magic_link",
      p_key_hash: "c31553741820135d7ac3012797da3cbc28a625fd91f50d9d4f8beffde26ee01d",
    });
    expect(limiterRpc.mock.calls[0]?.[1]).not.toHaveProperty("p_limit");
    expect(limiterRpc.mock.calls[0]?.[1]).not.toHaveProperty("p_window_seconds");
    expect(cookieClientRpc).not.toHaveBeenCalled();
  });

  it("ignores caller-controlled forwarding headers outside trusted ingress", async () => {
    const limiterRpc = vi.fn().mockResolvedValue({ data: true, error: null });
    vi.stubEnv("VERCEL", "");
    runtime.headers.mockResolvedValue({
      get: vi.fn((name: string) => {
        if (name === "x-forwarded-for") return "198.51.100.25";
        if (name === "x-real-ip") return "198.51.100.26";
        return null;
      }),
    });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({ auth: { signInWithOtp: vi.fn().mockResolvedValue({ error: null }) } });
    runtime.createClient.mockReturnValue({ rpc: limiterRpc });

    const gateway = await createServerMagicLinkGateway();

    await gateway.requestMagicLink({
      email: "operator@voya.example",
      redirectTo: "https://app.voya.example/auth/callback",
    });
    expect(limiterRpc).toHaveBeenCalledWith("consume_auth_rate_limit", {
      p_scope: "magic_link",
      p_key_hash: "a435935d7d0bb03184cc1f91fe22ad467397d3e9ed4b666d3b5b75c021ab4e22",
    });
  });

  it("surfaces a returned magic-link provider failure to the server action", async () => {
    const providerError = new Error("provider unavailable");
    const signInWithOtp = vi.fn().mockResolvedValue({ error: providerError });
    const rpc = vi.fn().mockResolvedValue({ data: true, error: null });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({ auth: { signInWithOtp }, rpc });
    runtime.createClient.mockReturnValue({ rpc });

    const gateway = await createServerMagicLinkGateway();

    await expect(gateway.requestMagicLink({ email: "operator@voya.example", redirectTo: "https://app.voya.example/auth/callback" }))
      .rejects.toBe(providerError);
  });

  it("does not ask Supabase Auth for another link when the database bucket denies it", async () => {
    const signInWithOtp = vi.fn();
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    const rpc = vi.fn().mockResolvedValue({ data: false, error: null });
    runtime.createServerClient.mockReturnValue({
      auth: { signInWithOtp },
      rpc,
    });
    runtime.createClient.mockReturnValue({ rpc });

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
    const signInWithPassword = vi.fn().mockResolvedValue({
      data: { user: { id: "user-a", email_confirmed_at: "2026-08-10T10:00:00.000Z" } },
      error: null,
    });
    const limiterRpc = vi.fn().mockResolvedValue({ data: true, error: null });
    const rpc = vi.fn().mockResolvedValue({ data: [{ organization_id: "organization-a" }], error: null });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    const byUser = vi.fn().mockResolvedValue({ data: [], error: null });
    runtime.createServerClient.mockReturnValue({
      auth: { signInWithPassword },
      rpc,
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
    });
    runtime.createClient.mockReturnValue({ rpc: limiterRpc });

    const gateway = await createServerPasswordSignInGateway();

    await expect(gateway.signIn({
      email: "operator@voya.example",
      password: "correct horse battery staple",
    })).resolves.toEqual({ status: "signed_in" });
    expect(limiterRpc).toHaveBeenCalledWith("consume_auth_rate_limit", {
      p_scope: "password_sign_in",
      p_key_hash: "c31553741820135d7ac3012797da3cbc28a625fd91f50d9d4f8beffde26ee01d",
    });
    expect(signInWithPassword).toHaveBeenCalledWith({
      email: "operator@voya.example",
      password: "correct horse battery staple",
    });
    expect(rpc).toHaveBeenCalledWith("bootstrap_personal_workspace", {
      p_request_id: expect.stringMatching(/^[0-9a-f-]{36}$/u),
    });
  });

  it("returns access pending for an existing suspended membership without bootstrapping", async () => {
    const signInWithPassword = vi.fn().mockResolvedValue({
      data: { user: { id: "user-a", email_confirmed_at: "2026-08-10T10:00:00.000Z" } },
      error: null,
    });
    const limiterRpc = vi.fn().mockResolvedValue({ data: true, error: null });
    const allMemberships = {
      data: [{ id: "membership-suspended", status: "suspended" }],
      error: null,
    };
    const byUser = vi.fn().mockResolvedValue(allMemberships);
    const rpc = vi.fn().mockResolvedValue({ data: [{ organization_id: "organization-a" }], error: null });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({
      auth: { signInWithPassword },
      rpc,
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
    });
    runtime.createClient.mockReturnValue({ rpc: limiterRpc });

    const gateway = await createServerPasswordSignInGateway();

    await expect(gateway.signIn({
      email: "operator@voya.example",
      password: "correct horse battery staple",
    })).resolves.toEqual({ status: "access_pending" });
    expect(rpc).not.toHaveBeenCalled();
  });

  it("returns access pending without bootstrapping when the authenticated email is unconfirmed", async () => {
    const signInWithPassword = vi.fn().mockResolvedValue({
      data: { user: { id: "user-a", email_confirmed_at: null } },
      error: null,
    });
    const limiterRpc = vi.fn().mockResolvedValue({ data: true, error: null });
    const rpc = vi.fn().mockResolvedValue({ data: [{ organization_id: "organization-a" }], error: null });
    const byUser = vi.fn().mockResolvedValue({ data: [], error: null });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({
      auth: { signInWithPassword },
      rpc,
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
    });
    runtime.createClient.mockReturnValue({ rpc: limiterRpc });

    const gateway = await createServerPasswordSignInGateway();

    await expect(gateway.signIn({
      email: "operator@voya.example",
      password: "correct horse battery staple",
    })).resolves.toEqual({ status: "access_pending" });
    expect(rpc).not.toHaveBeenCalled();
  });

  it("returns access pending when the membership lookup does not prove there are zero memberships", async () => {
    const signInWithPassword = vi.fn().mockResolvedValue({
      data: { user: { id: "user-a", email_confirmed_at: "2026-08-10T10:00:00.000Z" } },
      error: null,
    });
    const limiterRpc = vi.fn().mockResolvedValue({ data: true, error: null });
    const rpc = vi.fn();
    const byUser = vi.fn().mockResolvedValue({ data: null, error: null });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({
      auth: { signInWithPassword },
      rpc,
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
    });
    runtime.createClient.mockReturnValue({ rpc: limiterRpc });

    const gateway = await createServerPasswordSignInGateway();

    await expect(gateway.signIn({
      email: "operator@voya.example",
      password: "correct horse battery staple",
    })).resolves.toEqual({ status: "access_pending" });
    expect(rpc).not.toHaveBeenCalled();
  });

  it("returns safe invalid-credential feedback and never bootstraps a failed session", async () => {
    const signInWithPassword = vi.fn().mockResolvedValue({
      data: { user: null },
      error: { code: "invalid_credentials", status: 400 },
    });
    const limiterRpc = vi.fn().mockResolvedValue({ data: true, error: null });
    const rpc = vi.fn();
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({ auth: { signInWithPassword }, rpc });
    runtime.createClient.mockReturnValue({ rpc: limiterRpc });

    const gateway = await createServerPasswordSignInGateway();

    await expect(gateway.signIn({ email: "operator@voya.example", password: "incorrect password" }))
      .resolves.toEqual({ status: "invalid_credentials" });
    expect(rpc).not.toHaveBeenCalled();
  });

  it("keeps an existing active membership without creating an unrelated personal workspace", async () => {
    const signInWithPassword = vi.fn().mockResolvedValue({ data: { user: { id: "user-a" } }, error: null });
    const limiterRpc = vi.fn().mockResolvedValue({ data: true, error: null });
    const rpc = vi.fn();
    const byUser = vi.fn().mockResolvedValue({
      data: [{ id: "membership-a", status: "active" }],
      error: null,
    });
    runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
    runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
    runtime.createServerClient.mockReturnValue({
      auth: { signInWithPassword },
      rpc,
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
    });
    runtime.createClient.mockReturnValue({ rpc: limiterRpc });

    const gateway = await createServerPasswordSignInGateway();

    await expect(gateway.signIn({
      email: "operator@voya.example",
      password: "correct horse battery staple",
    })).resolves.toEqual({ status: "signed_in" });
    expect(rpc).not.toHaveBeenCalled();
    expect(rpc).not.toHaveBeenCalledWith("bootstrap_personal_workspace", expect.anything());
  });

  it.each(["membership lookup", "workspace bootstrap"])(
    "signs out an authenticated session after a %s failure",
    async (failurePoint) => {
      const dependencyError = new Error(`${failurePoint} unavailable`);
      const signInWithPassword = vi.fn().mockResolvedValue({
        data: { user: { id: "user-a", email_confirmed_at: "2026-08-10T10:00:00.000Z" } },
        error: null,
      });
      const signOut = vi.fn().mockResolvedValue({ error: null });
      const limiterRpc = vi.fn().mockResolvedValue({ data: true, error: null });
      const rpc = vi.fn().mockResolvedValue({
        data: null,
        error: failurePoint === "workspace bootstrap" ? dependencyError : null,
      });
      const membershipResult =
        failurePoint === "membership lookup"
          ? { data: null, error: dependencyError }
          : { data: [], error: null };
      const byUser = vi.fn().mockResolvedValue(membershipResult);
      runtime.cookies.mockResolvedValue({ getAll: vi.fn(), set: vi.fn() });
      runtime.readSupabasePublicConfig.mockReturnValue({ url: "https://project.supabase.co", publishableKey: "publishable-key" });
      runtime.createServerClient.mockReturnValue({
        auth: { signInWithPassword, signOut },
        rpc,
        from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
      });
      runtime.createClient.mockReturnValue({ rpc: limiterRpc });

      const gateway = await createServerPasswordSignInGateway();

      await expect(gateway.signIn({
        email: "operator@voya.example",
        password: "correct horse battery staple",
      })).rejects.toBe(dependencyError);
      expect(signOut).toHaveBeenCalledOnce();
      expect(signOut).toHaveBeenCalledWith({ scope: "local" });
    },
  );
});
