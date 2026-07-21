import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { readSupabasePublicConfig } from "./public-config";
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

export async function createServerSupabaseClient() {
  const config = readSupabasePublicConfig(process.env);
  const cookieStore = await cookies();
  return createServerClient(config.url, config.publishableKey, {
    cookies: {
      getAll: () => cookieStore.getAll(),
      setAll: (cookiesToSet) => {
        for (const { name, value, options } of cookiesToSet) {
          cookieStore.set(name, value, options);
        }
      },
    },
  });

}
