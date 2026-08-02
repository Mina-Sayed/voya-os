import { describe, expect, it, vi } from "vitest";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";

const mocks = vi.hoisted(() => ({
  createServerSupabaseClient: vi.fn(),
}));

vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: mocks.createServerSupabaseClient,
}));

import { AuthRateLimitUnavailable, consumeAuthRateLimit, hashAuthRateLimitKey } from "./auth-rate-limit";

describe("auth rate limit adapter", () => {
  it("hashes scope and normalized email without retaining the raw address", () => {
    const first = hashAuthRateLimitKey("magic_link", " Operator@Example.com ");
    const second = hashAuthRateLimitKey("magic_link", "operator@example.com");

    expect(first).toMatch(/^[0-9a-f]{64}$/);
    expect(first).toBe(second);
    expect(first).not.toContain("operator");
  });

  it("calls the narrow RPC with the bounded magic-link policy", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: true, error: null });
    mocks.createServerSupabaseClient.mockResolvedValue({ rpc });

    await expect(consumeAuthRateLimit({ scope: "magic_link", email: "operator@example.com" })).resolves.toBe(true);
    expect(rpc).toHaveBeenCalledWith("consume_auth_rate_limit", expect.objectContaining({
      p_scope: "magic_link",
      p_limit: 5,
      p_window_seconds: 900,
      p_key_hash: expect.stringMatching(/^[0-9a-f]{64}$/),
    }));
  });

  it("fails closed when the RPC is unavailable or malformed", async () => {
    mocks.createServerSupabaseClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ data: null, error: { code: "PGRST" } }) });

    await expect(consumeAuthRateLimit({ scope: "password_sign_in", email: "operator@example.com" }))
      .rejects.toBeInstanceOf(AuthRateLimitUnavailable);
  });

  it("preserves a missing public configuration failure for the action boundary", async () => {
    mocks.createServerSupabaseClient.mockRejectedValue(new SupabaseConfigurationError());

    await expect(consumeAuthRateLimit({ scope: "password_sign_in", email: "operator@example.com" }))
      .rejects.toBeInstanceOf(SupabaseConfigurationError);
  });

  it("maps an unexpected client failure to the safe unavailable error", async () => {
    mocks.createServerSupabaseClient.mockRejectedValue(new Error("provider detail"));

    await expect(consumeAuthRateLimit({ scope: "password_sign_in", email: "operator@example.com" }))
      .rejects.toBeInstanceOf(AuthRateLimitUnavailable);
  });
});
