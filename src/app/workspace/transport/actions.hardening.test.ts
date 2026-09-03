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

test("maps numeric overflow on fleet input to invalid instead of retry", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: { code: "22003", message: "integer out of range" } }) });

  await expect(createFleetVehicleAction({ status: "idle", message: "" }, form({
    display_name: "Van 1",
    vehicle_type: "van",
    registration_code: "EG-1",
    passenger_capacity: "9999999999",
    idempotency_key: "vehicle-overflow-1",
  }))).resolves.toEqual({ status: "invalid", message: "تحقق من البيانات أو رمز المركبة أو أعد إرسال نفس المحاولة دون تغيير البيانات." });
  expect(mocks.reportFailure).not.toHaveBeenCalled();
});

test("returns explicit validation feedback for an invalid transport status transition", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: { code: "22023", message: "invalid transition" } }) });

  await expect(updateTransportRequestStatusAction("request-1", "completed"))
    .resolves.toEqual({ status: "invalid", message: "لا يمكن تطبيق حالة طلب النقل المطلوبة." });
});

test("repeated vehicle submit reuses the same idempotency key (stable retry)", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
  const rpc = vi.fn().mockResolvedValue({ error: null });
  mocks.createServerClient.mockResolvedValue({ rpc });
  const values = {
    display_name: "Van 1",
    vehicle_type: "van",
    registration_code: "EG-1",
    passenger_capacity: "7",
    idempotency_key: "vehicle-attempt-1",
  };

  const first = await createFleetVehicleAction({ status: "idle", message: "" }, form(values));
  const second = await createFleetVehicleAction({ status: "idle", message: "" }, form(values));

  expect(first.status).toBe("success");
  expect(second.status).toBe("success");
  expect(rpc).toHaveBeenCalledTimes(2);
  expect(rpc).toHaveBeenNthCalledWith(1, "create_fleet_vehicle_v1", expect.objectContaining({ p_idempotency_key: "vehicle-attempt-1" }));
  expect(rpc).toHaveBeenNthCalledWith(2, "create_fleet_vehicle_v1", expect.objectContaining({ p_idempotency_key: "vehicle-attempt-1" }));
});

test("repeated driver submit reuses the same idempotency key (stable retry)", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
  const rpc = vi.fn().mockResolvedValue({ error: null });
  mocks.createServerClient.mockResolvedValue({ rpc });
  const values = { display_name: "Driver 1", phone_e164: "+201001234567", idempotency_key: "driver-attempt-1" };

  const first = await createFleetDriverAction({ status: "idle", message: "" }, form(values));
  const second = await createFleetDriverAction({ status: "idle", message: "" }, form(values));

  expect(first.status).toBe("success");
  expect(second.status).toBe("success");
  expect(rpc).toHaveBeenCalledTimes(2);
  expect(rpc).toHaveBeenNthCalledWith(1, "create_fleet_driver_v1", expect.objectContaining({ p_idempotency_key: "driver-attempt-1" }));
  expect(rpc).toHaveBeenNthCalledWith(2, "create_fleet_driver_v1", expect.objectContaining({ p_idempotency_key: "driver-attempt-1" }));
});

test("missing fleet idempotency key is invalid without calling the RPC", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  const rpc = vi.fn().mockResolvedValue({ error: null });
  mocks.createServerClient.mockResolvedValue({ rpc });

  await expect(createFleetVehicleAction({ status: "idle", message: "" }, form({
    display_name: "Van 1",
    vehicle_type: "van",
    registration_code: "EG-1",
    passenger_capacity: "7",
  }))).resolves.toEqual({ status: "invalid", message: "أكمل بيانات المركبة." });
  await expect(createFleetDriverAction({ status: "idle", message: "" }, form({
    display_name: "Driver 1",
    phone_e164: "+201001234567",
  }))).resolves.toEqual({ status: "invalid", message: "اكتب اسم السائق." });
  expect(rpc).not.toHaveBeenCalled();
});

test("idempotency key reuse with different data surfaces as invalid", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: { code: "23505", message: "idempotency key belongs to a different vehicle" } }) });

  await expect(createFleetVehicleAction({ status: "idle", message: "" }, form({
    display_name: "Van changed",
    vehicle_type: "van",
    registration_code: "EG-1",
    passenger_capacity: "7",
    idempotency_key: "vehicle-attempt-1",
  }))).resolves.toEqual({ status: "invalid", message: "تحقق من البيانات أو رمز المركبة أو أعد إرسال نفس المحاولة دون تغيير البيانات." });

  mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: { code: "23505", message: "idempotency key belongs to a different driver" } }) });
  await expect(createFleetDriverAction({ status: "idle", message: "" }, form({
    display_name: "Driver changed",
    phone_e164: "+201001234567",
    idempotency_key: "driver-attempt-1",
  }))).resolves.toEqual({ status: "invalid", message: "تحقق من الاسم أو رقم الهاتف أو أعد إرسال نفس المحاولة دون تغيير البيانات." });
});

test("fleet creation keeps the owner/manager/operations role gate", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "sales_agent" });
  const rpc = vi.fn().mockResolvedValue({ error: null });
  mocks.createServerClient.mockResolvedValue({ rpc });

  await expect(createFleetVehicleAction({ status: "idle", message: "" }, form({
    display_name: "Van 1",
    vehicle_type: "van",
    registration_code: "EG-1",
    passenger_capacity: "7",
    idempotency_key: "vehicle-attempt-1",
  }))).resolves.toEqual({ status: "denied", message: "إدارة المركبات متاحة لفريق التشغيل والمدير فقط." });
  await expect(createFleetDriverAction({ status: "idle", message: "" }, form({
    display_name: "Driver 1",
    idempotency_key: "driver-attempt-1",
  }))).resolves.toEqual({ status: "denied", message: "إدارة السائقين متاحة لفريق التشغيل والمدير فقط." });
  expect(rpc).not.toHaveBeenCalled();
});
