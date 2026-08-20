import { afterEach, expect, test, vi } from "vitest";
import { GET } from "./route";

afterEach(() => vi.unstubAllEnvs());

test("version exposes release identity without configuration secrets", async () => {
  vi.stubEnv("VOYA_RELEASE_VERSION", "v1.0.0");
  vi.stubEnv("VOYA_RELEASE_SHA", "abc123");
  vi.stubEnv("VERCEL_ENV", "staging");
  const response = GET();
  expect(response.status).toBe(200);
  await expect(response.json()).resolves.toEqual({ version: "v1.0.0", commit: "abc123", environment: "staging" });
});
