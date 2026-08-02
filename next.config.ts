import type { NextConfig } from "next";
import { assertProductionPublicConfiguration } from "./src/lib/supabase/public-config";

assertProductionPublicConfiguration(process.env);

function configuredServerActionOrigins(): string[] {
  const configuredOrigin = process.env.VOYA_APP_URL?.trim();
  if (!configuredOrigin) return [];
  try {
    return [new URL(configuredOrigin).host];
  } catch {
    return [];
  }
}

const nextConfig: NextConfig = {
  experimental: {
    serverActions: {
      allowedOrigins: configuredServerActionOrigins(),
      bodySizeLimit: "1mb",
    },
  },
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "X-Frame-Options", value: "DENY" },
          {
            key: "Referrer-Policy",
            value: "strict-origin-when-cross-origin",
          },
          {
            key: "Permissions-Policy",
            value: "camera=(), geolocation=(), microphone=(), payment=()",
          },
        ],
      },
    ];
  },
};

export default nextConfig;
