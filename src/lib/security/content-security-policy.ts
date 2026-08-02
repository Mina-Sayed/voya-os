type ContentSecurityPolicyOptions = Readonly<{
  nonce: string;
  isDevelopment: boolean;
  supabaseOrigin?: string;
}>;

export function buildContentSecurityPolicy({ nonce, isDevelopment, supabaseOrigin }: ContentSecurityPolicyOptions): string {
  const connectSources = ["'self'", supabaseOrigin].filter(Boolean);
  if (supabaseOrigin?.startsWith("https://")) connectSources.push(supabaseOrigin.replace("https://", "wss://"));
  if (supabaseOrigin?.startsWith("http://")) connectSources.push(supabaseOrigin.replace("http://", "ws://"));

  const directives = [
    "default-src 'self'",
    `script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${isDevelopment ? " 'unsafe-eval'" : ""}`,
    "style-src 'self' 'nonce-" + nonce + "'",
    "img-src 'self' blob: data:",
    "font-src 'self' data:",
    "connect-src " + connectSources.join(" "),
    "media-src 'self'",
    "worker-src 'self' blob:",
    "manifest-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
  ];
  if (!isDevelopment) directives.push("upgrade-insecure-requests");
  return directives.join("; ");
}
