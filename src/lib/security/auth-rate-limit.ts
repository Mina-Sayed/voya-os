import { createHmac } from "node:crypto";
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
const AUTH_RATE_LIMIT_KEY_PREFIX = "voya-auth-rate-limit:v2";
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
): string {
  if (!secret || secret.trim().length === 0) throw new AuthRateLimitUnavailable();
  const canonicalInput = [AUTH_RATE_LIMIT_KEY_PREFIX, scope, email.trim().toLowerCase()].join(AUTH_RATE_LIMIT_SEPARATOR);
  return createHmac("sha256", secret)
    .update(canonicalInput, "utf8")
    .digest("hex");
}

export async function consumeAuthRateLimit({ scope, email }: Readonly<{ scope: AuthRateLimitScope; email: string }>): Promise<boolean> {
  try {
    const keyHash = hashAuthRateLimitKey(scope, email);
    const client = createServiceRoleSupabaseClient();
    const { data, error } = await client.rpc("consume_auth_rate_limit", {
      p_scope: scope,
      p_key_hash: keyHash,
    });
    if (error || typeof data !== "boolean") throw new AuthRateLimitUnavailable();
    return data;
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) throw error;
    if (error instanceof AuthRateLimitUnavailable) throw error;
    throw new AuthRateLimitUnavailable();
  }
}
