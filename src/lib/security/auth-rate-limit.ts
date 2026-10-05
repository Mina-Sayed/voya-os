import { createHmac } from "node:crypto";
import { isIP } from "node:net";
import { headers as requestHeaders } from "next/headers";
import { createServiceRoleSupabaseClient } from "@/lib/supabase/server-auth";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";

export type AuthRateLimitScope = "password_sign_in" | "password_sign_up" | "password_reset" | "invitation_resend";

export class AuthRateLimitUnavailable extends Error {
  constructor() {
    super("Authentication rate limiting is unavailable.");
    this.name = "AuthRateLimitUnavailable";
  }
}

const AUTH_RATE_LIMIT_HMAC_SECRET = "AUTH_RATE_LIMIT_HMAC_SECRET";
const AUTH_RATE_LIMIT_KEY_PREFIX = "voya-auth-rate-limit:v3";
const AUTH_RATE_LIMIT_SEPARATOR = "\u001f";

function readAuthRateLimitHmacSecret(): string {
  const secret = process.env[AUTH_RATE_LIMIT_HMAC_SECRET];
  if (!secret || secret.trim().length === 0) throw new AuthRateLimitUnavailable();
  return secret;
}

export function hashAuthRateLimitKey(
  scope: AuthRateLimitScope,
  email: string,
  secret = readAuthRateLimitHmacSecret(),
  source = "unknown",
): string {
  if (!secret || secret.trim().length === 0) throw new AuthRateLimitUnavailable();
  const canonicalInput = [AUTH_RATE_LIMIT_KEY_PREFIX, scope, source.trim(), email.trim().toLowerCase()].join(AUTH_RATE_LIMIT_SEPARATOR);
  return createHmac("sha256", secret)
    .update(canonicalInput, "utf8")
    .digest("hex");
}

export function hashAuthRateLimitSourceKey(
  scope: AuthRateLimitScope,
  source: string,
  secret = readAuthRateLimitHmacSecret(),
): string {
  if (!secret || secret.trim().length === 0) throw new AuthRateLimitUnavailable();
  const canonicalInput = [AUTH_RATE_LIMIT_KEY_PREFIX, scope, "source", source.trim()].join(AUTH_RATE_LIMIT_SEPARATOR);
  return createHmac("sha256", secret).update(canonicalInput, "utf8").digest("hex");
}

export function getAuthRateLimitSource(headers: Headers): string {
  // Vercel overwrites these headers with the public client IP. Keep the
  // platform-specific copy first in case another trusted proxy sits in front.
  for (const headerName of ["x-vercel-forwarded-for", "x-real-ip", "x-forwarded-for"]) {
    const value = headers.get(headerName)?.split(",", 1)[0]?.trim();
    if (value && isIP(value)) return value;
  }
  return "unknown";
}

export async function consumeAuthRateLimit({ scope, email }: Readonly<{ scope: AuthRateLimitScope; email: string }>): Promise<boolean> {
  try {
    const source = getAuthRateLimitSource(await requestHeaders());
    const sourceKeyHash = hashAuthRateLimitSourceKey(scope, source);
    const accountKeyHash = hashAuthRateLimitKey(scope, email, readAuthRateLimitHmacSecret(), source);
    const client = createServiceRoleSupabaseClient();
    const sourceResult = await client.rpc("consume_auth_rate_limit", {
      p_scope: scope,
      p_key_hash: sourceKeyHash,
    });
    if (sourceResult.error || typeof sourceResult.data !== "boolean") throw new AuthRateLimitUnavailable();
    if (!sourceResult.data) return false;
    const accountResult = await client.rpc("consume_auth_rate_limit", {
      p_scope: scope,
      p_key_hash: accountKeyHash,
    });
    if (accountResult.error || typeof accountResult.data !== "boolean") throw new AuthRateLimitUnavailable();
    return accountResult.data;
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) throw error;
    if (error instanceof AuthRateLimitUnavailable) throw error;
    throw new AuthRateLimitUnavailable();
  }
}
