const RETIRED_PRODUCTION_ALIAS_HOSTS = ["voya-os.vercel.app"] as const;

type CanonicalHostInput = Readonly<{
  pathname: string;
  search: string;
  host: string | null;
  isProduction: boolean;
  applicationOrigin: string | null;
  deploymentAlias: string | null;
}>;

function normalizeHostname(value: string | null | undefined): string | null {
  const candidate = value?.split(",")[0]?.trim().toLowerCase();
  if (!candidate) return null;
  try {
    const hostname = new URL(`http://${candidate}`).hostname.toLowerCase().replace(/\.+$/, "");
    if (!hostname || /[\s/\\]/.test(hostname)) return null;
    return hostname;
  } catch {
    return null;
  }
}

export function canonicalHostRedirectUrl({
  pathname,
  search,
  host,
  isProduction,
  applicationOrigin,
  deploymentAlias,
}: CanonicalHostInput): URL | null {
  if (!isProduction) return null;

  let canonical: URL;
  try {
    canonical = new URL(applicationOrigin ?? "");
  } catch {
    return null;
  }
  if (canonical.protocol !== "https:" || canonical.pathname !== "/" || canonical.search || canonical.hash) return null;

  if (!pathname.startsWith("/") || pathname === "/api" || pathname.startsWith("/api/")) return null;
  if (search && !search.startsWith("?")) return null;

  const canonicalHost = canonical.hostname.toLowerCase();
  const requestHost = normalizeHostname(host);
  if (!requestHost || requestHost === canonicalHost) return null;

  const aliases = new Set<string>(RETIRED_PRODUCTION_ALIAS_HOSTS);
  const deploymentAliasHost = normalizeHostname(deploymentAlias);
  if (deploymentAliasHost && deploymentAliasHost !== canonicalHost) aliases.add(deploymentAliasHost);
  if (!aliases.has(requestHost)) return null;

  const target = new URL(canonical.origin);
  target.pathname = pathname;
  target.search = search;
  return target;
}
