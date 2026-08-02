export type MagicLinkGateway = Readonly<{
  requestMagicLink(input: Readonly<{ email: string; redirectTo: string }>): Promise<void>;
}>;

export type SignInRequest = Readonly<{
  email: string;
  redirectTo: string;
  gateway: MagicLinkGateway;
}>;

export type SignInRequestResult = Readonly<{ status: "sent" | "invalid_email" | "rate_limited" | "retry" }>;

import { isValidEmailAddress, normalizeEmailAddress } from "./email-address";

function isRateLimited(error: unknown): boolean {
  if (typeof error !== "object" || error === null) return false;
  const candidate = error as Readonly<{ status?: unknown; code?: unknown }>;
  return candidate.status === 429 || candidate.code === "over_email_send_rate_limit";
}

export async function requestSignIn({ email, redirectTo, gateway }: SignInRequest): Promise<SignInRequestResult> {
  const normalizedEmail = normalizeEmailAddress(email);
  if (!isValidEmailAddress(normalizedEmail)) {
    return { status: "invalid_email" };
  }

  try {
    await gateway.requestMagicLink({ email: normalizedEmail, redirectTo });
    return { status: "sent" };
  } catch (error) {
    if (isRateLimited(error)) return { status: "rate_limited" };
    return { status: "retry" };
  }
}
