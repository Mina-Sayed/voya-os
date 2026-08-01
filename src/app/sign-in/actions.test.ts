import { afterEach, describe, expect, it, vi } from "vitest";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";

const mocks = vi.hoisted(() => ({
  createPasswordGateway: vi.fn(),
  createMagicGateway: vi.fn(),
}));

vi.mock("@/lib/supabase/server-auth", () => ({
  createServerPasswordGateway: mocks.createPasswordGateway,
  createServerMagicLinkGateway: mocks.createMagicGateway,
}));

import { requestSignInAction, signInWithPasswordAction } from "./actions";

afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("signInWithPasswordAction", () => {
  it("returns the safe success result from the server-owned gateway", async () => {
    const signInWithPassword = vi.fn().mockResolvedValue(undefined);
    mocks.createPasswordGateway.mockResolvedValue({ signInWithPassword });

    await expect(signInWithPasswordAction(" MINA@example.com ", "secret-password"))
      .resolves.toEqual({ status: "signed_in" });
    expect(signInWithPassword).toHaveBeenCalledWith({ email: "mina@example.com", password: "secret-password" });
  });

  it("maps configuration failures to unavailable without exposing the cause", async () => {
    mocks.createPasswordGateway.mockRejectedValue(new SupabaseConfigurationError());

    await expect(signInWithPasswordAction("mina@example.com", "secret-password"))
      .resolves.toEqual({ status: "unavailable" });
  });

  it("maps unexpected provider failures to retry", async () => {
    mocks.createPasswordGateway.mockRejectedValue(new Error("provider token=secret"));

    await expect(signInWithPasswordAction("mina@example.com", "secret-password"))
      .resolves.toEqual({ status: "retry" });
  });
});

describe("requestSignInAction", () => {
  it("derives the trusted callback and normalizes the submitted email", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");
    const requestMagicLink = vi.fn().mockResolvedValue(undefined);
    mocks.createMagicGateway.mockResolvedValue({ requestMagicLink });

    await expect(requestSignInAction(" Operator@Voya.example "))
      .resolves.toEqual({ status: "sent" });
    expect(requestMagicLink).toHaveBeenCalledWith({
      email: "operator@voya.example",
      redirectTo: "https://app.voya.example/auth/callback",
    });
  });

  it("maps the provider email rate limit to a safe UI result", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");
    mocks.createMagicGateway.mockResolvedValue({
      requestMagicLink: vi.fn().mockRejectedValue({ status: 429, code: "over_email_send_rate_limit" }),
    });

    await expect(requestSignInAction("operator@voya.example"))
      .resolves.toEqual({ status: "rate_limited" });
  });

  it("does not call the provider for an invalid email", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");
    const requestMagicLink = vi.fn();
    mocks.createMagicGateway.mockResolvedValue({ requestMagicLink });

    await expect(requestSignInAction("not-an-email"))
      .resolves.toEqual({ status: "invalid_email" });
    expect(requestMagicLink).not.toHaveBeenCalled();
  });

  it("returns unavailable when public Supabase configuration is missing", async () => {
    mocks.createMagicGateway.mockRejectedValue(new SupabaseConfigurationError());

    await expect(requestSignInAction("operator@voya.example"))
      .resolves.toEqual({ status: "unavailable" });
  });

  it("keeps unexpected provider failures generic", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");
    mocks.createMagicGateway.mockResolvedValue({
      requestMagicLink: vi.fn().mockRejectedValue(new Error("provider token=secret")),
    });

    await expect(requestSignInAction("operator@voya.example"))
      .resolves.toEqual({ status: "retry" });
  });
});
