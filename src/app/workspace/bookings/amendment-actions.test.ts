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

import * as bookingActions from "./actions";
import type { BookingLifecycleActionState } from "@/features/bookings/bookings-page";

type LifecycleAction = (previousState: BookingLifecycleActionState, formData: FormData) => Promise<BookingLifecycleActionState>;

function form(values: Record<string, string>) {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

afterEach(() => vi.clearAllMocks());

test("exposes a server action that requests an amendment approval", async () => {
  const action = (bookingActions as unknown as Record<string, LifecycleAction>).requestBookingAmendmentAction;
  expect(action).toBeTypeOf("function");

  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
  const rpc = vi.fn().mockResolvedValue({ error: null });
  mocks.createServerClient.mockResolvedValue({ rpc });

  const result = await action({ status: "idle", message: "" }, form({
    booking_id: "booking",
    property_id: "property",
    client_id: "client",
    check_in: "2050-01-10",
    check_out: "2050-01-14",
    amount_minor: "3000000",
    currency: "EGP",
    reason: "تمديد الإقامة",
    idempotency_key: "amend-request-1",
  }));

  expect(result.status).toBe("success");
  expect(rpc).toHaveBeenCalledWith("request_booking_amendment", expect.objectContaining({
    p_organization_id: "organization",
    p_booking_id: "booking",
    p_property_id: "property",
    p_client_id: "client",
    p_check_in: "2050-01-10",
    p_check_out: "2050-01-14",
    p_amount_minor: "3000000",
    p_currency: "EGP",
    p_reason: "تمديد الإقامة",
    p_idempotency_key: "amend-request-1",
  }));
});

test("exposes a server action that executes an independently approved amendment", async () => {
  const action = (bookingActions as unknown as Record<string, LifecycleAction>).executeBookingAmendmentAction;
  expect(action).toBeTypeOf("function");

  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  const rpc = vi.fn().mockResolvedValue({ error: null });
  mocks.createServerClient.mockResolvedValue({ rpc });

  const result = await action({ status: "idle", message: "" }, form({ booking_id: "booking", idempotency_key: "amend-execute-1" }));

  expect(result.status).toBe("success");
  expect(rpc).toHaveBeenCalledWith("execute_booking_amendment", expect.objectContaining({
    p_organization_id: "organization",
    p_booking_id: "booking",
    p_idempotency_key: "amend-execute-1",
  }));
});
