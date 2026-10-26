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

function configuredVoyaStayMediaPattern() {
  const configuredUrl = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim();
  if (!configuredUrl) return [];
  try {
    const projectUrl = new URL(configuredUrl);
    const protocol = projectUrl.protocol.replace(/:$/u, "");
    if (protocol !== "https" && protocol !== "http") return [];
    return [{
      protocol: protocol as "http" | "https",
      hostname: projectUrl.hostname,
      ...(projectUrl.port ? { port: projectUrl.port } : {}),
      pathname: "/storage/v1/object/public/voya-stay-public-media/**",
    }];
  } catch {
    return [];
  }
}

const nextConfig: NextConfig = {
  images: {
    remotePatterns: configuredVoyaStayMediaPattern(),
  },
  experimental: {
    serverActions: {
      allowedOrigins: configuredServerActionOrigins(),
      // The property image action accepts files up to 10MB; leave room for
      // multipart form overhead while keeping the action-level 10MB check.
      bodySizeLimit: "11mb",
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
