export type MfaRequirement = "enrollment" | "challenge";

export type MfaAssuranceInput = Readonly<{
  currentLevel: string | null | undefined;
  verifiedFactorCount: number;
}>;

export type MfaAssuranceResult =
  | Readonly<{ state: "satisfied" }>
  | Readonly<{ state: "required"; reason: MfaRequirement }>;

/**
 * Workspace access is AAL2-only. A verified factor without an AAL2 session
 * still requires a fresh challenge; an account without a verified factor must
 * enroll before it can reach tenant data.
 */
export function resolveMfaAssurance({
  currentLevel,
  verifiedFactorCount,
}: MfaAssuranceInput): MfaAssuranceResult {
  if (verifiedFactorCount < 1) return { state: "required", reason: "enrollment" };
  if (currentLevel !== "aal2") return { state: "required", reason: "challenge" };
  return { state: "satisfied" };
}
