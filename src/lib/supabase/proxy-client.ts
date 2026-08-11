import { createServerClient } from "@supabase/ssr";
import { isAuthSessionMissingError } from "@supabase/supabase-js";
import { NextResponse, type NextRequest } from "next/server";
import { reportOperationalError } from "@/lib/observability/operational-error";
import { readSupabasePublicConfig, type SupabasePublicConfig } from "./public-config";

type CookieToSet = Readonly<{
  name: string;
  value: string;
  options?: Record<string, unknown>;
}>;

type ProxyCookieOptions = Readonly<{
  cookies: Readonly<{
    encode: "tokens-only";
    getAll(): ReturnType<NextRequest["cookies"]["getAll"]>;
    setAll(cookies: CookieToSet[]): void;
  }>;
}>;

export type ProxyClientFactory = (
  url: string,
  publishableKey: string,
  options: ProxyCookieOptions,
) => Readonly<{ auth: Readonly<{ getUser(): Promise<unknown> }> }>;

function hasAuthError(result: unknown): result is Readonly<{ error: unknown }> {
  return typeof result === "object" && result !== null && "error" in result && result.error != null;
}

function isInvalidRefreshTokenError(error: unknown): boolean {
  return typeof error === "object"
    && error !== null
    && "code" in error
    && error.code === "refresh_token_not_found";
}

function isExpectedMissingSessionError(error: unknown): boolean {
  return isAuthSessionMissingError(error) || isInvalidRefreshTokenError(error);
}

export async function refreshSupabaseSession(
  request: NextRequest,
  clientFactory: ProxyClientFactory = createServerClient as ProxyClientFactory,
  config?: SupabasePublicConfig,
  forwardedHeaders?: Headers,
): Promise<NextResponse> {
  const createPassThroughResponse = () => forwardedHeaders
    ? NextResponse.next({ request: { headers: forwardedHeaders } })
    : NextResponse.next({ request });
  let response = createPassThroughResponse();
  try {
    const resolvedConfig = config ?? readSupabasePublicConfig(process.env);
    const client = clientFactory(resolvedConfig.url, resolvedConfig.publishableKey, {
      cookies: {
        encode: "tokens-only",
        getAll: () => request.cookies.getAll(),
        setAll: (cookiesToSet) => {
          for (const cookie of cookiesToSet) {
            request.cookies.set(cookie.name, cookie.value);
          }
          if (forwardedHeaders) forwardedHeaders.set("cookie", request.cookies.toString());
          response = createPassThroughResponse();
          for (const cookie of cookiesToSet) {
            response.cookies.set(cookie.name, cookie.value, cookie.options);
          }
        },
      },
    });
    const userResult = await client.auth.getUser();
    if (hasAuthError(userResult) && isExpectedMissingSessionError(userResult.error)) return response;
    if (hasAuthError(userResult)) throw userResult.error;
  } catch (cause) {
    if (isExpectedMissingSessionError(cause)) return response;
    reportOperationalError({
      operation: "supabase.session_refresh",
      requestId: crypto.randomUUID(),
      code: "session_refresh_failed",
      outcome: "unavailable",
      cause,
    });
    return response;
  }
  return response;
}
