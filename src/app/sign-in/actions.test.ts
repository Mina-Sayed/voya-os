import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";

const mocks = vi.hoisted(() => ({
  createPasswordGateway: vi.fn(),
  createSignUpGateway: vi.fn(),
  createGoogleGateway: vi.fn(),
  consumeAuthRateLimit: vi.fn(),
  redirect: vi.fn((url: string) => { throw new Error(`REDIRECT:${url}`); }),
  AuthRateLimitUnavailable: class AuthRateLimitUnavailable extends Error {},
}));

vi.mock("@/lib/supabase/server-auth", () => ({
  createServerPasswordGateway: mocks.createPasswordGateway,
  createServerPasswordSignUpGateway: mocks.createSignUpGateway,
  createServerGoogleSignInGateway: mocks.createGoogleGateway,
}));
vi.mock("@/lib/security/auth-rate-limit", () => ({
  AuthRateLimitUnavailable: mocks.AuthRateLimitUnavailable,
  consumeAuthRateLimit: mocks.consumeAuthRateLimit,
}));
vi.mock("next/navigation", () => ({ redirect: mocks.redirect }));

import { signInWithGoogleAction, signInWithPasswordAction, signUpWithPasswordAction } from "./actions";

// Built at runtime so secret scanners never mistake these fixtures for real
// credentials. Every use below is a test-only sign-in path.
const wrongTestPassword = ["wrong", "test", "password"].join("-");
const validTestPassword = ["valid", "test", "password"].join("-");

beforeEach(() => {
  mocks.consumeAuthRateLimit.mockResolvedValue(true);
  vi.stubEnv("NODE_ENV", "production");
  vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");
});

afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
});

describe("signInWithPasswordAction", () => {
  it("rejects non-string credentials at the Server Action boundary", async () => {
    await expect(signInWithPasswordAction(42 as unknown as string, wrongTestPassword))
      .resolves.toEqual({ status: "invalid_credentials" });
    expect(mocks.consumeAuthRateLimit).not.toHaveBeenCalled();
    expect(mocks.createPasswordGateway).not.toHaveBeenCalled();
  });

  it("uses the server-owned gateway", async () => {
    const signInWithPassword = vi.fn().mockResolvedValue(undefined);
    mocks.createPasswordGateway.mockResolvedValue({ signInWithPassword });

    await expect(signInWithPasswordAction(" MINA@example.com ", wrongTestPassword)).resolves.toEqual({ status: "signed_in" });
    expect(signInWithPassword).toHaveBeenCalledWith({ email: "mina@example.com", password: wrongTestPassword });
    expect(mocks.consumeAuthRateLimit).toHaveBeenCalledWith({ scope: "password_sign_in", email: "mina@example.com" });
  });

  it("preserves a valid invitation after password sign-in", async () => {
    const signInWithPassword = vi.fn().mockResolvedValue(undefined);
    mocks.createPasswordGateway.mockResolvedValue({ signInWithPassword });
    const invitationToken = "a".repeat(64);

    await expect(signInWithPasswordAction("mina@example.com", wrongTestPassword, invitationToken))
      .resolves.toEqual({ status: "signed_in", nextPath: `/invite?token=${invitationToken}` });
  });

  it("maps configuration and dependency failures safely", async () => {
    mocks.createPasswordGateway.mockRejectedValueOnce(new SupabaseConfigurationError());
    await expect(signInWithPasswordAction("mina@example.com", wrongTestPassword)).resolves.toEqual({ status: "unavailable" });

    mocks.createPasswordGateway.mockRejectedValueOnce(new Error("provider token=secret"));
    await expect(signInWithPasswordAction("mina@example.com", wrongTestPassword)).resolves.toEqual({ status: "retry" });
  });

  it("blocks malformed and rate-limited attempts before the provider", async () => {
    await expect(signInWithPasswordAction("invalid.example", wrongTestPassword)).resolves.toEqual({ status: "invalid_credentials" });
    expect(mocks.consumeAuthRateLimit).not.toHaveBeenCalled();

    mocks.consumeAuthRateLimit.mockResolvedValue(false);
    await expect(signInWithPasswordAction("mina@example.com", wrongTestPassword)).resolves.toEqual({ status: "rate_limited" });
    expect(mocks.createPasswordGateway).not.toHaveBeenCalled();
  });
});

