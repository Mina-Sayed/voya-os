import { AuthSessionMissingError } from "@supabase/supabase-js";
import { afterEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { refreshSupabaseSession, type ProxyClientFactory } from "./proxy-client";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

describe("refreshSupabaseSession", () => {
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
