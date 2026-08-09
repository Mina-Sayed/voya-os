export type MagicLinkGateway = Readonly<{
  requestMagicLink(input: Readonly<{ email: string; redirectTo: string }>): Promise<"sent" | "rate_limited" | void>;
}>;

export type SignInRequest = Readonly<{
  email: string;
  redirectTo: string;
  gateway: MagicLinkGateway;
}>;

export type SignInRequestResult = Readonly<{ status: "sent" | "invalid_email" | "rate_limited" | "retry" }>;

const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/u;

export async function requestSignIn({ email, redirectTo, gateway }: SignInRequest): Promise<SignInRequestResult> {
  const normalizedEmail = email.trim().toLowerCase();
  if (!emailPattern.test(normalizedEmail)) {
    return { status: "invalid_email" };
  }

  try {
    const result = await gateway.requestMagicLink({ email: normalizedEmail, redirectTo });
    return { status: result === "rate_limited" ? "rate_limited" : "sent" };
  } catch {
    return { status: "retry" };
  }
}
