import { afterEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";

const mocks = vi.hoisted(() => ({
  createRouteClient: vi.fn(),
}));

vi.mock("@/lib/supabase/route-client", () => ({
  createRouteSupabaseClient: mocks.createRouteClient,
}));

import { GET } from "./route";

afterEach(() => {
  vi.clearAllMocks();
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("GET /auth/callback", () => {
  it("redirects an internal production callback to the configured application origin", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");

    const response = await GET(new NextRequest("http://internal:3000/auth/callback"));

    expect(response.headers.get("location")).toBe("https://app.voya.example/access-pending");
  });

  it("redirects a successful active membership callback to workspace on the configured origin", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");
    const limit = vi.fn().mockResolvedValue({ data: [{ id: "membership" }], error: null });
    const byStatus = vi.fn().mockReturnValue({ limit });
    const byUser = vi.fn().mockReturnValue({ eq: byStatus });
    mocks.createRouteClient.mockReturnValue({
      auth: {
        exchangeCodeForSession: vi.fn().mockResolvedValue({ error: null }),
        getUser: vi.fn().mockResolvedValue({ data: { user: { id: "user" } }, error: null }),
      },
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
    });

    const response = await GET(new NextRequest("http://internal:3000/auth/callback?code=callback-code"));

    expect(byStatus).toHaveBeenCalledWith("status", "active");
    expect(limit).toHaveBeenCalledWith(1);
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://app.voya.example/workspace");
  });

  it("preserves the loopback request origin during local development", async () => {
    vi.stubEnv("NODE_ENV", "development");
    vi.stubEnv("VOYA_APP_URL", "");

    const request = new NextRequest("http://127.0.0.1:3000/auth/callback");
    Object.defineProperty(request, "url", { value: "http://127.0.0.1:3000/auth/callback" });
    const response = await GET(request);

    expect(response.headers.get("location")).toBe("http://127.0.0.1:3000/access-pending");
  });

  it("logs safe metadata and uses a fixed pending path when production origin configuration fails", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("VOYA_APP_URL", "https://operator:secret@app.voya.example");
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await GET(new NextRequest("http://internal:3000/auth/callback?code=code-secret"));

    expect(response.headers.get("location")).toBe("/access-pending");
    expect(write).toHaveBeenCalledWith(expect.stringContaining('"code":"callback_configuration_failed"'));
    expect(write.mock.calls.flat().join(" ")).not.toContain("secret");
  });

  it("logs a sanitized exchange dependency failure before returning access pending", async () => {
    mocks.createRouteClient.mockReturnValue({
      auth: {
        exchangeCodeForSession: vi.fn().mockResolvedValue({ error: new Error("code=secret customer@example.com") }),
      },
    });
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await GET(new NextRequest("https://app.example.com/auth/callback?code=secret"));

    expect(response.headers.get("location")).toBe("https://app.example.com/access-pending");
    expect(write).toHaveBeenCalledWith(expect.stringContaining('"operation":"auth.callback.exchange"'));
    expect(write.mock.calls.flat().join(" ")).not.toContain("secret");
    expect(write.mock.calls.flat().join(" ")).not.toContain("customer@example.com");
  });

  it.each([
    ["user", "auth.callback.user", () => ({
      auth: {
        exchangeCodeForSession: vi.fn().mockResolvedValue({ error: null }),
        getUser: vi.fn().mockResolvedValue({ data: { user: null }, error: new Error("token=secret") }),
      },
    })],
    ["memberships", "auth.callback.memberships", () => {
      const limit = vi.fn().mockResolvedValue({ data: null, error: new Error("customer@example.com") });
      const byStatus = vi.fn().mockReturnValue({ limit });
      const byUser = vi.fn().mockReturnValue({ eq: byStatus });
      return {
        auth: {
          exchangeCodeForSession: vi.fn().mockResolvedValue({ error: null }),
          getUser: vi.fn().mockResolvedValue({ data: { user: { id: "user" } }, error: null }),
        },
        from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
      };
    }],
  ])("logs a sanitized %s dependency failure", async (_stage, operation, createClient) => {
    mocks.createRouteClient.mockReturnValue(createClient());
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await GET(new NextRequest("https://app.example.com/auth/callback?code=secret"));

    expect(write).toHaveBeenCalledWith(expect.stringContaining(`"operation":"${operation}"`));
    expect(write.mock.calls.flat().join(" ")).not.toContain("secret");
    expect(write.mock.calls.flat().join(" ")).not.toContain("customer@example.com");
  });

  it("logs a sanitized thrown dependency failure", async () => {
    mocks.createRouteClient.mockImplementation(() => { throw new Error("code=secret"); });
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    await GET(new NextRequest("https://app.example.com/auth/callback?code=secret"));

    expect(write).toHaveBeenCalledWith(expect.stringContaining('"operation":"auth.callback.dependency"'));
    expect(write.mock.calls.flat().join(" ")).not.toContain("secret");
  });
});
