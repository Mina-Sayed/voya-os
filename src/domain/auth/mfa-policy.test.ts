import { describe, expect, test } from "vitest";
import { resolveMfaAssurance } from "./mfa-policy";

describe("workspace MFA policy", () => {
  test("requires enrollment when no verified factor exists", () => {
    expect(resolveMfaAssurance({ currentLevel: "aal1", verifiedFactorCount: 0 })).toEqual({
      state: "required",
      reason: "enrollment",
    });
  });

  test("requires a challenge for an existing factor in an AAL1 session", () => {
    expect(resolveMfaAssurance({ currentLevel: "aal1", verifiedFactorCount: 1 })).toEqual({
      state: "required",
      reason: "challenge",
    });
  });

  test("allows only an AAL2 session into the workspace", () => {
    expect(resolveMfaAssurance({ currentLevel: "aal2", verifiedFactorCount: 1 })).toEqual({
      state: "satisfied",
    });
    expect(resolveMfaAssurance({ currentLevel: null, verifiedFactorCount: 1 })).toEqual({
      state: "required",
      reason: "challenge",
    });
  });
});
