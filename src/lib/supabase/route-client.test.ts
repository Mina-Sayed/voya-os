import { afterEach, describe, expect, it, vi } from "vitest";
import { NextRequest, NextResponse } from "next/server";

const runtime = vi.hoisted(() => ({
  createServerClient: vi.fn(),
  readSupabasePublicConfig: vi.fn(),
}));

vi.mock("@supabase/ssr", () => ({
  createServerClient: runtime.createServerClient,
}));

vi.mock("./public-config", () => ({
  readSupabasePublicConfig: runtime.readSupabasePublicConfig,
}));

import { createRouteSupabaseClient } from "./route-client";

afterEach(() => {
  vi.clearAllMocks();
});

describe("createRouteSupabaseClient", () => {
  it("uses PKCE and forwards refreshed cookies to the callback response", () => {
    runtime.readSupabasePublicConfig.mockReturnValue({
      url: "https://project.supabase.co",
      publishableKey: "publishable-key",
    });
    let options: Record<string, unknown> | undefined;
    runtime.createServerClient.mockImplementation((_url, _key, receivedOptions) => {
      options = receivedOptions;
      return { auth: {} };
    });
    const request = new NextRequest("https://app.voya.example/auth/callback", {
      headers: { cookie: "existing=value" },
    });
    const response = NextResponse.redirect("https://app.voya.example/access-pending");

    createRouteSupabaseClient(request, response);

    expect(options?.auth).toEqual({ flowType: "pkce" });
    expect((options?.cookies as { encode?: string }).encode).toBe("tokens-only");
    const cookieAdapter = options?.cookies as { getAll(): unknown; setAll(items: Array<{ name: string; value: string; options?: Record<string, unknown> }>): void };
    expect(cookieAdapter.getAll()).toEqual(expect.arrayContaining([
      expect.objectContaining({ name: "existing", value: "value" }),
    ]));
    cookieAdapter.setAll([{ name: "sb-session", value: "session", options: { httpOnly: true } }]);
    expect(response.cookies.get("sb-session")?.value).toBe("session");
  });
});