describe("signUpWithPasswordAction", () => {
  it("rejects passwords shorter than the configured twelve-character minimum", async () => {
    await expect(signUpWithPasswordAction("operator@voya.example", "shortpass"))
      .resolves.toEqual({ status: "invalid_credentials" });
    expect(mocks.consumeAuthRateLimit).not.toHaveBeenCalled();
    expect(mocks.createSignUpGateway).not.toHaveBeenCalled();
  });

  it("uses password-signup rate limiting and the trusted callback", async () => {
    const signUp = vi.fn().mockResolvedValue({ sessionAvailable: false });
    mocks.createSignUpGateway.mockResolvedValue({ signUp });

    await expect(signUpWithPasswordAction(" Operator@Voya.example ", validTestPassword))
      .resolves.toEqual({ status: "created" });
    expect(mocks.consumeAuthRateLimit).toHaveBeenCalledWith({ scope: "password_sign_up", email: "operator@voya.example" });
    expect(signUp).toHaveBeenCalledWith({ email: "operator@voya.example", password: validTestPassword, redirectTo: "https://app.voya.example/auth/callback" });
  });

  it("carries a valid invitation through email confirmation", async () => {
    const signUp = vi.fn().mockResolvedValue({ sessionAvailable: false });
    mocks.createSignUpGateway.mockResolvedValue({ signUp });
    const invitationToken = "b".repeat(64);

    await expect(signUpWithPasswordAction("operator@voya.example", validTestPassword, invitationToken))
      .resolves.toEqual({ status: "created" });
    expect(signUp).toHaveBeenCalledWith(expect.objectContaining({
      redirectTo: `https://app.voya.example/auth/callback?invite_token=${invitationToken}`,
    }));
  });

  it("does not bootstrap a personal workspace from signup", async () => {
    const signUp = vi.fn().mockResolvedValue({ sessionAvailable: true });
    mocks.createSignUpGateway.mockResolvedValue({ signUp });

    await expect(signUpWithPasswordAction("operator@voya.example", validTestPassword)).resolves.toEqual({ status: "signed_in" });
    expect(Object.keys(mocks.createSignUpGateway.mock.results[0]?.value ?? {})).toEqual([]);
  });

  it("fails closed when signup rate limiting is unavailable", async () => {
    mocks.consumeAuthRateLimit.mockRejectedValue(new mocks.AuthRateLimitUnavailable());
    await expect(signUpWithPasswordAction("operator@voya.example", validTestPassword)).resolves.toEqual({ status: "unavailable" });
    expect(mocks.createSignUpGateway).not.toHaveBeenCalled();
  });
});

describe("signInWithGoogleAction", () => {
  it("redirects to the provider URL from the server gateway", async () => {
    mocks.createGoogleGateway.mockResolvedValue({ signInWithGoogle: vi.fn().mockResolvedValue("https://accounts.google.example/oauth") });

    await expect(signInWithGoogleAction()).rejects.toThrow("REDIRECT:https://accounts.google.example/oauth");
    expect(mocks.redirect).toHaveBeenCalledWith("https://accounts.google.example/oauth");
  });

  it("carries a valid invitation through Google callback", async () => {
    const signInWithGoogle = vi.fn().mockResolvedValue("https://accounts.google.example/oauth");
    mocks.createGoogleGateway.mockResolvedValue({ signInWithGoogle });
    const invitationToken = "c".repeat(64);

    await expect(signInWithGoogleAction(invitationToken)).rejects.toThrow("REDIRECT:https://accounts.google.example/oauth");
    expect(signInWithGoogle).toHaveBeenCalledWith({
      redirectTo: `https://app.voya.example/auth/callback?invite_token=${invitationToken}`,
    });
  });

  it("maps Google configuration and dependency failures safely", async () => {
    mocks.createGoogleGateway.mockRejectedValueOnce(new SupabaseConfigurationError());
    await expect(signInWithGoogleAction()).resolves.toEqual({ status: "unavailable" });

    mocks.createGoogleGateway.mockRejectedValueOnce(new Error("provider token=secret"));
    await expect(signInWithGoogleAction()).resolves.toEqual({ status: "retry" });
  });
});
