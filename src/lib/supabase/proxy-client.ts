import { createServerClient } from "@supabase/ssr";
import { isAuthSessionMissingError } from "@supabase/supabase-js";
import { NextResponse, type NextRequest } from "next/server";
import { reportOperationalError } from "@/lib/observability/operational-error";
import { readSupabasePublicConfig, SupabaseConfigurationError, type SupabasePublicConfig } from "./public-config";

type CookieToSet = Readonly<{
  name: string;
  value: string;
  options?: Record<string, unknown>;
}>;

type ProxyCookieOptions = Readonly<{
  cookies: Readonly<{
    getAll(): ReturnType<NextRequest["cookies"]["getAll"]>;
    setAll(cookies: CookieToSet[]): void;
  }>;
}>;

export type ProxyClientFactory = (
  url: string,
  publishableKey: string,
  options: ProxyCookieOptions,
) => Readonly<{
  auth: Readonly<{
    getUser(): Promise<unknown>;
    mfa?: Readonly<{ getAuthenticatorAssuranceLevel(): Promise<unknown> }>;
  }>;
}>;

function hasAuthError(result: unknown): result is Readonly<{ error: unknown }> {
  return typeof result === "object" && result !== null && "error" in result && result.error != null;
}

function hasAuthenticatedUser(result: unknown): boolean {
  if (typeof result !== "object" || result === null || !("data" in result)) return false;
  const data = result.data;
  return typeof data === "object" && data !== null && "user" in data && data.user != null;
}

type AssuranceLevel = "aal1" | "aal2";

function isAssuranceLevel(value: unknown): value is AssuranceLevel {
  return value === "aal1" || value === "aal2";
}

function assuranceLevels(result: unknown): Readonly<{ currentLevel: AssuranceLevel; nextLevel: AssuranceLevel }> | null {
  if (hasAuthError(result) || typeof result !== "object" || result === null || !("data" in result)) return null;
  const data = result.data;
  if (typeof data !== "object" || data === null || !("currentLevel" in data) || !("nextLevel" in data)) return null;
  if (!isAssuranceLevel(data.currentLevel) || !isAssuranceLevel(data.nextLevel)) return null;
  return { currentLevel: data.currentLevel, nextLevel: data.nextLevel };
}

export function isProtectedWorkspacePath(pathname: string): boolean {
  return pathname === "/workspace" || pathname.startsWith("/workspace/");
}

function redirectWithCookies(request: NextRequest, path: "/mfa" | "/access-pending", source: NextResponse): NextResponse {
  const redirect = NextResponse.redirect(new URL(path, request.url));
  for (const cookie of source.cookies.getAll()) redirect.cookies.set(cookie);
  return redirect;
}

export async function refreshSupabaseSession(
  request: NextRequest,
  clientFactory: ProxyClientFactory = createServerClient as ProxyClientFactory,
  config?: SupabasePublicConfig,
): Promise<NextResponse> {
  let response = NextResponse.next({ request });
  try {
    const resolvedConfig = config ?? readSupabasePublicConfig(process.env);
    const client = clientFactory(resolvedConfig.url, resolvedConfig.publishableKey, {
      cookies: {
        getAll: () => request.cookies.getAll(),
        setAll: (cookiesToSet) => {
          for (const cookie of cookiesToSet) {
            request.cookies.set(cookie.name, cookie.value);
          }
          response = NextResponse.next({ request });
          for (const cookie of cookiesToSet) {
            response.cookies.set(cookie.name, cookie.value, cookie.options);
          }
        },
      },
    });
    const userResult = await client.auth.getUser();
    if (hasAuthError(userResult) && isAuthSessionMissingError(userResult.error)) return response;
    if (hasAuthError(userResult)) throw userResult.error;
    if (!isProtectedWorkspacePath(request.nextUrl.pathname) || !hasAuthenticatedUser(userResult)) return response;

    let assuranceResult: unknown;
    try {
      assuranceResult = await client.auth.mfa?.getAuthenticatorAssuranceLevel();
    } catch (cause) {
      reportOperationalError({
        operation: "supabase.mfa_assurance",
        requestId: crypto.randomUUID(),
        code: "mfa_assurance_failed",
        outcome: "unavailable",
        cause,
      });
      return redirectWithCookies(request, "/access-pending", response);
    }
    const levels = assuranceLevels(assuranceResult);
    if (!levels) {
      const cause = hasAuthError(assuranceResult) ? assuranceResult.error : undefined;
      reportOperationalError({
        operation: "supabase.mfa_assurance",
        requestId: crypto.randomUUID(),
        code: "mfa_assurance_failed",
        outcome: "unavailable",
        cause,
      });
      return redirectWithCookies(request, "/access-pending", response);
    }
    if (levels.currentLevel !== "aal2" && levels.nextLevel === "aal2") {
      return redirectWithCookies(request, "/mfa", response);
    }
  } catch (cause) {
    if (isAuthSessionMissingError(cause)) return response;
    reportOperationalError({
      operation: "supabase.session_refresh",
      requestId: crypto.randomUUID(),
      code: "session_refresh_failed",
      outcome: "unavailable",
      cause,
    });
    if (
      cause instanceof SupabaseConfigurationError
      && cause.message === "Supabase public configuration is incomplete."
    ) {
      return response;
    }
    if (!isProtectedWorkspacePath(request.nextUrl.pathname)) {
      return response;
    }
    return redirectWithCookies(request, "/access-pending", response);
  }
  return response;
}
