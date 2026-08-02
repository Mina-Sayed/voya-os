import { describe, expect, it } from "vitest";
import { buildContentSecurityPolicy } from "./content-security-policy";

describe("content security policy", () => {
  it("builds a nonce-based production policy without unsafe script allowances", () => {
    const policy = buildContentSecurityPolicy({
      nonce: "nonce-value",
      isDevelopment: false,
      supabaseOrigin: "https://project.supabase.co",
    });

    expect(policy).toContain("script-src 'self' 'nonce-nonce-value' 'strict-dynamic'");
    expect(policy).not.toContain("unsafe-inline");
    expect(policy).not.toContain("unsafe-eval");
    expect(policy).toContain("connect-src 'self' https://project.supabase.co wss://project.supabase.co");
    expect(policy).toContain("frame-ancestors 'none'");
    expect(policy).toContain("upgrade-insecure-requests");
  });

  it("keeps local development usable without upgrade-insecure-requests", () => {
    const policy = buildContentSecurityPolicy({
      nonce: "local-nonce",
      isDevelopment: true,
      supabaseOrigin: "http://127.0.0.1:55321",
    });

    expect(policy).toContain("'unsafe-eval'");
    expect(policy).toContain("ws://127.0.0.1:55321");
    expect(policy).not.toContain("upgrade-insecure-requests");
  });
});
