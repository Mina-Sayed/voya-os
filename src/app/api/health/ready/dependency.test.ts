import { afterEach, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createServiceClient: vi.fn(),
}));

vi.mock("@/lib/supabase/server-auth", () => ({
  createServiceRoleSupabaseClient: mocks.createServiceClient,
}));

import { GET } from "./route";

function configureProduction() {
  vi.stubEnv("NODE_ENV", "production");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://voya.supabase.co");
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "publishable-key");
  vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key");
  vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");
}

afterEach(() => {
  vi.useRealTimers();
  vi.unstubAllEnvs();
  vi.restoreAllMocks();
  vi.clearAllMocks();
});

test("production readiness returns 503 when the database dependency cannot be reached", async () => {
  configureProduction();
  vi.spyOn(console, "error").mockImplementation(() => undefined);
  mocks.createServiceClient.mockReturnValue({
    from: vi.fn().mockReturnValue({
      select: vi.fn().mockReturnValue({
        limit: vi.fn().mockResolvedValue({ data: null, error: { code: "PGRST000", message: "unreachable" } }),
      }),
    }),
  });

  const response = await GET();

  expect(mocks.createServiceClient).toHaveBeenCalledTimes(1);
  expect(response.status).toBe(503);
  await expect(response.json()).resolves.toEqual({ status: "not_ready" });
});

test("production readiness fails closed when the database probe stalls", async () => {
  configureProduction();
  vi.useFakeTimers();
  vi.spyOn(console, "error").mockImplementation(() => undefined);
  mocks.createServiceClient.mockReturnValue({
    from: vi.fn().mockReturnValue({
      select: vi.fn().mockReturnValue({
        limit: vi.fn().mockReturnValue(new Promise(() => {})),
      }),
    }),
  });

  const responsePromise = GET();
  await vi.advanceTimersByTimeAsync(5_000);
  const response = await responsePromise;

  expect(response.status).toBe(503);
  await expect(response.json()).resolves.toEqual({ status: "not_ready" });
});

test("production readiness returns 200 only after a successful database probe", async () => {
  configureProduction();
  const limit = vi.fn().mockResolvedValue({ data: [], error: null });
  const select = vi.fn().mockReturnValue({ limit });
  const from = vi.fn().mockReturnValue({ select });
  mocks.createServiceClient.mockReturnValue({ from });

  const response = await GET();

  expect(from).toHaveBeenCalledWith("organizations");
  expect(select).toHaveBeenCalledWith("id");
  expect(limit).toHaveBeenCalledWith(1);
  expect(response.status).toBe(200);
});
