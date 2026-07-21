import { describe, expect, it, vi } from "vitest";
import { requestSignIn } from "./request-sign-in";

describe("requestSignIn", () => {
  it("normalizes a valid email and sends a magic link to the trusted redirect", async () => {
    const gateway = { requestMagicLink: vi.fn().mockResolvedValue(undefined) };

    await expect(requestSignIn({
      email: "  Operator@Voya.example ",
      redirectTo: "https://app.voya.example/auth/callback",
      gateway,
    })).resolves.toEqual({ status: "sent" });

    expect(gateway.requestMagicLink).toHaveBeenCalledWith({
      email: "operator@voya.example",
      redirectTo: "https://app.voya.example/auth/callback",
    });
  });

  it("does not call Supabase for an invalid email", async () => {
    const gateway = { requestMagicLink: vi.fn() };

    await expect(requestSignIn({ email: "not-an-email", redirectTo: "https://app.voya.example/auth/callback", gateway }))
      .resolves.toEqual({ status: "invalid_email" });
    expect(gateway.requestMagicLink).not.toHaveBeenCalled();
  });

  it("returns generic retry feedback when the provider fails", async () => {
    const gateway = { requestMagicLink: vi.fn().mockRejectedValue(new Error("provider failure")) };

    await expect(requestSignIn({ email: "operator@voya.example", redirectTo: "https://app.voya.example/auth/callback", gateway }))
      .resolves.toEqual({ status: "retry" });
  });
});
