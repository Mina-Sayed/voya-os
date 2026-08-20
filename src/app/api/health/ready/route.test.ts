import { afterEach, expect, test, vi } from "vitest";
import { GET } from "./route";

afterEach(() => {
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
});

test("readiness validates production public configuration", async () => {
  vi.stubEnv("NODE_ENV", "production");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "");
  vi.stubEnv("VOYA_APP_URL", "");
  vi.spyOn(console, "error").mockImplementation(() => undefined);
  const response = GET();
  expect(response.status).toBe(503);
  await expect(response.json()).resolves.toEqual({ status: "not_ready" });
});

test("readiness is healthy when the app boundary is configured", async () => {
  vi.stubEnv("NODE_ENV", "production");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://voya.supabase.co");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "publishable-key");
  vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");
  const response = GET();
  expect(response.status).toBe(200);
  await expect(response.json()).resolves.toEqual({ status: "ok" });
});
