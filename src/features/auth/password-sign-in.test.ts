import { describe, expect, test } from "vitest";
import { requestPasswordSignIn } from "./password-sign-in";

describe("requestPasswordSignIn", () => {
  test("normalizes email and forwards credentials without returning secrets", async () => {
    const calls: Array<{ email: string; password: string }> = [];
    const result = await requestPasswordSignIn({
      email: "  MINA@example.com ",
      password: "correct horse battery staple",
      gateway: { signInWithPassword: async (input) => { calls.push(input); } },
    });

    expect(result).toEqual({ status: "signed_in" });
    expect(calls).toEqual([{ email: "mina@example.com", password: "correct horse battery staple" }]);
    expect(JSON.stringify(result)).not.toContain("correct horse");
  });

  test("maps invalid credentials and rate limits to safe statuses", async () => {
    const invalid = await requestPasswordSignIn({
      email: "mina@example.com",
      password: "wrong",
      gateway: { signInWithPassword: async () => { throw Object.assign(new Error("bad"), { status: 400 }); } },
    });
    const limited = await requestPasswordSignIn({
      email: "mina@example.com",
      password: "wrong",
      gateway: { signInWithPassword: async () => { throw Object.assign(new Error("slow"), { status: 429 }); } },
    });

    expect(invalid).toEqual({ status: "invalid_credentials" });
    expect(limited).toEqual({ status: "rate_limited" });
  });

  test("maps provider errors without a numeric status to a retryable result", async () => {
    const result = await requestPasswordSignIn({
      email: "mina@example.com",
      password: "wrong",
      gateway: { signInWithPassword: async () => { throw { status: "429", message: "provider detail" }; } },
    });

    expect(result).toEqual({ status: "retry" });
    expect(JSON.stringify(result)).not.toContain("provider detail");
  });

  test("rejects incomplete credentials before calling the gateway", async () => {
    let called = false;
    const result = await requestPasswordSignIn({
      email: "not-an-email",
      password: "",
      gateway: { signInWithPassword: async () => { called = true; } },
    });

    expect(result).toEqual({ status: "invalid_credentials" });
    expect(called).toBe(false);
  });
});
