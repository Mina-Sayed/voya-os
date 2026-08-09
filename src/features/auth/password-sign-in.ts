export type PasswordSignInStatus = "signed_in" | "invalid_credentials" | "rate_limited" | "retry";

export type PasswordSignInGateway = Readonly<{
  signIn(input: Readonly<{ email: string; password: string }>): Promise<Readonly<{
    status: Exclude<PasswordSignInStatus, "retry">;
  }>>;
}>;

type PasswordSignInRequest = Readonly<{
  email: string;
  password: string;
  gateway: PasswordSignInGateway;
}>;

const emailPattern = /^[^\s@]+@[^\s@]+\.[^\s@]+$/u;

export async function requestPasswordSignIn({
  email,
  password,
  gateway,
}: PasswordSignInRequest): Promise<Readonly<{ status: PasswordSignInStatus }>> {
  const normalizedEmail = email.trim().toLowerCase();
  if (!emailPattern.test(normalizedEmail) || password.length < 8) {
    return { status: "invalid_credentials" };
  }

  try {
    return await gateway.signIn({ email: normalizedEmail, password });
  } catch {
    return { status: "retry" };
  }
}
