export type PublicEnvironment = Readonly<Record<string, string | undefined>>;

export type SupabasePublicConfig = Readonly<{
  url: string;
  publishableKey: string;
}>;

export class SupabaseConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SupabaseConfigurationError";
  }
}

export function readSupabasePublicConfig(environment: PublicEnvironment): SupabasePublicConfig {
  const url = environment.NEXT_PUBLIC_SUPABASE_URL?.trim();
  const publishableKey = environment.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY?.trim();

  if (!url || !publishableKey) {
    throw new SupabaseConfigurationError("Supabase public configuration is incomplete.");
  }

  let parsedUrl: URL;
  try {
    parsedUrl = new URL(url);
  } catch {
    throw new SupabaseConfigurationError("Supabase project URL is invalid.");
  }

  const dedicatedLocalAuthE2e = environment.VOYA_AUTH_E2E_LOCAL === "1"
    && parsedUrl.origin === "http://127.0.0.1:55321"
    && parsedUrl.pathname === "/"
    && !parsedUrl.search
    && !parsedUrl.hash;
  if (
    environment.NODE_ENV === "production"
    && parsedUrl.protocol !== "https:"
    && !dedicatedLocalAuthE2e
  ) {
    throw new SupabaseConfigurationError("Supabase project URL must use HTTPS in production.");
  }

  return { url: parsedUrl.toString().replace(/\/$/, ""), publishableKey };
}
