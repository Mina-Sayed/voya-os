import { NextResponse, type NextRequest } from "next/server";
import { refreshSupabaseSession } from "@/lib/supabase/proxy-client";
import { REQUEST_ID_HEADER, resolveRequestId } from "@/lib/observability/request-id";
import { buildContentSecurityPolicy } from "@/lib/security/content-security-policy";
import { canonicalHostRedirectUrl } from "@/lib/security/canonical-host";

function configuredSupabaseOrigin(): string | undefined {
  try {
    return new URL(process.env.NEXT_PUBLIC_SUPABASE_URL ?? "").origin;
  } catch {
    return undefined;
  }
}

export async function proxy(request: NextRequest) {
  // Google sign-in stores a host-only PKCE verifier, and VOYA pins its callback to one
  // application origin, so serving the same session on a second hostname fails silently.
  // Send retired aliases to the canonical origin before any session work happens.
  const forwardedHost = request.headers.get("x-forwarded-host")?.trim();
  const canonicalRedirect = canonicalHostRedirectUrl({
    pathname: request.nextUrl.pathname,
    search: request.nextUrl.search,
    host: forwardedHost || request.nextUrl.host,
    isProduction: process.env.NODE_ENV === "production",
    applicationOrigin: process.env.VOYA_APP_URL ?? null,
    deploymentAlias: process.env.VERCEL_PROJECT_PRODUCTION_URL ?? null,
  });
  if (canonicalRedirect) {
    const redirect = NextResponse.redirect(canonicalRedirect, 308);
    redirect.headers.set("Cache-Control", "private, no-store");
    return redirect;
  }

  const nonce = Buffer.from(crypto.randomUUID()).toString("base64");
  const requestId = resolveRequestId(request.headers.get(REQUEST_ID_HEADER));
  const contentSecurityPolicy = buildContentSecurityPolicy({
    nonce,
    isDevelopment: process.env.NODE_ENV !== "production",
    supabaseOrigin: configuredSupabaseOrigin(),
  });
  const forwardedHeaders = new Headers(request.headers);
  forwardedHeaders.set("x-nonce", nonce);
  forwardedHeaders.set(REQUEST_ID_HEADER, requestId);
  forwardedHeaders.set("Content-Security-Policy", contentSecurityPolicy);
  const response = await refreshSupabaseSession(request, undefined, undefined, forwardedHeaders);
  response.headers.set("Content-Security-Policy", contentSecurityPolicy);
  response.headers.set(REQUEST_ID_HEADER, requestId);
  return response;
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
