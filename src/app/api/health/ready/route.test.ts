import { afterEach, expect, test, vi } from "vitest";

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
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
  vi.clearAllMocks();
});

test("readiness validates production public configuration before probing dependencies", async () => {
  vi.stubEnv("NODE_ENV", "production");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "");
  vi.stubEnv("VOYA_APP_URL", "");
  vi.spyOn(console, "error").mockImplementation(() => undefined);
  const response = await GET();
  expect(response.status).toBe(503);
  await expect(response.json()).resolves.toEqual({ status: "not_ready" });
  expect(mocks.createServiceClient).not.toHaveBeenCalled();
});

test("readiness is healthy only when the app boundary and database are available", async () => {
  vi.stubEnv("NODE_ENV", "production");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://voya.supabase.co");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "publishable-key");
  vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");
  healthyDependency();
  const response = await GET();
  expect(response.status).toBe(200);
  await expect(response.json()).resolves.toEqual({ status: "ok" });
  expect(mocks.createServiceClient).toHaveBeenCalledTimes(1);
});
