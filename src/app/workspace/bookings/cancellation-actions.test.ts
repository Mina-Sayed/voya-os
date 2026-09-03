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

test("exposes a server action that cancels a draft booking with a reason", async () => {
  const action = (bookingActions as unknown as Record<string, LifecycleAction>).cancelBookingDraftAction;
  expect(action).toBeTypeOf("function");

  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "sales_agent" });
  const rpc = vi.fn().mockResolvedValue({ error: null });
  mocks.createServerClient.mockResolvedValue({ rpc });

  const result = await action({ status: "idle", message: "" }, form({
    booking_id: "booking",
    reason: "طلب العميل",
    idempotency_key: "cancel-draft-1",
  }));

  expect(result.status).toBe("success");
  expect(rpc).toHaveBeenCalledWith("cancel_booking_draft", expect.objectContaining({
    p_organization_id: "organization",
    p_booking_id: "booking",
    p_reason: "طلب العميل",
    p_idempotency_key: "cancel-draft-1",
  }));
  expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/bookings");
  expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/approvals");
});

test("exposes a server action that requests cancellation approval for a confirmed booking", async () => {
  const action = (bookingActions as unknown as Record<string, LifecycleAction>).requestBookingCancellationAction;
  expect(action).toBeTypeOf("function");

  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
  const rpc = vi.fn().mockResolvedValue({ error: null });
  mocks.createServerClient.mockResolvedValue({ rpc });

  const result = await action({ status: "idle", message: "" }, form({
    booking_id: "booking",
    reason: "تعذر السفر",
    idempotency_key: "cancel-request-1",
  }));

  expect(result.status).toBe("success");
  expect(rpc).toHaveBeenCalledWith("request_booking_cancellation", expect.objectContaining({
    p_organization_id: "organization",
    p_booking_id: "booking",
    p_reason: "تعذر السفر",
    p_idempotency_key: "cancel-request-1",
  }));
});

test("exposes a server action that executes an independently approved cancellation", async () => {
  const action = (bookingActions as unknown as Record<string, LifecycleAction>).executeBookingCancellationAction;
  expect(action).toBeTypeOf("function");

  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  const rpc = vi.fn().mockResolvedValue({ error: null });
  mocks.createServerClient.mockResolvedValue({ rpc });

  const result = await action({ status: "idle", message: "" }, form({
    booking_id: "booking",
    idempotency_key: "cancel-execute-1",
  }));

  expect(result.status).toBe("success");
  expect(rpc).toHaveBeenCalledWith("execute_booking_cancellation", expect.objectContaining({
    p_organization_id: "organization",
    p_booking_id: "booking",
    p_idempotency_key: "cancel-execute-1",
  }));
});

test("denies cancellation commands without an active workspace membership", async () => {
  mocks.loadMembership.mockResolvedValue(null);
  const rpc = vi.fn();
  mocks.createServerClient.mockResolvedValue({ rpc });

  const result = await bookingActions.requestBookingCancellationAction(
    { status: "idle", message: "" },
    form({ booking_id: "booking", reason: "تعذر السفر", idempotency_key: "cancel-request-denied" }),
  );

  expect(result.status).toBe("denied");
  expect(rpc).not.toHaveBeenCalled();
});

test("maps the database role denial for cancellation requests to denied", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "sales_agent" });
  const rpc = vi.fn().mockResolvedValue({ error: { code: "42501" } });
  mocks.createServerClient.mockResolvedValue({ rpc });

  const result = await bookingActions.requestBookingCancellationAction(
    { status: "idle", message: "" },
    form({ booking_id: "booking", reason: "تعذر السفر", idempotency_key: "cancel-request-42501" }),
  );

  expect(result.status).toBe("denied");
  expect(mocks.reportFailure).not.toHaveBeenCalled();
});

test("rejects cancellation commands without a reason or idempotency key", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
  const rpc = vi.fn();
  mocks.createServerClient.mockResolvedValue({ rpc });

  const missingReason = await bookingActions.cancelBookingDraftAction(
    { status: "idle", message: "" },
    form({ booking_id: "booking", idempotency_key: "cancel-draft-no-reason" }),
  );
  const missingKey = await bookingActions.requestBookingCancellationAction(
    { status: "idle", message: "" },
    form({ booking_id: "booking", reason: "تعذر السفر" }),
  );
  const overlongReason = await bookingActions.requestBookingCancellationAction(
    { status: "idle", message: "" },
    form({ booking_id: "booking", reason: "س".repeat(1001), idempotency_key: "cancel-request-long" }),
  );

  expect(missingReason.status).toBe("invalid");
  expect(missingKey.status).toBe("invalid");
  expect(overlongReason.status).toBe("invalid");
  expect(rpc).not.toHaveBeenCalled();
});

test("maps invalid cancellation state to invalid instead of retry", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
  const rpc = vi.fn().mockResolvedValue({ error: { code: "22023" } });
  mocks.createServerClient.mockResolvedValue({ rpc });

  const result = await bookingActions.executeBookingCancellationAction(
    { status: "idle", message: "" },
    form({ booking_id: "booking", idempotency_key: "cancel-execute-invalid" }),
  );

  expect(result.status).toBe("invalid");
  expect(mocks.reportFailure).not.toHaveBeenCalled();
});

test("maps unexpected cancellation failures to retry with failure evidence", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  const rpc = vi.fn().mockResolvedValue({ error: { code: "XX000" } });
  mocks.createServerClient.mockResolvedValue({ rpc });

  const result = await bookingActions.cancelBookingDraftAction(
    { status: "idle", message: "" },
    form({ booking_id: "booking", reason: "طلب العميل", idempotency_key: "cancel-draft-retry" }),
  );

  expect(result.status).toBe("retry");
  expect(mocks.reportFailure).toHaveBeenCalled();
});
