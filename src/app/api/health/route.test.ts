import { afterEach, describe, expect, it, vi } from "vitest";

import { GET } from "./route";

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

describe("GET /api/health", () => {
  it("returns a non-cacheable healthy response outside production", async () => {
    vi.stubEnv("NODE_ENV", "development");

    const response = await GET();

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok" });
    expect(response.headers.get("cache-control")).toBe("no-store, max-age=0");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
  });

  it("returns not-ready without configuration details when production configuration is missing", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "");
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "");
    vi.stubEnv("VOYA_APP_URL", "");
    const write = vi.spyOn(console, "error").mockImplementation(() => undefined);

    const response = await GET();

    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ status: "not_ready" });
    expect(write).toHaveBeenCalledWith(expect.stringContaining('"code":"runtime_configuration_missing"'));
    expect(write.mock.calls.flat().join(" ")).not.toContain("SUPABASE");
  });

  it("returns healthy only after validating the complete production configuration", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://voya.supabase.co");
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "publishable-key");
    vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");

    const response = await GET();

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok" });
  });
});
