import { createServerClient } from "@supabase/ssr";
import { createClient } from "@supabase/supabase-js";
import { cookies } from "next/headers";
import { readSupabasePublicConfig, SupabaseConfigurationError } from "./public-config";
import type { PasswordSignInGateway } from "@/features/auth/password-sign-in";
import type { MagicLinkGateway } from "@/features/auth/request-sign-in";

export async function createServerMagicLinkGateway(): Promise<MagicLinkGateway> {
  const client = await createServerSupabaseClient();

  return {
    async requestMagicLink({ email, redirectTo }) {
      const { error } = await client.auth.signInWithOtp({ email, options: { emailRedirectTo: redirectTo } });
      if (error) throw error;
    },
  };
}

export async function createServerPasswordGateway(): Promise<PasswordSignInGateway> {
  const client = await createServerSupabaseClient();

  return {
    async signInWithPassword({ email, password }) {
      const { error } = await client.auth.signInWithPassword({ email, password });
      if (error) throw error;
    },
  };
}

export async function createServerSupabaseClient() {
  const config = readSupabasePublicConfig(process.env);
  const cookieStore = await cookies();
  return createServerClient(config.url, config.publishableKey, {
    auth: { flowType: "pkce" },
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

export function createServiceRoleSupabaseClient() {
  const config = readSupabasePublicConfig(process.env);
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim();
  if (!serviceRoleKey) throw new SupabaseConfigurationError("Supabase server configuration is incomplete.");
  return createClient(config.url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}
