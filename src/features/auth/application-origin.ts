import { type PublicEnvironment, SupabaseConfigurationError } from "@/lib/supabase/public-config";

type ApplicationOriginInput = Readonly<{
  environment: PublicEnvironment;
  requestUrl: string;
}>;

type InternalApplicationPath = "/auth/callback" | "/workspace" | "/access-pending" | "/onboarding" | "/forgot-password" | "/auth/recovery" | "/security/mfa?reason=enrollment";

function parseConfiguredApplicationOrigin(value: string, isProduction: boolean): URL {
  let origin: URL;
  try {
    origin = new URL(value);
  } catch {
    throw new SupabaseConfigurationError("Voya app URL is invalid.");
  }

  if (
    origin.pathname !== "/"
    || origin.username
    || origin.password
    || origin.search
    || origin.hash
    || origin.href !== `${origin.origin}/`
    || (isProduction && origin.protocol !== "https:")
  ) {
    throw new SupabaseConfigurationError("Voya app URL is not an approved application origin.");
  }

  return origin;
}

export function resolveApplicationOrigin({ environment, requestUrl }: ApplicationOriginInput): URL {
  const configuredOrigin = environment.VOYA_APP_URL?.trim();
  const isProduction = environment.NODE_ENV === "production";

  if (configuredOrigin) return parseConfiguredApplicationOrigin(configuredOrigin, isProduction);
  if (isProduction) throw new SupabaseConfigurationError("Voya app URL is not configured.");

  try {
    return new URL(new URL(requestUrl).origin);
  } catch {
    throw new SupabaseConfigurationError("Request URL is invalid.");
  }
}

export function internalApplicationUrl(origin: URL, path: InternalApplicationPath): URL {
  return new URL(path, origin);
}
