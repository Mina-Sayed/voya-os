import { describe, expect, it } from "vitest";
import { assertProductionPublicConfiguration, readSupabasePublicConfig, SupabaseConfigurationError } from "./public-config";

describe("readSupabasePublicConfig", () => {
  it("returns the public Supabase configuration when both values are present", () => {
    expect(readSupabasePublicConfig({
      NEXT_PUBLIC_SUPABASE_URL: "https://voya.supabase.co",
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "publishable-key",
      NODE_ENV: "production",
    })).toEqual({
      url: "https://voya.supabase.co",
      publishableKey: "publishable-key",
    });
  });

  it("rejects an incomplete public configuration", () => {
    expect(() => readSupabasePublicConfig({ NEXT_PUBLIC_SUPABASE_URL: "https://voya.supabase.co" }))
      .toThrow(SupabaseConfigurationError);
  });

  it("rejects a non-HTTPS project URL in production", () => {
    expect(() => readSupabasePublicConfig({
      NEXT_PUBLIC_SUPABASE_URL: "http://voya.supabase.co",
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "publishable-key",
      NODE_ENV: "production",
    })).toThrow("HTTPS");
  });

  it("allows HTTP in production only for the dedicated authenticated local stack", () => {
    expect(readSupabasePublicConfig({
      NEXT_PUBLIC_SUPABASE_URL: "http://127.0.0.1:55321",
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "local-public-key",
      NODE_ENV: "production",
      VOYA_AUTH_E2E_LOCAL: "1",
    })).toEqual({
      url: "http://127.0.0.1:55321",
      publishableKey: "local-public-key",
    });

    for (const url of [
      "http://127.0.0.1:54321",
      "http://localhost:55321",
      "http://127.0.0.1:55321/tunnel",
    ]) {
      expect(() => readSupabasePublicConfig({
        NEXT_PUBLIC_SUPABASE_URL: url,
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "local-public-key",
        NODE_ENV: "production",
        VOYA_AUTH_E2E_LOCAL: "1",
      })).toThrow("HTTPS");
    }
  });
});

describe("assertProductionPublicConfiguration", () => {
  it("accepts a complete HTTPS deployment configuration", () => {
    expect(() => assertProductionPublicConfiguration({
      NODE_ENV: "production",
      NEXT_PUBLIC_SUPABASE_URL: "https://voya.supabase.co",
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "publishable-key",
      VOYA_APP_URL: "https://app.voya.example",
    })).not.toThrow();
  });

  it("fails the production build when public configuration is incomplete", () => {
    expect(() => assertProductionPublicConfiguration({ NODE_ENV: "production" }))
      .toThrow(SupabaseConfigurationError);
  });

  it.each([
    "http://app.voya.example",
    "https://app.voya.example/workspace",
    "https://operator:secret@app.voya.example",
    "https://app.voya.example/?next=/workspace",
  ])("rejects unsafe production application origin %s", (VOYA_APP_URL) => {
    expect(() => assertProductionPublicConfiguration({
      NODE_ENV: "production",
      NEXT_PUBLIC_SUPABASE_URL: "https://voya.supabase.co",
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "publishable-key",
      VOYA_APP_URL,
    })).toThrow(SupabaseConfigurationError);
  });

  it("allows only the dedicated local auth E2E origin over HTTP", () => {
    expect(() => assertProductionPublicConfiguration({
      NODE_ENV: "production",
      VOYA_AUTH_E2E_LOCAL: "1",
      NEXT_PUBLIC_SUPABASE_URL: "http://127.0.0.1:55321",
      NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: "local-key",
      VOYA_APP_URL: "http://127.0.0.1:3102",
    })).not.toThrow();
  });
});
