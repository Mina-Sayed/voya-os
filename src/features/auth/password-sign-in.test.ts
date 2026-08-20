import { describe, expect, it, vi } from "vitest";
import { requestPasswordSignIn } from "./password-sign-in";

describe("requestPasswordSignIn", () => {
  it("normalizes credentials and returns a successful sign-in", async () => {
    const gateway = { signIn: vi.fn().mockResolvedValue({ status: "signed_in" }) };

    await expect(requestPasswordSignIn({
      email: "  Operator@Voya.example ",
      password: "correct horse battery staple",
      gateway,
    })).resolves.toEqual({ status: "signed_in" });

    expect(gateway.signIn).toHaveBeenCalledWith({
      email: "operator@voya.example",
      password: "correct horse battery staple",
    });
  });

  it("rejects malformed credentials before calling the provider", async () => {
    const gateway = { signIn: vi.fn() };

    await expect(requestPasswordSignIn({ email: "invalid", password: "short", gateway }))
      .resolves.toEqual({ status: "invalid_credentials" });
    expect(gateway.signIn).not.toHaveBeenCalled();
  });

  it.each(["invalid_credentials", "rate_limited", "access_pending"] as const)(
    "preserves the safe %s provider outcome",
    async (status) => {
      const gateway = { signIn: vi.fn().mockResolvedValue({ status }) };

      await expect(requestPasswordSignIn({
        email: "operator@voya.example",
        password: "correct horse battery staple",
        gateway,
      })).resolves.toEqual({ status });
    },
  );

  it("returns generic retry feedback for an unexpected dependency failure", async () => {
    const gateway = { signIn: vi.fn().mockRejectedValue(new Error("provider secret")) };

    await expect(requestPasswordSignIn({
      email: "operator@voya.example",
      password: "correct horse battery staple",
      gateway,
    })).resolves.toEqual({ status: "retry" });
  });
});
