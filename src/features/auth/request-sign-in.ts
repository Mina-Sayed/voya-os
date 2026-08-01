export type MagicLinkGateway = Readonly<{
  requestMagicLink(input: Readonly<{ email: string; redirectTo: string }>): Promise<void>;
}>;

export type SignInRequest = Readonly<{
  email: string;
  redirectTo: string;
  gateway: MagicLinkGateway;
}>;

export type SignInRequestResult = Readonly<{ status: "sent" | "invalid_email" | "rate_limited" | "retry" }>;

const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/u;

function isRateLimited(error: unknown): boolean {
  return typeof error === "object"
    && error !== null
    && "status" in error
    && error.status === 429;
}

export async function requestSignIn({ email, redirectTo, gateway }: SignInRequest): Promise<SignInRequestResult> {
  const normalizedEmail = email.trim().toLowerCase();
  if (!emailPattern.test(normalizedEmail)) {
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
