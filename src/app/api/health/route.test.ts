import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({ createServiceClient: vi.fn() }));
vi.mock("@/lib/supabase/server-auth", () => ({ createServiceRoleSupabaseClient: mocks.createServiceClient }));

import { GET } from "./route";

function healthyDependency() {
  mocks.createServiceClient.mockReturnValue({
    from: vi.fn().mockReturnValue({
      select: vi.fn().mockReturnValue({
        limit: vi.fn().mockResolvedValue({ data: [], error: null }),
      }),
    }),
  });
}

afterEach(() => {
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
  vi.clearAllMocks();
});

describe("GET /api/health", () => {
  it("returns a non-cacheable healthy response outside production", async () => {
    vi.stubEnv("NODE_ENV", "development");

    const response = await GET();

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok" });
    expect(response.headers.get("cache-control")).toBe("no-store, max-age=0");
    expect(response.headers.get("x-content-type-options")).toBe("nosniff");
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
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
    expect(mocks.createServiceClient).not.toHaveBeenCalled();
  });

  it("returns healthy only after validating configuration and the database dependency", async () => {
    vi.stubEnv("NODE_ENV", "production");
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://voya.supabase.co");
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "publishable-key");
    vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");
    healthyDependency();

    const response = await GET();

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ status: "ok" });
    expect(mocks.createServiceClient).toHaveBeenCalledTimes(1);
  });
});
