import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";

const mocks = vi.hoisted(() => ({
  createServiceRoleSupabaseClient: vi.fn(),
}));

vi.mock("@/lib/supabase/server-auth", () => ({
  createServiceRoleSupabaseClient: mocks.createServiceRoleSupabaseClient,
}));

import { AuthRateLimitUnavailable, consumeAuthRateLimit, hashAuthRateLimitKey } from "./auth-rate-limit";

const testSecret = "auth-rate-limit-test-secret-32-bytes";

describe("auth rate limit adapter", () => {
  beforeEach(() => {
    vi.stubEnv("AUTH_RATE_LIMIT_HMAC_SECRET", testSecret);
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "test-service-role-key-for-rate-limit");
    vi.stubEnv("NODE_ENV", "production");
    vi.clearAllMocks();
  });

  afterEach(() => {
    vi.unstubAllEnvs();
  });

  it("derives the same 64-character digest for the same secret and canonical input", () => {
    const first = hashAuthRateLimitKey("password_sign_up", " Operator@Example.com ", testSecret);
    const second = hashAuthRateLimitKey("password_sign_up", "operator@example.com", testSecret);

    expect(first).toMatch(/^[0-9a-f]{64}$/);
    expect(first).toBe(second);
    expect(first).not.toContain("operator");
  });

  it("separates scopes, emails, and secrets", () => {
    const passwordSignUp = hashAuthRateLimitKey("password_sign_up", "operator@example.com", testSecret);
    const passwordSignIn = hashAuthRateLimitKey("password_sign_in", "operator@example.com", testSecret);
    const otherEmail = hashAuthRateLimitKey("password_sign_up", "other@example.com", testSecret);
    const otherSecret = hashAuthRateLimitKey("password_sign_up", "operator@example.com", "different-auth-rate-limit-secret");

    expect(passwordSignUp).not.toBe(passwordSignIn);
    expect(passwordSignUp).not.toBe(otherEmail);
    expect(passwordSignUp).not.toBe(otherSecret);
  });

  it("does not accept the public SHA-256 formula as the trusted bucket key", () => {
    const canonicalInput = "voya-auth-rate-limit:v2\u001fpassword_sign_up\u001foperator@example.com";
    const publicDigest = createHash("sha256").update(canonicalInput, "utf8").digest("hex");
    const legacyPublicDigest = createHash("sha256")
      .update("voya-auth-rate-limit:v1:password_sign_up:operator@example.com", "utf8")
      .digest("hex");
    const trustedDigest = hashAuthRateLimitKey("password_sign_up", "operator@example.com", testSecret);

    expect(trustedDigest).not.toBe(publicDigest);
    expect(trustedDigest).not.toBe(legacyPublicDigest);
  });

  it("calls the narrow RPC without caller-controlled policy parameters", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: true, error: null });
    mocks.createServiceRoleSupabaseClient.mockReturnValue({ rpc });

    await expect(consumeAuthRateLimit({ scope: "password_sign_up", email: "operator@example.com" })).resolves.toBe(true);
    expect(rpc).toHaveBeenCalledWith("consume_auth_rate_limit", {
      p_scope: "password_sign_up",
      p_key_hash: expect.stringMatching(/^[0-9a-f]{64}$/),
    });
  });

  it("fails closed when the RPC is unavailable or malformed", async () => {
    mocks.createServiceRoleSupabaseClient.mockReturnValue({ rpc: vi.fn().mockResolvedValue({ data: null, error: { code: "PGRST" } }) });

    await expect(consumeAuthRateLimit({ scope: "password_sign_in", email: "operator@example.com" }))
      .rejects.toBeInstanceOf(AuthRateLimitUnavailable);
  });

  it("fails closed before creating a client when the server secret is missing", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("AUTH_RATE_LIMIT_HMAC_SECRET", "");

    await expect(consumeAuthRateLimit({ scope: "password_sign_in", email: "operator@example.com" }))
      .rejects.toBeInstanceOf(AuthRateLimitUnavailable);
    expect(mocks.createServiceRoleSupabaseClient).not.toHaveBeenCalled();
  });

  it("never includes the HMAC secret in an unavailable error", async () => {
    mocks.createServiceRoleSupabaseClient.mockImplementation(() => { throw new Error(`provider detail ${testSecret}`); });

    const error = await consumeAuthRateLimit({ scope: "password_sign_in", email: "operator@example.com" })
      .catch((value: unknown) => value);

    expect(error).toBeInstanceOf(AuthRateLimitUnavailable);
    expect(String(error)).not.toContain(testSecret);
  });

  it("preserves a missing public configuration failure for the action boundary", async () => {
    mocks.createServiceRoleSupabaseClient.mockImplementation(() => { throw new SupabaseConfigurationError(); });

    await expect(consumeAuthRateLimit({ scope: "password_sign_in", email: "operator@example.com" }))
      .rejects.toBeInstanceOf(SupabaseConfigurationError);
  });

  it("maps an unexpected client failure to the safe unavailable error", async () => {
    mocks.createServiceRoleSupabaseClient.mockImplementation(() => { throw new Error("provider detail"); });

    await expect(consumeAuthRateLimit({ scope: "password_sign_in", email: "operator@example.com" }))
      .rejects.toBeInstanceOf(AuthRateLimitUnavailable);
  });
});
