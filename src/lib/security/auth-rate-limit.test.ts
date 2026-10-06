import { createHash } from "node:crypto";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";

const mocks = vi.hoisted(() => ({
  createServiceRoleSupabaseClient: vi.fn(),
  headers: vi.fn(),
}));

vi.mock("@/lib/supabase/server-auth", () => ({
  createServiceRoleSupabaseClient: mocks.createServiceRoleSupabaseClient,
}));
vi.mock("next/headers", () => ({ headers: mocks.headers }));

import { AuthRateLimitUnavailable, consumeAuthRateLimit, getAuthRateLimitSource, hashAuthRateLimitKey, hashAuthRateLimitSourceKey } from "./auth-rate-limit";

const testSecret = "auth-rate-limit-test-secret-32-bytes";

describe("auth rate limit adapter", () => {
  beforeEach(() => {
    vi.stubEnv("AUTH_RATE_LIMIT_HMAC_SECRET", testSecret);
    vi.clearAllMocks();
    mocks.headers.mockResolvedValue(new Headers({ "x-vercel-forwarded-for": "203.0.113.10" }));
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

  it("binds account buckets to the request source and collapses attacker-controlled email cardinality per source", () => {
    const firstEmail = hashAuthRateLimitKey("password_sign_in", "victim@example.com", testSecret, "203.0.113.10");
    const otherSourceAccount = hashAuthRateLimitKey("password_sign_in", "victim@example.com", testSecret, "203.0.113.11");
    const firstSource = hashAuthRateLimitSourceKey("password_sign_in", "203.0.113.10", testSecret);
    const sameSource = hashAuthRateLimitSourceKey("password_sign_in", "203.0.113.10", testSecret);
    const otherSource = hashAuthRateLimitSourceKey("password_sign_in", "203.0.113.11", testSecret);

    expect(firstEmail).not.toBe(otherSourceAccount);
    expect(firstSource).toBe(sameSource);
    expect(firstSource).not.toBe(otherSource);
  });

  it("uses Vercel's platform-overwritten client IP before other forwarding headers", () => {
    vi.stubEnv("NODE_ENV", "production");
    expect(getAuthRateLimitSource(new Headers({
      "x-vercel-forwarded-for": "203.0.113.10",
      "x-real-ip": "198.51.100.99",
      "x-forwarded-for": "192.0.2.88",
    }))).toBe("203.0.113.10");
    expect(getAuthRateLimitSource(new Headers({
      "x-real-ip": "198.51.100.99",
      "x-forwarded-for": "192.0.2.88",
    }))).toBeNull();
    expect(getAuthRateLimitSource(new Headers({ "x-vercel-forwarded-for": "not-an-ip" }))).toBeNull();
  });

  it("uses only an explicitly configured single-IP header for another trusted proxy", () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("AUTH_RATE_LIMIT_TRUSTED_PROXY_CLIENT_IP_HEADER", "x-edge-client-ip");

    expect(getAuthRateLimitSource(new Headers({
      "x-edge-client-ip": "203.0.113.20",
      "x-vercel-forwarded-for": "192.0.2.99",
    }))).toBe("203.0.113.20");
    expect(getAuthRateLimitSource(new Headers({ "x-edge-client-ip": "203.0.113.20, 198.51.100.9" }))).toBeNull();
    expect(getAuthRateLimitSource(new Headers({ "x-vercel-forwarded-for": "192.0.2.99" }))).toBeNull();
  });

  it("uses one stable local bucket when no edge proxy exists outside production", () => {
    vi.stubEnv("NODE_ENV", "development");

    expect(getAuthRateLimitSource(new Headers())).toBe("local-development");
  });

  it("does not accept the public SHA-256 formula as the trusted bucket key", () => {
    const canonicalInput = "voya-auth-rate-limit:v3\u001fpassword_sign_up\u001f203.0.113.10\u001foperator@example.com";
    const publicDigest = createHash("sha256").update(canonicalInput, "utf8").digest("hex");
    const legacyPublicDigest = createHash("sha256")
      .update("voya-auth-rate-limit:v2\u001fpassword_sign_up\u001foperator@example.com", "utf8")
      .digest("hex");
    const trustedDigest = hashAuthRateLimitKey("password_sign_up", "operator@example.com", testSecret);

    expect(trustedDigest).not.toBe(publicDigest);
    expect(trustedDigest).not.toBe(legacyPublicDigest);
  });

  it("calls the narrow RPC without caller-controlled policy parameters", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: true, error: null });
    mocks.createServiceRoleSupabaseClient.mockReturnValue({ rpc });

    await expect(consumeAuthRateLimit({ scope: "password_sign_up", email: "operator@example.com" })).resolves.toBe(true);
    expect(rpc).toHaveBeenNthCalledWith(1, "consume_auth_rate_limit", {
      p_scope: "password_sign_up",
      p_key_hash: expect.stringMatching(/^[0-9a-f]{64}$/),
    });
    expect(rpc).toHaveBeenNthCalledWith(2, "consume_auth_rate_limit", {
      p_scope: "password_sign_up",
      p_key_hash: expect.stringMatching(/^[0-9a-f]{64}$/),
    });
  });

  it("does not allocate an account bucket when a source has exhausted its shared budget", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: false, error: null });
    mocks.createServiceRoleSupabaseClient.mockReturnValue({ rpc });

    await expect(consumeAuthRateLimit({ scope: "password_sign_in", email: "one-of-many@example.com" })).resolves.toBe(false);
    expect(rpc).toHaveBeenCalledTimes(1);
  });

  it("fails closed when the RPC is unavailable or malformed", async () => {
    mocks.createServiceRoleSupabaseClient.mockReturnValue({ rpc: vi.fn().mockResolvedValue({ data: null, error: { code: "PGRST" } }) });

    await expect(consumeAuthRateLimit({ scope: "password_sign_in", email: "operator@example.com" }))
      .rejects.toBeInstanceOf(AuthRateLimitUnavailable);
  });

  it("fails closed when the request has no trusted proxy source", async () => {
    vi.stubEnv("NODE_ENV", "production");
    mocks.headers.mockResolvedValue(new Headers({
      "x-real-ip": "198.51.100.99",
      "x-forwarded-for": "192.0.2.88",
    }));

    await expect(consumeAuthRateLimit({ scope: "password_sign_in", email: "operator@example.com" }))
      .rejects.toBeInstanceOf(AuthRateLimitUnavailable);
    expect(mocks.createServiceRoleSupabaseClient).not.toHaveBeenCalled();
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
