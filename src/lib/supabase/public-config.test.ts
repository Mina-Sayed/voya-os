import { describe, expect, it } from "vitest";
import { readSupabasePublicConfig, SupabaseConfigurationError } from "./public-config";

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
});
