"use server";

import { requestSignIn, type SignInRequestResult } from "@/features/auth/request-sign-in";
import { internalApplicationUrl, resolveApplicationOrigin } from "@/features/auth/application-origin";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerMagicLinkGateway } from "@/lib/supabase/server-auth";

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
