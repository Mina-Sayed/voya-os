import { afterEach, describe, expect, it, vi } from "vitest";
import { NextRequest } from "next/server";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";

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

    expect(response.headers.get("location")).toBe("https://app.voya.example/sign-in?error=link_session");
  });

  it("redirects a successful active membership callback to workspace on the configured origin", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");
    const byUser = vi.fn().mockResolvedValue({
      data: [{ id: "membership", status: "active" }],
      error: null,
    });
    mocks.createRouteClient.mockReturnValue({
      auth: {
        exchangeCodeForSession: vi.fn().mockResolvedValue({ error: null }),
        getUser: vi.fn().mockResolvedValue({ data: { user: { id: "user" } }, error: null }),
      },
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
    });

    const response = await GET(new NextRequest("http://internal:3000/auth/callback?code=callback-code"));

    expect(byUser).toHaveBeenCalledWith("user_id", "user");
    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://app.voya.example/workspace");
  });

  it("continues when any active membership exists among all membership states", async () => {
    const allMemberships = {
      data: [
        { id: "membership-suspended", status: "suspended" },
        { id: "membership-active", status: "active" },
      ],
      error: null,
    };
    const byUser = vi.fn().mockResolvedValue(allMemberships);
    const rpc = vi.fn();
    mocks.createRouteClient.mockReturnValue({
      auth: {
        exchangeCodeForSession: vi.fn().mockResolvedValue({ error: null }),
        getUser: vi.fn().mockResolvedValue({
          data: { user: { id: "user", email_confirmed_at: "2026-08-10T10:00:00.000Z" } },
          error: null,
        }),
      },
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
      rpc,
    });

    const response = await GET(new NextRequest("https://app.example.com/auth/callback?code=callback-code"));

    expect(response.headers.get("location")).toBe("https://app.example.com/workspace");
    expect(rpc).not.toHaveBeenCalled();
  });

  it("keeps an existing suspended membership access pending without bootstrapping", async () => {
    const allMemberships = {
      data: [{ id: "membership-suspended", status: "suspended" }],
      error: null,
    };
    const byUser = vi.fn().mockResolvedValue(allMemberships);
    const rpc = vi.fn().mockResolvedValue({ data: [{ organization_id: "organization-a" }], error: null });
    mocks.createRouteClient.mockReturnValue({
      auth: {
        exchangeCodeForSession: vi.fn().mockResolvedValue({ error: null }),
        getUser: vi.fn().mockResolvedValue({
          data: { user: { id: "user", email_confirmed_at: "2026-08-10T10:00:00.000Z" } },
          error: null,
        }),
      },
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
      rpc,
    });

    const response = await GET(new NextRequest("https://app.example.com/auth/callback?code=callback-code"));

    expect(response.headers.get("location")).toBe("https://app.example.com/access-pending");
    expect(rpc).not.toHaveBeenCalled();
  });

  it("preserves the loopback request origin during local development", async () => {
    vi.stubEnv("NODE_ENV", "development");
    vi.stubEnv("VOYA_APP_URL", "");

    const request = new NextRequest("http://127.0.0.1:3000/auth/callback");
    Object.defineProperty(request, "url", { value: "http://127.0.0.1:3000/auth/callback" });
    const response = await GET(request);

    expect(response.headers.get("location")).toBe("http://127.0.0.1:3000/sign-in?error=link_session");
  });

  it("logs safe metadata and uses a fixed pending path when production origin configuration fails", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("VOYA_APP_URL", "https://operator:secret@app.voya.example");
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await GET(new NextRequest("http://internal:3000/auth/callback?code=code-secret"));

    expect(response.headers.get("location")).toBe("/sign-in?error=link_session");
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

    expect(response.headers.get("location")).toBe("https://app.example.com/sign-in?error=link_session");
    expect(write).toHaveBeenCalledWith(expect.stringContaining('"operation":"auth.callback.exchange"'));
    expect(write.mock.calls.flat().join(" ")).not.toContain("secret");
    expect(write.mock.calls.flat().join(" ")).not.toContain("customer@example.com");
  });

  it("returns access pending when the exchanged session has no user", async () => {
    mocks.createRouteClient.mockReturnValue({
      auth: {
        exchangeCodeForSession: vi.fn().mockResolvedValue({ error: null }),
        getUser: vi.fn().mockResolvedValue({ data: { user: null }, error: null }),
      },
    });

    const response = await GET(new NextRequest("https://app.example.com/auth/callback?code=callback-code"));

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://app.example.com/access-pending");
  });

  it("bootstraps a verified user with no active membership before opening workspace", async () => {
    const byUser = vi.fn().mockResolvedValue({ data: [], error: null });
    const rpc = vi.fn().mockResolvedValue({ data: [{ organization_id: "organization-a" }], error: null });
    mocks.createRouteClient.mockReturnValue({
      auth: {
        exchangeCodeForSession: vi.fn().mockResolvedValue({ error: null }),
        getUser: vi.fn().mockResolvedValue({
          data: { user: { id: "user", email_confirmed_at: "2026-08-10T10:00:00.000Z" } },
          error: null,
        }),
      },
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
      rpc,
    });

    const response = await GET(new NextRequest("https://app.example.com/auth/callback?code=callback-code"));

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe("https://app.example.com/workspace");
    expect(rpc).toHaveBeenCalledWith("bootstrap_personal_workspace", {
      p_request_id: expect.stringMatching(/^[0-9a-f-]{36}$/u),
    });
  });

  it("does not bootstrap a user whose email is not confirmed", async () => {
    const byUser = vi.fn().mockResolvedValue({ data: [], error: null });
    const rpc = vi.fn().mockResolvedValue({ data: [{ organization_id: "organization-a" }], error: null });
    mocks.createRouteClient.mockReturnValue({
      auth: {
        exchangeCodeForSession: vi.fn().mockResolvedValue({ error: null }),
        getUser: vi.fn().mockResolvedValue({
          data: { user: { id: "user", email_confirmed_at: null } },
          error: null,
        }),
      },
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
      rpc,
    });

    const response = await GET(new NextRequest("https://app.example.com/auth/callback?code=callback-code"));

    expect(response.headers.get("location")).toBe("https://app.example.com/access-pending");
    expect(rpc).not.toHaveBeenCalled();
  });

  it("fails closed when the membership lookup does not prove there are zero memberships", async () => {
    const byUser = vi.fn().mockResolvedValue({ data: null, error: null });
    const rpc = vi.fn();
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);
    mocks.createRouteClient.mockReturnValue({
      auth: {
        exchangeCodeForSession: vi.fn().mockResolvedValue({ error: null }),
        getUser: vi.fn().mockResolvedValue({
          data: { user: { id: "user", email_confirmed_at: "2026-08-10T10:00:00.000Z" } },
          error: null,
        }),
      },
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
      rpc,
    });

    const response = await GET(new NextRequest("https://app.example.com/auth/callback?code=callback-code"));

    expect(response.headers.get("location")).toBe("https://app.example.com/access-pending");
    expect(rpc).not.toHaveBeenCalled();
    expect(write).not.toHaveBeenCalled();
  });

  it("fails closed when self-service workspace bootstrap is unavailable", async () => {
    const byUser = vi.fn().mockResolvedValue({ data: [], error: null });
    mocks.createRouteClient.mockReturnValue({
      auth: {
        exchangeCodeForSession: vi.fn().mockResolvedValue({ error: null }),
        getUser: vi.fn().mockResolvedValue({
          data: { user: { id: "user", email_confirmed_at: "2026-08-10T10:00:00.000Z" } },
          error: null,
        }),
      },
      from: vi.fn().mockReturnValue({ select: vi.fn().mockReturnValue({ eq: byUser }) }),
      rpc: vi.fn().mockResolvedValue({ data: null, error: new Error("database secret") }),
    });
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await GET(new NextRequest("https://app.example.com/auth/callback?code=callback-code"));

    expect(response.headers.get("location")).toBe("https://app.example.com/access-pending");
    expect(write).toHaveBeenCalledWith(expect.stringContaining('"operation":"auth.callback.bootstrap"'));
    expect(write.mock.calls.flat().join(" ")).not.toContain("database secret");
  });

  it("logs a sanitized Supabase configuration failure from route-client construction", async () => {
    const configurationError = new SupabaseConfigurationError("Supabase project URL is invalid.");
    mocks.createRouteClient.mockImplementation(() => {
      throw configurationError;
    });
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await GET(new NextRequest("https://app.example.com/auth/callback?code=callback-code"));

    expect(response.headers.get("location")).toBe("https://app.example.com/access-pending");
    expect(write).toHaveBeenCalledWith(expect.stringContaining('"operation":"auth.callback.client"'));
    expect(write.mock.calls.flat().join(" ")).not.toContain("callback-code");
  });

  it.each([
    ["user", "auth.callback.user", () => ({
      auth: {
        exchangeCodeForSession: vi.fn().mockResolvedValue({ error: null }),
        getUser: vi.fn().mockResolvedValue({ data: { user: null }, error: new Error("token=secret") }),
      },
    })],
    ["memberships", "auth.callback.memberships", () => {
      const byUser = vi.fn().mockResolvedValue({ data: null, error: new Error("customer@example.com") });
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
