export type PasswordSignInGateway = Readonly<{
  signInWithPassword(input: Readonly<{ email: string; password: string }>): Promise<void>;
}>;

export type PasswordSignInResult = Readonly<{
  status: "signed_in" | "invalid_credentials" | "rate_limited" | "retry";
  nextPath?: string;
}>;

import { isValidEmailAddress, normalizeEmailAddress } from "./email-address";

type PasswordSignInRequest = Readonly<{
  email: string;
  password: string;
  gateway: PasswordSignInGateway;
}>;

function errorStatus(error: unknown): number | null {
  if (typeof error !== "object" || error === null || !("status" in error)) return null;
  const status = error.status;
  return typeof status === "number" ? status : null;
}

export async function requestPasswordSignIn({ email, password, gateway }: PasswordSignInRequest): Promise<PasswordSignInResult> {
  const normalizedEmail = normalizeEmailAddress(email);
  if (!isValidEmailAddress(normalizedEmail) || password.length === 0) {
    return { status: "invalid_credentials" };
  }

  try {
    await gateway.signInWithPassword({ email: normalizedEmail, password });
    return { status: "signed_in" };
  } catch (error) {
    const status = errorStatus(error);
    if (status === 400) return { status: "invalid_credentials" };
    if (status === 429) return { status: "rate_limited" };
    return { status: "retry" };
  }
}
