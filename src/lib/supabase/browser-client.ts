import { createBrowserClient } from "@supabase/ssr";
import { readSupabasePublicConfig } from "./public-config";

export function createBrowserSupabaseClient() {
  const config = readSupabasePublicConfig({
    NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    NODE_ENV: process.env.NODE_ENV,
    VOYA_AUTH_E2E_LOCAL: process.env.NEXT_PUBLIC_VOYA_AUTH_E2E_LOCAL,
  });
  return createBrowserClient(config.url, config.publishableKey);
}
