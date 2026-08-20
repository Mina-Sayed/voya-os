import { describe, expect, it, vi } from "vitest";
import { requestPasswordSignUp } from "./password-sign-up";

describe("requestPasswordSignUp", () => {
  it("normalizes email and returns created when confirmation is required", async () => {
    const signUp = vi.fn().mockResolvedValue({ sessionAvailable: false });
    await expect(requestPasswordSignUp({ email: " Operator@Example.com ", password: "safe-password", redirectTo: "https://app.example/auth/callback", gateway: { signUp } }))
      .resolves.toEqual({ status: "created" });
    expect(signUp).toHaveBeenCalledWith({ email: "operator@example.com", password: "safe-password", redirectTo: "https://app.example/auth/callback" });
  });

  it("does not call Supabase for malformed credentials", async () => {
    const signUp = vi.fn();
    await expect(requestPasswordSignUp({ email: "bad", password: "short", redirectTo: "https://app.example/auth/callback", gateway: { signUp } }))
      .resolves.toEqual({ status: "invalid_credentials" });
    expect(signUp).not.toHaveBeenCalled();
  });

  it("returns signed_in when the provider creates an active session", async () => {
    await expect(requestPasswordSignUp({
      email: "operator@example.com",
      password: "safe-password",
      redirectTo: "https://app.example/auth/callback",
      gateway: { signUp: vi.fn().mockResolvedValue({ sessionAvailable: true }) },
    })).resolves.toEqual({ status: "signed_in" });
  });

  it.each([
    [400, "invalid_credentials"],
    [429, "rate_limited"],
    [503, "retry"],
  ] as const)("maps provider status %s to a safe result", async (status, expectedStatus) => {
    const signUp = vi.fn().mockRejectedValue(Object.assign(new Error("provider detail"), { status }));
    await expect(requestPasswordSignUp({
      email: "operator@example.com",
      password: "safe-password",
      redirectTo: "https://app.example/auth/callback",
      gateway: { signUp },
    })).resolves.toEqual({ status: expectedStatus });
  });
});
