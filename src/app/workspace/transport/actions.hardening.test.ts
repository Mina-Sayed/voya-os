import { afterEach, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createServerClient: vi.fn(),
  loadMembership: vi.fn(),
  revalidatePath: vi.fn(),
  reportFailure: vi.fn(),
}));

vi.mock("next/cache", () => ({ revalidatePath: mocks.revalidatePath }));
vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({ createServerSupabaseClient: mocks.createServerClient }));

import { createFleetDriverAction, createFleetVehicleAction, updateTransportRequestStatusAction } from "./actions";

function form(values: Record<string, string>) {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

afterEach(() => vi.clearAllMocks());

test("passes an explicit idempotency key to fleet vehicle creation", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  const rpc = vi.fn().mockResolvedValue({ error: null });
  mocks.createServerClient.mockResolvedValue({ rpc });

  const result = await createFleetVehicleAction({ status: "idle", message: "" }, form({
    display_name: "Van 1",
    vehicle_type: "van",
    registration_code: "EG-1",
    passenger_capacity: "7",
    idempotency_key: "vehicle-attempt-1",
  }));

  expect(result.status).toBe("success");
  expect(rpc).toHaveBeenCalledWith("create_fleet_vehicle_v1", expect.objectContaining({ p_idempotency_key: "vehicle-attempt-1" }));
});

test("passes an explicit idempotency key to fleet driver creation", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  const rpc = vi.fn().mockResolvedValue({ error: null });
  mocks.createServerClient.mockResolvedValue({ rpc });

  const result = await createFleetDriverAction({ status: "idle", message: "" }, form({
    display_name: "Driver 1",
    phone_e164: "+201001234567",
    idempotency_key: "driver-attempt-1",
  }));

  expect(result.status).toBe("success");
  expect(rpc).toHaveBeenCalledWith("create_fleet_driver_v1", expect.objectContaining({ p_idempotency_key: "driver-attempt-1" }));
});

test("returns explicit validation feedback for an invalid transport status transition", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: { code: "22023", message: "invalid transition" } }) });

  await expect(updateTransportRequestStatusAction("request-1", "completed"))
    .resolves.toEqual({ status: "invalid", message: "لا يمكن تطبيق حالة طلب النقل المطلوبة." });
});
