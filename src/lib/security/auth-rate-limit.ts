import { createHash } from "node:crypto";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";

export type AuthRateLimitScope = "magic_link" | "password_sign_in";

type AuthRateLimitPolicy = Readonly<{
  limit: number;
  windowSeconds: number;
}>;

const policies: Readonly<Record<AuthRateLimitScope, AuthRateLimitPolicy>> = {
  magic_link: { limit: 5, windowSeconds: 900 },
  password_sign_in: { limit: 10, windowSeconds: 900 },
};

export class AuthRateLimitUnavailable extends Error {
  constructor() {
    super("Authentication rate limiting is unavailable.");
    this.name = "AuthRateLimitUnavailable";
  }
}

export function hashAuthRateLimitKey(scope: AuthRateLimitScope, email: string): string {
  return createHash("sha256")
    .update(`voya-auth-rate-limit:v1:${scope}:${email.trim().toLowerCase()}`, "utf8")
    .digest("hex");
}

export async function consumeAuthRateLimit({ scope, email }: Readonly<{ scope: AuthRateLimitScope; email: string }>): Promise<boolean> {
  const policy = policies[scope];
  try {
    const client = await createServerSupabaseClient();
    const { data, error } = await client.rpc("consume_auth_rate_limit", {
      p_scope: scope,
      p_key_hash: hashAuthRateLimitKey(scope, email),
      p_limit: policy.limit,
      p_window_seconds: policy.windowSeconds,
    });
    if (error || typeof data !== "boolean") throw new AuthRateLimitUnavailable();
    return data;
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) throw error;
    if (error instanceof AuthRateLimitUnavailable) throw error;
    throw new AuthRateLimitUnavailable();
  }
}
