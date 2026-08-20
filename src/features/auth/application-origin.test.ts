import { describe, expect, it } from "vitest";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { internalApplicationUrl, resolveApplicationOrigin } from "./application-origin";

describe("resolveApplicationOrigin", () => {
  it("uses the configured HTTPS root origin in production", () => {
    expect(resolveApplicationOrigin({ environment: { NODE_ENV: "production", VOYA_APP_URL: "https://app.voya.example" }, requestUrl: "http://internal:3000/auth/callback" }).origin).toBe("https://app.voya.example");
  });

  it.each([
    ["HTTP", "http://app.voya.example"],
    ["credentials", "https://operator:password@app.voya.example"],
    ["fragment", "https://app.voya.example/#fragment"],
    ["empty fragment delimiter", "https://app.voya.example/#"],
    ["query", "https://app.voya.example/?next=/workspace"],
    ["empty query delimiter", "https://app.voya.example/?"],
    ["non-root pathname", "https://app.voya.example/application"],
  ])("rejects a production app URL with %s", (_reason, VOYA_APP_URL) => {
    expect(() => resolveApplicationOrigin({ environment: { NODE_ENV: "production", VOYA_APP_URL }, requestUrl: "http://internal:3000/auth/callback" })).toThrow(SupabaseConfigurationError);
  });

  it("uses the local request origin outside production when no app URL is configured", () => {
    expect(resolveApplicationOrigin({ environment: { NODE_ENV: "development" }, requestUrl: "http://127.0.0.1:3000/auth/callback?code=ignored" }).origin).toBe("http://127.0.0.1:3000");
  });

  it.each([["missing", undefined], ["invalid", "not a URL"]])("rejects %s production configuration", (_reason, VOYA_APP_URL) => {
    expect(() => resolveApplicationOrigin({ environment: { NODE_ENV: "production", VOYA_APP_URL }, requestUrl: "http://internal:3000/auth/callback" })).toThrow(SupabaseConfigurationError);
  });
});

describe("internalApplicationUrl", () => {
  it("builds an approved fixed internal path", () => {
    expect(internalApplicationUrl(new URL("https://app.voya.example"), "/auth/callback").toString()).toBe("https://app.voya.example/auth/callback");
  });
});
