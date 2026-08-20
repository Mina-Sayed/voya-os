import { createHash, randomUUID } from "node:crypto";
import { createServerClient } from "@supabase/ssr";
import { createClient } from "@supabase/supabase-js";
import { cookies, headers } from "next/headers";
import { readSupabasePublicConfig } from "./public-config";
import type { MagicLinkGateway } from "@/features/auth/request-sign-in";
import type { PasswordSignInGateway } from "@/features/auth/password-sign-in";

type AuthRateLimitScope = "magic_link" | "password_sign_in";

function rateLimitKey(email: string, requestAddress: string): string {
  return createHash("sha256")
    .update(`${email.trim().toLowerCase()}\n${requestAddress}`, "utf8")
    .digest("hex");
}

async function consumeAuthRateLimit(
  scope: AuthRateLimitScope,
  email: string,
  requestAddress: string,
): Promise<boolean> {
  const config = readSupabasePublicConfig(process.env);
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim();
  if (!serviceRoleKey) throw new Error("Supabase service-role configuration is incomplete.");
  const client = createClient(config.url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data, error } = await client.rpc("consume_auth_rate_limit", {
    p_scope: scope,
    p_key_hash: rateLimitKey(email, requestAddress),
  });
  if (error) throw error;
  return data === true;
}

async function trustedRequestAddress(): Promise<string> {
  if (process.env.VERCEL !== "1") return "unknown";

  const requestHeaders = await headers();
  return requestHeaders.get("x-forwarded-for")?.split(",", 1)[0]?.trim()
    || "unknown";
}

export async function createServerMagicLinkGateway(): Promise<MagicLinkGateway> {
  const client = await createServerSupabaseClient();
  const requestAddress = await trustedRequestAddress();

  return {
    async requestMagicLink({ email, redirectTo }) {
      if (!await consumeAuthRateLimit("magic_link", email, requestAddress)) return "rate_limited";
      const { error } = await client.auth.signInWithOtp({ email, options: { emailRedirectTo: redirectTo } });
      if (error) throw error;
      return "sent";
    },
  };
}

export async function createServerPasswordSignInGateway(): Promise<PasswordSignInGateway> {
  const client = await createServerSupabaseClient();
  const requestAddress = await trustedRequestAddress();

  return {
    async signIn({ email, password }) {
      if (!await consumeAuthRateLimit("password_sign_in", email, requestAddress)) {
        return { status: "rate_limited" };
      }

      const { data, error } = await client.auth.signInWithPassword({ email, password });
      if (error) {
        if (error.code === "invalid_credentials") return { status: "invalid_credentials" };
        throw error;
      }
      if (!data.user) return { status: "invalid_credentials" };

      try {
        const { data: memberships, error: membershipError } = await client
          .from("organization_memberships")
          .select("id, status")
          .eq("user_id", data.user.id);
        if (membershipError) throw membershipError;

        if (!Array.isArray(memberships)) return { status: "access_pending" };
        if (memberships.some((membership) => membership.status === "active")) {
          return { status: "signed_in" };
        }
        if (memberships.length > 0 || !data.user.email_confirmed_at) {
          return { status: "access_pending" };
        }

        if (memberships.length === 0) {
          const { error: bootstrapError } = await client.rpc("bootstrap_personal_workspace", {
            p_request_id: randomUUID(),
          });
          if (bootstrapError) throw bootstrapError;
        }

        return { status: "signed_in" };
      } catch (error) {
        await client.auth.signOut({ scope: "local" });
        throw error;
      }
    },
  };
}

export async function createServerSupabaseClient() {
  const config = readSupabasePublicConfig(process.env);
  const cookieStore = await cookies();
  return createServerClient(config.url, config.publishableKey, {
    cookies: {
      getAll: () => cookieStore.getAll(),
      setAll: (cookiesToSet) => {
        try {
          for (const { name, value, options } of cookiesToSet) {
            cookieStore.set(name, value, options);
          }
        } catch {
          // Server Components cannot mutate cookies. The request proxy performs
          // session refresh before protected rendering; Server Actions and Route
          // Handlers still write cookies through this adapter normally.
        }
      },
    },
  });

}
