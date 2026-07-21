"use server";

import { requestSignIn, type SignInRequestResult } from "@/features/auth/request-sign-in";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerMagicLinkGateway } from "@/lib/supabase/server-auth";

function readAppUrl(environment: NodeJS.ProcessEnv): string {
  const value = environment.VOYA_APP_URL?.trim();
  if (!value) throw new SupabaseConfigurationError("Voya app URL is not configured.");
  const url = new URL(value);
  if (environment.NODE_ENV === "production" && url.protocol !== "https:") {
    throw new SupabaseConfigurationError("Voya app URL must use HTTPS in production.");
  }
  return url.toString();
}

export async function requestSignInAction(email: string): Promise<SignInRequestResult | Readonly<{ status: "unavailable" }>> {
  try {
    const gateway = await createServerMagicLinkGateway();
    const redirectTo = new URL("/auth/callback", readAppUrl(process.env)).toString();
    return requestSignIn({ email, redirectTo, gateway });
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) return { status: "unavailable" };
    return { status: "retry" };
  }
}
