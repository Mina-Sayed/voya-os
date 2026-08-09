import { createHash, randomUUID } from "node:crypto";
import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { readSupabasePublicConfig } from "./public-config";
import type { MagicLinkGateway } from "@/features/auth/request-sign-in";
import type { PasswordSignInGateway } from "@/features/auth/password-sign-in";

type AuthRateLimitScope = "magic_link" | "password_sign_in";

function rateLimitKey(email: string): string {
  return createHash("sha256").update(email.trim().toLowerCase(), "utf8").digest("hex");
}

async function consumeAuthRateLimit(
  client: Awaited<ReturnType<typeof createServerSupabaseClient>>,
  scope: AuthRateLimitScope,
  email: string,
): Promise<boolean> {
  const { data, error } = await client.rpc("consume_auth_rate_limit", {
    p_scope: scope,
    p_key_hash: rateLimitKey(email),
  });
  if (error) throw error;
  return data === true;
}

export async function createServerMagicLinkGateway(): Promise<MagicLinkGateway> {
  const client = await createServerSupabaseClient();

  return {
    async requestMagicLink({ email, redirectTo }) {
      if (!await consumeAuthRateLimit(client, "magic_link", email)) return "rate_limited";
      const { error } = await client.auth.signInWithOtp({ email, options: { emailRedirectTo: redirectTo } });
      if (error) throw error;
      return "sent";
    },
  };
}

export async function createServerPasswordSignInGateway(): Promise<PasswordSignInGateway> {
  const client = await createServerSupabaseClient();

  return {
    async signIn({ email, password }) {
      if (!await consumeAuthRateLimit(client, "password_sign_in", email)) {
        return { status: "rate_limited" };
      }

      const { data, error } = await client.auth.signInWithPassword({ email, password });
      if (error) {
        if (error.code === "invalid_credentials") return { status: "invalid_credentials" };
        throw error;
      }
      if (!data.user) return { status: "invalid_credentials" };

      const { data: memberships, error: membershipError } = await client
        .from("organization_memberships")
        .select("id")
        .eq("user_id", data.user.id)
        .eq("status", "active")
        .limit(1);
      if (membershipError) throw membershipError;

      if (!memberships?.length) {
        const { error: bootstrapError } = await client.rpc("bootstrap_personal_workspace", {
          p_request_id: randomUUID(),
        });
        if (bootstrapError) throw bootstrapError;
      }

      return { status: "signed_in" };
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
