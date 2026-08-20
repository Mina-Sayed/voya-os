import { isValidEmailAddress, normalizeEmailAddress } from "./email-address";

export type PasswordSignUpGateway = Readonly<{
  signUp(input: Readonly<{ email: string; password: string; redirectTo: string }>): Promise<Readonly<{ sessionAvailable: boolean }>>;
}>;

export type PasswordSignUpResult = Readonly<{
  status: "created" | "signed_in" | "invalid_credentials" | "rate_limited" | "retry";
  nextPath?: string;
}>;

type PasswordSignUpRequest = Readonly<{
  email: string;
  password: string;
  redirectTo: string;
  gateway: PasswordSignUpGateway;
}>;

function errorStatus(error: unknown): number | null {
  if (typeof error !== "object" || error === null || !("status" in error)) return null;
  const status = error.status;
  return typeof status === "number" ? status : null;
}

export async function requestPasswordSignUp({ email, password, redirectTo, gateway }: PasswordSignUpRequest): Promise<PasswordSignUpResult> {
  const normalizedEmail = normalizeEmailAddress(email);
  if (!isValidEmailAddress(normalizedEmail) || password.length < 8) return { status: "invalid_credentials" };

  try {
    const result = await gateway.signUp({ email: normalizedEmail, password, redirectTo });
    return result.sessionAvailable ? { status: "signed_in" } : { status: "created" };
  } catch (error) {
    const status = errorStatus(error);
    if (status === 400) return { status: "invalid_credentials" };
    if (status === 429) return { status: "rate_limited" };
    return { status: "retry" };
  }
}
