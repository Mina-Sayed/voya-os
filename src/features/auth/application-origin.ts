import { type PublicEnvironment, SupabaseConfigurationError } from "@/lib/supabase/public-config";

type ApplicationOriginInput = Readonly<{
  environment: PublicEnvironment;
  requestUrl: string;
}>;

type InternalApplicationPath = "/auth/callback" | "/workspace" | "/access-pending" | "/onboarding" | "/forgot-password" | "/auth/recovery" | "/security/mfa?reason=enrollment";
const DEDICATED_LOCAL_AUTH_E2E_ORIGIN = "http://127.0.0.1:3102";

function parseConfiguredApplicationOrigin(value: string, isProduction: boolean, allowDedicatedLocalAuthE2E: boolean): URL {
  let origin: URL;
  try {
    origin = new URL(value);
  } catch {
    throw new SupabaseConfigurationError("Voya app URL is invalid.");
  }

  const isDedicatedLocalAuthE2E = allowDedicatedLocalAuthE2E && origin.origin === DEDICATED_LOCAL_AUTH_E2E_ORIGIN;
  if (
    origin.pathname !== "/"
    || origin.username
    || origin.password
    || origin.search
    || origin.hash
    || origin.href !== `${origin.origin}/`
    || (isProduction && origin.protocol !== "https:" && !isDedicatedLocalAuthE2E)
  ) {
    throw new SupabaseConfigurationError("Voya app URL is not an approved application origin.");
  }

  return origin;
}

export function resolveApplicationOrigin({ environment, requestUrl }: ApplicationOriginInput): URL {
  const configuredOrigin = environment.VOYA_APP_URL?.trim();
  const isProduction = environment.NODE_ENV === "production";

  if (configuredOrigin) return parseConfiguredApplicationOrigin(configuredOrigin, isProduction, environment.VOYA_AUTH_E2E_LOCAL === "1");
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
