import { afterEach, describe, expect, it, vi } from "vitest";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { internalApplicationUrl, resolveApplicationOrigin } from "./application-origin";

const signInMocks = vi.hoisted(() => ({
  createGateway: vi.fn(),
}));

vi.mock("@/lib/supabase/server-auth", () => ({
  createServerMagicLinkGateway: signInMocks.createGateway,
}));

import { requestSignInAction } from "@/app/sign-in/actions";

afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("resolveApplicationOrigin", () => {
  it("uses the configured HTTPS root origin in production", () => {
    expect(resolveApplicationOrigin({
      environment: { NODE_ENV: "production", VOYA_APP_URL: "https://app.voya.example" },
      requestUrl: "http://internal:3000/auth/callback",
    }).origin).toBe("https://app.voya.example");
  });

  it.each([
    ["HTTP", "http://app.voya.example"],
    ["credentials", "https://operator:password@app.voya.example"],
    ["fragment", "https://app.voya.example/#fragment"],
    ["query", "https://app.voya.example/?next=/workspace"],
    ["non-root pathname", "https://app.voya.example/application"],
  ])("rejects a production app URL with %s", (_reason, VOYA_APP_URL) => {
    expect(() => resolveApplicationOrigin({
      environment: { NODE_ENV: "production", VOYA_APP_URL },
      requestUrl: "http://internal:3000/auth/callback",
    })).toThrow(SupabaseConfigurationError);
  });

  it("uses the local request origin outside production when no app URL is configured", () => {
    expect(resolveApplicationOrigin({
      environment: { NODE_ENV: "development" },
      requestUrl: "http://127.0.0.1:3000/auth/callback?code=ignored",
    }).origin).toBe("http://127.0.0.1:3000");
  });

  it.each([
    ["missing", undefined],
    ["invalid", "not a URL"],
  ])("rejects %s production configuration", (_reason, VOYA_APP_URL) => {
    expect(() => resolveApplicationOrigin({
      environment: { NODE_ENV: "production", VOYA_APP_URL },
      requestUrl: "http://internal:3000/auth/callback",
    })).toThrow(SupabaseConfigurationError);
  });
});

describe("internalApplicationUrl", () => {
  it("builds an approved fixed internal path", () => {
    expect(internalApplicationUrl(new URL("https://app.voya.example"), "/auth/callback").toString())
      .toBe("https://app.voya.example/auth/callback");
  });
});

describe("requestSignInAction", () => {
  it("uses the configured production origin for its fixed callback path", async () => {
    const gateway = { requestMagicLink: vi.fn().mockResolvedValue(undefined) };
    signInMocks.createGateway.mockResolvedValue(gateway);
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");

    await expect(requestSignInAction("operator@voya.example")).resolves.toEqual({ status: "sent" });

    expect(gateway.requestMagicLink).toHaveBeenCalledWith({
      email: "operator@voya.example",
      redirectTo: "https://app.voya.example/auth/callback",
    });
  });

  it("fails closed when a development action has no configured origin", async () => {
    signInMocks.createGateway.mockResolvedValue({ requestMagicLink: vi.fn() });
    vi.stubEnv("NODE_ENV", "development");
    vi.stubEnv("VOYA_APP_URL", "");

    await expect(requestSignInAction("operator@voya.example")).resolves.toEqual({ status: "unavailable" });
  });
});
