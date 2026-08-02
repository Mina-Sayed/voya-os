import type { NextRequest } from "next/server";
import { refreshSupabaseSession } from "@/lib/supabase/proxy-client";
import { buildContentSecurityPolicy } from "@/lib/security/content-security-policy";

function configuredSupabaseOrigin(): string | undefined {
  try {
    return new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? "").origin;
  } catch {
    return undefined;
  }
}

export async function proxy(request: NextRequest) {
  const nonce = Buffer.from(crypto.randomUUID()).toString("base64");
  const contentSecurityPolicy = buildContentSecurityPolicy({
    nonce,
    isDevelopment: process.env.NODE_ENV !== "production",
    supabaseOrigin: configuredSupabaseOrigin(),
  });
  const forwardedHeaders = new Headers(request.headers);
  forwardedHeaders.set("x-nonce", nonce);
  forwardedHeaders.set("Content-Security-Policy", contentSecurityPolicy);
  const response = await refreshSupabaseSession(request, undefined, undefined, forwardedHeaders);
  response.headers.set("Content-Security-Policy", contentSecurityPolicy);
  return response;
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
