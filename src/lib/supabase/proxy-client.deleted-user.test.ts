import { NextRequest } from "next/server";
import { describe, expect, it, vi } from "vitest";
import { refreshSupabaseSession, type ProxyClientFactory } from "./proxy-client";

describe("refreshSupabaseSession deleted-user recovery", () => {
  it("expires stale Supabase auth cookies while preserving unrelated request state", async () => {
    const getUser = vi.fn().mockResolvedValue({
      data: { user: null },
      error: Object.assign(new Error("auth user no longer exists"), { code: "user_not_found" }),
    });
    const factory: ProxyClientFactory = () => ({ auth: { getUser } });
    const request = new NextRequest("https://app.example.com/workspace", {
      headers: { cookie: "sb-project-auth-token=deleted-user-session; theme=dark" },
    });
    const forwardedHeaders = new Headers({ "x-nonce": "nonce-value" });

    const response = await refreshSupabaseSession(request, factory, {
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    }, forwardedHeaders);

    expect(getUser).toHaveBeenCalledOnce();
    expect(request.cookies.get("sb-project-auth-token")?.value).toBe("");
    expect(request.cookies.get("theme")?.value).toBe("dark");
    expect(response.headers.get("set-cookie")).toContain("sb-project-auth-token=");
    expect(response.headers.get("set-cookie")).toContain("Max-Age=0");
    expect(forwardedHeaders.get("cookie")).toContain("theme=dark");
    expect(forwardedHeaders.get("cookie")).not.toContain("deleted-user-session");
    expect(forwardedHeaders.get("x-nonce")).toBe("nonce-value");
  });
});
