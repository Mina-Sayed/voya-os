import { AuthSessionMissingError } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { refreshSupabaseSession, type ProxyClientFactory } from "./proxy-client";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("refreshSupabaseSession", () => {
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
