"use server";

import { requestSignIn, type SignInRequestResult } from "@/features/auth/request-sign-in";
import { requestPasswordSignIn, type PasswordSignInStatus } from "@/features/auth/password-sign-in";
import { internalApplicationUrl, resolveApplicationOrigin } from "@/features/auth/application-origin";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerMagicLinkGateway, createServerPasswordSignInGateway } from "@/lib/supabase/server-auth";

export async function requestSignInAction(email: string): Promise<SignInRequestResult | Readonly<{ status: "unavailable" }>> {
  try {
    const gateway = await createServerMagicLinkGateway();
    const origin = resolveApplicationOrigin({ environment: process.env, requestUrl: "" });
    const redirectTo = internalApplicationUrl(origin, "/auth/callback").toString();
    return requestSignIn({ email, redirectTo, gateway });
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) return { status: "unavailable" };
    return { status: "retry" };
  }
}

export async function passwordSignInAction(
  email: string,
  password: string,
): Promise<Readonly<{ status: PasswordSignInStatus | "unavailable" }>> {
  try {
    const gateway = await createServerPasswordSignInGateway();
    return requestPasswordSignIn({ email, password, gateway });
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) return { status: "unavailable" };
    return { status: "retry" };
  }
}
