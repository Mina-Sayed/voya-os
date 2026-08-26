import { createServerClient } from "@supabase/ssr";
import { createClient } from "@supabase/supabase-js";
import { cookies } from "next/headers";
import { readSupabasePublicConfig, SupabaseConfigurationError } from "./public-config";
import type { PasswordSignInGateway } from "@/features/auth/password-sign-in";
import type { GoogleSignInGateway } from "@/features/auth/google-sign-in";
import type { PasswordSignUpGateway } from "@/features/auth/password-sign-up";

export async function createServerPasswordGateway(): Promise<PasswordSignInGateway> {
  const client = await createServerSupabaseClient();

  return {
    async signInWithPassword({ email, password }) {
      const { error } = await client.auth.signInWithPassword({ email, password });
      if (error) throw error;
    },
  };
}

export async function createServerPasswordSignUpGateway(): Promise<PasswordSignUpGateway> {
  const client = await createServerSupabaseClient();

  return {
    async signUp({ email, password, redirectTo }) {
      const { data, error } = await client.auth.signUp({ email, password, options: { emailRedirectTo: redirectTo } });
      if (error) throw error;
      return { sessionAvailable: data.session !== null };
    },
  };
}

export async function createServerGoogleSignInGateway(): Promise<GoogleSignInGateway> {
  const client = await createServerSupabaseClient();

  return {
    async signInWithGoogle({ redirectTo }) {
      const { data, error } = await client.auth.signInWithOAuth({ provider: "google", options: { redirectTo } });
      if (error) throw error;
      if (!data.url) throw new Error("Google OAuth URL was not returned.");
      return data.url;
    },
  };
}

export async function createServerSupabaseClient() {
  const config = readSupabasePublicConfig(process.env);
  const cookieStore = await cookies();
  return createServerClient(config.url, config.publishableKey, {
    auth: { flowType: "pkce" },
    cookies: {
      encode: "tokens-only",
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

export function createServiceRoleSupabaseClient(options: Readonly<{ fetch?: typeof fetch }> = {}) {
  const config = readSupabasePublicConfig(process.env);
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY?.trim();
  if (!serviceRoleKey) throw new SupabaseConfigurationError("Supabase server configuration is incomplete.");
  return createClient(config.url, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    ...(options.fetch ? { global: { fetch: options.fetch } } : {}),
  });
}
