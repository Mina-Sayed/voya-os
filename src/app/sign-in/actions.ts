"use server";

import { redirect } from "next/navigation";
import type { GoogleSignInResult } from "@/features/auth/google-sign-in";
import { requestPasswordSignIn, type PasswordSignInResult } from "@/features/auth/password-sign-in";
import { requestPasswordSignUp, type PasswordSignUpResult } from "@/features/auth/password-sign-up";
import { internalApplicationUrl, resolveApplicationOrigin } from "@/features/auth/application-origin";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerGoogleSignInGateway, createServerPasswordGateway, createServerPasswordSignUpGateway } from "@/lib/supabase/server-auth";
import { AuthRateLimitUnavailable, consumeAuthRateLimit } from "@/lib/security/auth-rate-limit";
import { isValidEmailAddress, normalizeEmailAddress } from "@/features/auth/email-address";
import { invitationPath, isValidInvitationToken } from "@/features/auth/invitation-token";
import { z } from "zod";

const signInArguments = z.object({
  email: z.string().max(320),
  password: z.string().min(1).max(1024),
  invitationToken: z.string().max(64).optional(),
});
const signUpArguments = z.object({
  email: z.string().max(320),
  password: z.string().min(12).max(1024),
  invitationToken: z.string().max(64).optional(),
});

function authCallbackUrl(invitationToken?: string): string {
  const origin = resolveApplicationOrigin({ environment: process.env, requestUrl: "" });
  const callback = internalApplicationUrl(origin, "/auth/callback");
  if (isValidInvitationToken(invitationToken)) callback.searchParams.set("invite_token", invitationToken);
  return callback.toString();
}

export async function signInWithPasswordAction(
  email: string,
  password: string,
  invitationToken?: string,
): Promise<PasswordSignInResult | Readonly<{ status: "unavailable" }>> {
  const input = signInArguments.safeParse({ email, password, invitationToken });
  if (!input.success) return { status: "invalid_credentials" };
  const normalizedEmail = normalizeEmailAddress(input.data.email);
  if (!isValidEmailAddress(normalizedEmail)) return { status: "invalid_credentials" };
  try {
    if (!await consumeAuthRateLimit({ scope: "password_sign_in", email: normalizedEmail })) return { status: "rate_limited" };
    const gateway = await createServerPasswordGateway();
    const result = await requestPasswordSignIn({ email: normalizedEmail, password: input.data.password, gateway });
    return result.status === "signed_in" && isValidInvitationToken(input.data.invitationToken)
      ? { ...result, nextPath: invitationPath(input.data.invitationToken) }
      : result;
  } catch (error) {
    if (error instanceof SupabaseConfigurationError || error instanceof AuthRateLimitUnavailable) return { status: "unavailable" };
    return { status: "retry" };
  }
}

export async function signUpWithPasswordAction(email: string, password: string, invitationToken?: string): Promise<PasswordSignUpResult | Readonly<{ status: "unavailable" }>> {
  const input = signUpArguments.safeParse({ email, password, invitationToken });
  if (!input.success) return { status: "invalid_credentials" };
  const normalizedEmail = normalizeEmailAddress(input.data.email);
  if (!isValidEmailAddress(normalizedEmail)) return { status: "invalid_credentials" };
  try {
    if (!await consumeAuthRateLimit({ scope: "password_sign_up", email: normalizedEmail })) return { status: "rate_limited" };
    const gateway = await createServerPasswordSignUpGateway();
    const result = await requestPasswordSignUp({ email: normalizedEmail, password: input.data.password, redirectTo: authCallbackUrl(input.data.invitationToken), gateway });
    return result.status === "signed_in" && isValidInvitationToken(input.data.invitationToken)
      ? { ...result, nextPath: invitationPath(input.data.invitationToken) }
      : result;
  } catch (error) {
    if (error instanceof SupabaseConfigurationError || error instanceof AuthRateLimitUnavailable) return { status: "unavailable" };
    return { status: "retry" };
  }
}

export async function signInWithGoogleAction(invitationToken?: string): Promise<GoogleSignInResult> {
  let oauthUrl: string;
  try {
    const gateway = await createServerGoogleSignInGateway();
    oauthUrl = await gateway.signInWithGoogle({ redirectTo: authCallbackUrl(invitationToken) });
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) return { status: "unavailable" };
    return { status: "retry" };
  }
  redirect(oauthUrl);
}
