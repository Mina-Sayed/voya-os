import { AuthSessionMissingError } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { refreshSupabaseSession, type ProxyClientFactory } from "./proxy-client";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("refreshSupabaseSession", () => {
  it.each(["sb-project-auth-token-code-verifier", "sb-project-auth-token-code-verifier.0", "sb-project-auth-token-flow-abcdefgh-code-verifier", "sb-project-auth-token-flows-code-verifier"])("preserves %s when SDK session cleanup queues its deletion", async (name) => {
    const request = new NextRequest("https://app.example.com/auth/callback?code=callback-code", {
      headers: { cookie: `sb-project-auth-token=expired; ${name}=keep` },
    });
    const factory: ProxyClientFactory = (_url, _key, options) => ({ auth: { getUser: async () => {
      options.cookies.setAll([
        { name: "sb-project-auth-token", value: "", options: { maxAge: 0, path: "/" } },
        { name, value: "", options: { maxAge: 0, path: "/" } },
      ]);
      return { error: { code: "refresh_token_not_found" } };
    } } });
    const response = await refreshSupabaseSession(request, factory, {
      url: "https://project.supabase.co", publishableKey: "publishable-key",
    });
    expect(response.cookies.get("sb-project-auth-token")?.value).toBe("");
    expect(response.cookies.get(name)).toBeUndefined();
    expect(request.cookies.get(name)?.value).toBe("keep");
  });

  it.each(["returned", "thrown"])("preserves pending PKCE cookies on a %s missing-session result", async (mode) => {
    const getUser = vi.fn(async () => {
      if (mode === "thrown") throw new AuthSessionMissingError();
      return { data: { user: null }, error: new AuthSessionMissingError() };
    });
    const request = new NextRequest("https://app.example.com/auth/callback?code=callback-code", {
      headers: { cookie: "sb-project-auth-token-code-verifier=verifier; sb-project-auth-token-flow-abcdefgh-code-verifier=slot; sb-project-auth-token-flows-code-verifier=index" },
    });
    const response = await refreshSupabaseSession(request, () => ({ auth: { getUser } }), {
      url: "https://project.supabase.co", publishableKey: "publishable-key",
    });
    for (const name of ["sb-project-auth-token-code-verifier", "sb-project-auth-token-flow-abcdefgh-code-verifier", "sb-project-auth-token-flows-code-verifier"]) {
      expect(request.cookies.get(name)?.value).toBeTruthy();
      expect(response.cookies.get(name)).toBeUndefined();
    }
  });

  it("removes invalid session chunks without deleting an ongoing OAuth verifier", async () => {
    const request = new NextRequest("https://app.example.com/forgot-password", {
      headers: { cookie: "sb-project-auth-token.0=expired; sb-project-auth-token.1=expired; sb-project-auth-token-code-verifier=keep" },
    });
    const getUser = vi.fn().mockResolvedValue({ error: { code: "refresh_token_not_found" } });
    const response = await refreshSupabaseSession(request, () => ({ auth: { getUser } }), {
      url: "https://project.supabase.co", publishableKey: "publishable-key",
    });
    expect(response.cookies.get("sb-project-auth-token.0")?.value).toBe("");
    expect(response.cookies.get("sb-project-auth-token.1")?.value).toBe("");
    expect(request.cookies.get("sb-project-auth-token-code-verifier")?.value).toBe("keep");
    expect(response.cookies.get("sb-project-auth-token-code-verifier")).toBeUndefined();
  });

  function deferred<T>() {
    let resolve!: (value: T | PromiseLike<T>) => void;
    const promise = new Promise<T>((resolvePromise) => {
      resolve = resolvePromise;
    });
    return { promise, resolve };
  }

  it("forwards refreshed cookies to the request and response", async () => {
    const getUser = vi.fn().mockResolvedValue({ data: { user: null }, error: null });
    let encoding: string | undefined;
    const factory: ProxyClientFactory = (_url, _key, options) => {
      encoding = options.cookies.encode;
      options.cookies.setAll([{ name: "sb-refreshed", value: "new-value", options: { httpOnly: true } }]);
      return { auth: { getUser } };
    };
    const request = new NextRequest("https://app.example.com/workspace", {
      headers: { cookie: "existing=value" },
    });

    const response = await refreshSupabaseSession(request, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });

    expect(getUser).toHaveBeenCalledOnce();
    expect(encoding).toBe("tokens-only");
    expect(request.cookies.get("sb-refreshed")?.value).toBe("new-value");
    expect(response.cookies.get("sb-refreshed")?.value).toBe("new-value");
  });

  it("forwards request headers used by nonce CSP and refreshed cookies", async () => {
    const getUser = vi.fn().mockResolvedValue({ data: { user: null }, error: null });
    let forwardedCookie: string | null = null;
    const factory: ProxyClientFactory = (_url, _key, options) => {
      options.cookies.setAll([{ name: "sb-refreshed", value: "new-value", options: {} }]);
      return { auth: { getUser } };
    };
    const request = new NextRequest("https://app.example.com/workspace", {
      headers: { cookie: "existing=value" },
    });
    const forwardedHeaders = new Headers({ "x-nonce": "nonce-value" });

    const response = await refreshSupabaseSession(request, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    }, forwardedHeaders);
    forwardedCookie = forwardedHeaders.get("cookie");

    expect(response.status).toBe(200);
    expect(forwardedHeaders.get("x-nonce")).toBe("nonce-value");
    expect(forwardedCookie).toContain("sb-refreshed=new-value");
  });

  it("passes the request cookies to the Supabase client before refreshing", async () => {
    const getUser = vi.fn().mockResolvedValue({ data: { user: { id: "user" } }, error: null });
    let incomingCookies: ReturnType<NextRequest["cookies"]["getAll"]> | undefined;
    const factory: ProxyClientFactory = (_url, _key, options) => {
      incomingCookies = options.cookies.getAll();
      return { auth: { getUser } };
    };
    const request = new NextRequest("https://app.example.com/workspace", {
      headers: { cookie: "sb-access-token=token-value" },
    });

    await refreshSupabaseSession(request, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });

    expect(incomingCookies).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "sb-access-token", value: "token-value" }),
    ]));
  });

  it("returns a pass-through response when refresh fails", async () => {
    const getUser = vi.fn().mockResolvedValue({ data: { user: null }, error: new Error("secret provider detail") });
    const factory: ProxyClientFactory = () => ({ auth: { getUser } });
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const request = new NextRequest("https://app.example.com/workspace");

    const response = await refreshSupabaseSession(request, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });

    expect(response.status).toBe(200);
    expect(await response.text()).not.toContain("secret provider detail");
    expect(write).toHaveBeenCalledWith(expect.stringContaining('"code":"session_refresh_failed"'));
    expect(write.mock.calls.flat().join(" ")).not.toContain("secret provider detail");
  });

  it("does not log Supabase's expected missing-session result as a refresh failure", async () => {
    const getUser = vi.fn().mockResolvedValue({ data: { user: null }, error: new AuthSessionMissingError() });
    const factory: ProxyClientFactory = () => ({ auth: { getUser } });
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const request = new NextRequest("https://app.example.com/workspace");

    const response = await refreshSupabaseSession(request, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });

    expect(response.status).toBe(200);
    expect(write).not.toHaveBeenCalled();
  });

  it("does not log a thrown missing-session error as a refresh failure", async () => {
    const factory: ProxyClientFactory = () => ({
      auth: { getUser: vi.fn().mockRejectedValue(new AuthSessionMissingError()) },
    });
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const request = new NextRequest("https://app.example.com/workspace");

    await refreshSupabaseSession(request, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });

    expect(write).not.toHaveBeenCalled();
  });

  it("does not log an invalid refresh token as a provider failure", async () => {
    const getUser = vi.fn().mockResolvedValue({
      data: { user: null },
      error: Object.assign(new Error("refresh token is stale"), { code: "refresh_token_not_found" }),
    });
    const factory: ProxyClientFactory = () => ({ auth: { getUser } });
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const request = new NextRequest("https://app.example.com/workspace");

    const response = await refreshSupabaseSession(request, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });

    expect(response.status).toBe(200);
    expect(write).not.toHaveBeenCalled();
  });

  it("does not log a deleted auth user as a provider failure", async () => {
    const getUser = vi.fn().mockResolvedValue({
      data: { user: null },
      error: Object.assign(new Error("auth user no longer exists"), { code: "user_not_found" }),
    });
    const factory: ProxyClientFactory = () => ({ auth: { getUser } });
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const request = new NextRequest("https://app.example.com/workspace");

    const response = await refreshSupabaseSession(request, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });

    expect(response.status).toBe(200);
    expect(write).not.toHaveBeenCalled();
  });

  it("does not clear cookies when a concurrent refresh cannot be recovered", async () => {
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const factory: ProxyClientFactory = (_url, _key, options) => {
      options.cookies.setAll([{ name: "sb-project-auth-token", value: "", options: { maxAge: 0 } }]);
      return {
        auth: {
          getUser: vi.fn().mockResolvedValue({
            data: { user: null },
            error: Object.assign(new Error("refresh token already used"), { code: "refresh_token_already_used" }),
          }),
        },
      };
    };
    const request = new NextRequest("https://app.example.com/workspace", {
      headers: { cookie: "sb-project-auth-token=still-valid-in-another-request" },
    });

    const response = await refreshSupabaseSession(request, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });

    expect(request.cookies.get("sb-project-auth-token")?.value).toBe("still-valid-in-another-request");
    expect(response.cookies.get("sb-project-auth-token")).toBeUndefined();
    expect(write).not.toHaveBeenCalled();
  });

  it("reuses recently rotated cookies for a late parallel request", async () => {
    const getUser = vi.fn().mockResolvedValue({ data: { user: { id: "user" } }, error: null });
    const factory = vi.fn<ProxyClientFactory>((_url, _key, options) => {
      options.cookies.setAll([{ name: "sb-project-auth-token", value: "rotated-after-grace", options: { httpOnly: true } }]);
      return { auth: { getUser } };
    });
    const firstRequest = new NextRequest("https://app.example.com/workspace", {
      headers: { cookie: "sb-project-auth-token=expired-before-grace" },
    });
    const secondRequest = new NextRequest("https://app.example.com/workspace/leads", {
      headers: { cookie: "sb-project-auth-token=expired-before-grace" },
    });

    const firstResponse = await refreshSupabaseSession(firstRequest, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });
    const secondResponse = await refreshSupabaseSession(secondRequest, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });

    expect(factory).toHaveBeenCalledOnce();
    expect(firstRequest.cookies.get("sb-project-auth-token")?.value).toBe("rotated-after-grace");
    expect(secondRequest.cookies.get("sb-project-auth-token")?.value).toBe("rotated-after-grace");
    expect(firstResponse.cookies.get("sb-project-auth-token")?.value).toBe("rotated-after-grace");
    expect(secondResponse.cookies.get("sb-project-auth-token")?.value).toBe("rotated-after-grace");
  });

  it("single-flights refreshes for concurrent requests with the same session", async () => {
    const started = deferred<void>();
    const release = deferred<void>();
    const getUser = vi.fn(async () => {
      started.resolve();
      await release.promise;
      return { data: { user: { id: "user" } }, error: null };
    });
    const factory = vi.fn<ProxyClientFactory>((_url, _key, options) => {
      options.cookies.setAll([{ name: "sb-project-auth-token", value: "rotated-session", options: { httpOnly: true } }]);
      return { auth: { getUser } };
    });
    const firstRequest = new NextRequest("https://app.example.com/workspace", {
      headers: { cookie: "sb-project-auth-token=expired-session" },
    });
    const secondRequest = new NextRequest("https://app.example.com/workspace/activity", {
      headers: { cookie: "sb-project-auth-token=expired-session" },
    });

    const firstResponsePromise = refreshSupabaseSession(firstRequest, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });
    await started.promise;
    const secondResponsePromise = refreshSupabaseSession(secondRequest, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });
    release.resolve();
    const [firstResponse, secondResponse] = await Promise.all([firstResponsePromise, secondResponsePromise]);

    expect(factory).toHaveBeenCalledOnce();
    expect(getUser).toHaveBeenCalledOnce();
    expect(firstRequest.cookies.get("sb-project-auth-token")?.value).toBe("rotated-session");
    expect(secondRequest.cookies.get("sb-project-auth-token")?.value).toBe("rotated-session");
    expect(firstResponse.cookies.get("sb-project-auth-token")?.value).toBe("rotated-session");
    expect(secondResponse.cookies.get("sb-project-auth-token")?.value).toBe("rotated-session");
  });

  it("returns a pass-through response when public configuration is unavailable", async () => {
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "");
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "");
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const factory = vi.fn<ProxyClientFactory>();
    const request = new NextRequest("https://app.example.com/workspace");

    const response = await refreshSupabaseSession(request, factory);

    expect(response.status).toBe(200);
    expect(factory).not.toHaveBeenCalled();
    expect(write).toHaveBeenCalledWith(expect.stringContaining('"operation":"supabase.session_refresh"'));
    expect(write.mock.calls.flat().join(" ")).not.toContain("configuration is incomplete");
  });
});

describe("refreshSupabaseSession request correlation", () => {
  it("logs refresh failures under the forwarded request id", async () => {
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const factory: ProxyClientFactory = () => {
      throw new Error("refresh transport down");
    };
    const request = new NextRequest("https://app.example.com/workspace");
    const forwardedHeaders = new Headers({ "x-request-id": "support-case-7" });

    await refreshSupabaseSession(request, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    }, forwardedHeaders);

    const logged = write.mock.calls.map((args) => String(args[0]));
    expect(logged.some((line) => line.includes('"request_id":"support-case-7"'))).toBe(true);
  });
});
