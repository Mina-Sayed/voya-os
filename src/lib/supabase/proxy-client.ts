import { createHash } from "node:crypto";
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

type RequestCookie = ReturnType<NextRequest["cookies"]["getAll"]>[number];

type SessionRefreshResult = Readonly<{
  outcome: "success" | "missing" | "concurrent" | "failed";
  cookies: readonly CookieToSet[];
  cause?: unknown;
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

const inFlightSessionRefreshes = new Map<string, Promise<SessionRefreshResult>>();
const completedSessionRefreshes = new Map<string, Readonly<{
  result: SessionRefreshResult;
  expiresAt: number;
}>>();
const COMPLETED_REFRESH_GRACE_MS = 2_000;

function hasAuthError(result: unknown): result is Readonly<{ error: unknown }> {
  return typeof result === "object" && result !== null && "error" in result && result.error != null;
}

function hasErrorCode(error: unknown, code: string): boolean {
  return typeof error === "object"
    && error !== null
    && "code" in error
    && error.code === code;
}

function isInvalidRefreshTokenError(error: unknown): boolean {
  return hasErrorCode(error, "refresh_token_not_found");
}

function isConcurrentRefreshError(error: unknown): boolean {
  return hasErrorCode(error, "refresh_token_already_used");
}

function isExpectedMissingSessionError(error: unknown): boolean {
  return isAuthSessionMissingError(error) || isInvalidRefreshTokenError(error);
}

function authSessionKey(request: NextRequest): string | undefined {
  const authCookies = request.cookies
    .getAll()
    .filter((cookie) => cookie.name.startsWith("sb-") && cookie.name.includes("auth-token"))
    .sort((left, right) => left.name.localeCompare(right.name));
  if (authCookies.length === 0) return undefined;
  return createHash("sha256").update(JSON.stringify(authCookies)).digest("hex");
}

function classifySessionRefreshError(error: unknown): SessionRefreshResult["outcome"] {
  if (isExpectedMissingSessionError(error)) return "missing";
  if (isConcurrentRefreshError(error)) return "concurrent";
  return "failed";
}

function readCompletedSessionRefresh(key: string | undefined): SessionRefreshResult | undefined {
  if (!key) return undefined;
  const cached = completedSessionRefreshes.get(key);
  if (!cached) return undefined;
  if (cached.expiresAt <= Date.now()) {
    completedSessionRefreshes.delete(key);
    return undefined;
  }
  return cached.result;
}

function rememberCompletedSessionRefresh(key: string, result: SessionRefreshResult): void {
  if (result.outcome !== "success" || result.cookies.length === 0) return;
  const entry = { result, expiresAt: Date.now() + COMPLETED_REFRESH_GRACE_MS } as const;
  completedSessionRefreshes.set(key, entry);
  const expiry = setTimeout(() => {
    if (completedSessionRefreshes.get(key) === entry) completedSessionRefreshes.delete(key);
  }, COMPLETED_REFRESH_GRACE_MS);
  expiry.unref?.();
}

async function executeSessionRefresh(
  request: NextRequest,
  clientFactory: ProxyClientFactory,
  config: SupabasePublicConfig,
): Promise<SessionRefreshResult> {
  const workingCookies = new Map<string, RequestCookie>(
    request.cookies.getAll().map((cookie) => [cookie.name, cookie]),
  );
  const pendingResponseCookies = new Map<string, CookieToSet>();

  try {
    const client = clientFactory(config.url, config.publishableKey, {
      cookies: {
        encode: "tokens-only",
        getAll: () => Array.from(workingCookies.values()),
        setAll: (cookiesToSet) => {
          for (const cookie of cookiesToSet) {
            workingCookies.set(cookie.name, { name: cookie.name, value: cookie.value });
            pendingResponseCookies.set(cookie.name, cookie);
          }
        },
      },
    });
    const userResult = await client.auth.getUser();
    if (hasAuthError(userResult)) {
      const outcome = classifySessionRefreshError(userResult.error);
      return {
        outcome,
        cookies: outcome === "missing" ? Array.from(pendingResponseCookies.values()) : [],
        ...(outcome === "failed" ? { cause: userResult.error } : {}),
      };
    }
    return { outcome: "success", cookies: Array.from(pendingResponseCookies.values()) };
  } catch (cause) {
    const outcome = classifySessionRefreshError(cause);
    return {
      outcome,
      cookies: outcome === "missing" ? Array.from(pendingResponseCookies.values()) : [],
      ...(outcome === "failed" ? { cause } : {}),
    };
  }
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
    const key = authSessionKey(request);
    const existingFlight = key ? inFlightSessionRefreshes.get(key) : undefined;
    const completedResult = readCompletedSessionRefresh(key);
    const flight = existingFlight
      ?? (completedResult
        ? Promise.resolve(completedResult)
        : executeSessionRefresh(request, clientFactory, resolvedConfig));
    const ownsFlight = Boolean(key && !existingFlight && !completedResult);
    if (key && ownsFlight) inFlightSessionRefreshes.set(key, flight);

    let result: SessionRefreshResult;
    try {
      result = await flight;
    } finally {
      if (key && ownsFlight && inFlightSessionRefreshes.get(key) === flight) {
        inFlightSessionRefreshes.delete(key);
      }
    }

    if (key && ownsFlight) rememberCompletedSessionRefresh(key, result);

    if (result.outcome === "success" || result.outcome === "missing") {
      for (const cookie of result.cookies) request.cookies.set(cookie.name, cookie.value);
      if (forwardedHeaders) forwardedHeaders.set("cookie", request.cookies.toString());
      response = createPassThroughResponse();
      for (const cookie of result.cookies) {
        response.cookies.set(cookie.name, cookie.value, cookie.options);
      }
    }
    if (result.outcome === "concurrent") {
      // Another request may already have rotated this session successfully.
      // Never delete cookies here: this response can arrive after the winner
      // and overwrite the browser's fresh session with a deletion.
    }
    if (result.outcome === "failed") throw result.cause;
  } catch (cause) {
    if (isExpectedMissingSessionError(cause) || isConcurrentRefreshError(cause)) return response;
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
