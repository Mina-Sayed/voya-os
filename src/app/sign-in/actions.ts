"use server";

import { requestSignIn, type SignInRequestResult } from "@/features/auth/request-sign-in";
import { requestPasswordSignIn, type PasswordSignInResult } from "@/features/auth/password-sign-in";
import { internalApplicationUrl, resolveApplicationOrigin } from "@/features/auth/application-origin";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerMagicLinkGateway, createServerPasswordGateway } from "@/lib/supabase/server-auth";
import { AuthRateLimitUnavailable, consumeAuthRateLimit } from "@/lib/security/auth-rate-limit";
import { isValidEmailAddress, normalizeEmailAddress } from "@/features/auth/email-address";

export async function requestSignInAction(email: string): Promise<SignInRequestResult | Readonly<{ status: "unavailable" }>> {
  const normalizedEmail = normalizeEmailAddress(email);
  if (!isValidEmailAddress(normalizedEmail)) return { status: "invalid_email" };
  try {
    if (!await consumeAuthRateLimit({ scope: "magic_link", email: normalizedEmail })) return { status: "rate_limited" };
    const gateway = await createServerMagicLinkGateway();
    const origin = resolveApplicationOrigin({ environment: process.env, requestUrl: "" });
    const redirectTo = internalApplicationUrl(origin, "/auth/callback").toString();
    return requestSignIn({ email, redirectTo, gateway });
  } catch (error) {
    if (error instanceof SupabaseConfigurationError || error instanceof AuthRateLimitUnavailable) return { status: "unavailable" };
    return { status: "retry" };
  }
}

export async function signInWithPasswordAction(
  email: string,
  password: string,
): Promise<PasswordSignInResult | Readonly<{ status: "unavailable" }>> {
  const normalizedEmail = normalizeEmailAddress(email);
  if (!isValidEmailAddress(normalizedEmail) || password.length === 0) return { status: "invalid_credentials" };
  try {
    if (!await consumeAuthRateLimit({ scope: "password_sign_in", email: normalizedEmail })) return { status: "rate_limited" };
    const gateway = await createServerPasswordGateway();
    return requestPasswordSignIn({ email, password, gateway });
  } catch (error) {
    if (error instanceof SupabaseConfigurationError || error instanceof AuthRateLimitUnavailable) return { status: "unavailable" };
    return { status: "retry" };
  }
}
