import { AuthSessionMissingError } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { refreshSupabaseSession, type ProxyClientFactory } from "./proxy-client";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("refreshSupabaseSession", () => {
  it("redirects an authenticated AAL1 workspace request to MFA and preserves refreshed cookies", async () => {
    const getAuthenticatorAssuranceLevel = vi.fn().mockResolvedValue({
      data: { currentLevel: "aal1", nextLevel: "aal2" },
      error: null,
    });
    const factory: ProxyClientFactory = (_url, _key, options) => {
      options.cookies.setAll([{ name: "sb-refreshed", value: "new-value", options: { httpOnly: true } }]);
      return {
        auth: {
          getUser: vi.fn().mockResolvedValue({ data: { user: { id: "user-a" } }, error: null }),
          mfa: { getAuthenticatorAssuranceLevel },
        },
      };
    };

    const response = await refreshSupabaseSession(
      new NextRequest("https://app.example.com/workspace/bookings"),
      factory,
      { url: "https://project.supabase.co", publishableKey: "publishable-key" },
    );

    expect(response.headers.get("location")).toBe("https://app.example.com/mfa");
    expect(response.cookies.get("sb-refreshed")?.value).toBe("new-value");
    expect(getAuthenticatorAssuranceLevel).toHaveBeenCalledOnce();
  });

  it("fails a protected authenticated request closed when MFA assurance cannot be read", async () => {
    const getAuthenticatorAssuranceLevel = vi.fn().mockResolvedValue({
      data: null,
      error: new Error("provider unavailable"),
    });
    const factory: ProxyClientFactory = () => ({
      auth: {
        getUser: vi.fn().mockResolvedValue({ data: { user: { id: "user-a" } }, error: null }),
        mfa: { getAuthenticatorAssuranceLevel },
      },
    });
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await refreshSupabaseSession(
      new NextRequest("https://app.example.com/workspace"),
      factory,
      { url: "https://project.supabase.co", publishableKey: "publishable-key" },
    );

    expect(response.headers.get("location")).toBe("https://app.example.com/access-pending");
    expect(write.mock.calls.flat().join(" ")).not.toContain("provider unavailable");
  });

  it("fails a protected authenticated request closed for malformed MFA assurance levels", async () => {
    const factory: ProxyClientFactory = () => ({
      auth: {
        getUser: vi.fn().mockResolvedValue({ data: { user: { id: "user-a" } }, error: null }),
        mfa: {
          getAuthenticatorAssuranceLevel: vi.fn().mockResolvedValue({
            data: { currentLevel: null, nextLevel: null },
            error: null,
          }),
        },
      },
    });
    vi.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await refreshSupabaseSession(
      new NextRequest("https://app.example.com/workspace"),
      factory,
      { url: "https://project.supabase.co", publishableKey: "publishable-key" },
    );

    expect(response.headers.get("location")).toBe("https://app.example.com/access-pending");
  });

  it("does not challenge the public MFA route again", async () => {
    const getAuthenticatorAssuranceLevel = vi.fn();
    const factory: ProxyClientFactory = () => ({
      auth: {
        getUser: vi.fn().mockResolvedValue({ data: { user: { id: "user-a" } }, error: null }),
        mfa: { getAuthenticatorAssuranceLevel },
      },
    });

    const response = await refreshSupabaseSession(
      new NextRequest("https://app.example.com/mfa"),
      factory,
      { url: "https://project.supabase.co", publishableKey: "publishable-key" },
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("location")).toBeNull();
    expect(getAuthenticatorAssuranceLevel).not.toHaveBeenCalled();
  });

  it("forwards refreshed cookies to the request and response", async () => {
    const getUser = vi.fn().mockResolvedValue({ data: { user: null }, error: null });
    const factory: ProxyClientFactory = (_url, _key, options) => {
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
    expect(request.cookies.get("sb-refreshed")?.value).toBe("new-value");
    expect(response.cookies.get("sb-refreshed")?.value).toBe("new-value");
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

  it("fails a protected request closed when session refresh fails", async () => {
    const getUser = vi.fn().mockResolvedValue({ data: { user: null }, error: new Error("secret provider detail") });
    const factory: ProxyClientFactory = () => ({ auth: { getUser } });
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const request = new NextRequest("https://app.example.com/workspace");

    const response = await refreshSupabaseSession(request, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });

    expect(response.headers.get("location")).toBe("https://app.example.com/access-pending");
    expect(await response.text()).not.toContain("secret provider detail");
    expect(write).toHaveBeenCalledWith(expect.stringContaining('"code":"session_refresh_failed"'));
    expect(write.mock.calls.flat().join(" ")).not.toContain("secret provider detail");
  });

  it("keeps a public request pass-through when session refresh fails", async () => {
    const getUser = vi.fn().mockResolvedValue({ data: { user: null }, error: new Error("secret provider detail") });
    const factory: ProxyClientFactory = () => ({ auth: { getUser } });
    vi.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await refreshSupabaseSession(
      new NextRequest("https://app.example.com/sign-in"),
      factory,
      { url: "https://project.supabase.co", publishableKey: "publishable-key" },
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("location")).toBeNull();
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

  it("fails a protected request closed when public configuration is invalid", async () => {
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "http://project.supabase.co");
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "publishable-key");
    vi.stubEnv("NODE_ENV", "production");
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const factory = vi.fn<ProxyClientFactory>();

    const response = await refreshSupabaseSession(
      new NextRequest("https://app.example.com/workspace"),
      factory,
    );

    expect(response.headers.get("location")).toBe("https://app.example.com/access-pending");
    expect(factory).not.toHaveBeenCalled();
    expect(write.mock.calls.flat().join(" ")).not.toContain("http://project.supabase.co");
  });
});
