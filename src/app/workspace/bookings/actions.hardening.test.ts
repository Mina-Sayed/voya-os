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

function form(values: Record<string, string>) {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

afterEach(() => vi.clearAllMocks());

const draft = (idempotencyKey: string) => form({
  property_id: "property",
  client_id: "client",
  check_in: "2050-01-10",
  check_out: "2050-01-14",
  amount_major: "2500",
  currency: "EGP",
  idempotency_key: idempotencyKey,
});

test("rejects impossible booking and amendment dates before loading tenant context", async () => {
  for (const dates of [
    { check_in: "abc", check_out: "2050-01-14" },
    { check_in: "2050-02-30", check_out: "2050-03-02" },
    { check_in: "2050-13-01", check_out: "2050-13-05" },
    { check_in: "2050-01-14", check_out: "2050-01-10" },
  ]) {
    await expect(bookingActions.createBookingDraftAction(
      { status: "idle", message: "" },
      form({ property_id: "property", client_id: "client", amount_major: "2500", currency: "EGP", idempotency_key: "bad-date", ...dates }),
    )).resolves.toMatchObject({ status: "invalid" });

    await expect(bookingActions.requestBookingAmendmentAction(
      { status: "idle", message: "" },
      form({ booking_id: "booking", property_id: "property", client_id: "client", amount_major: "30000", currency: "EGP", reason: "تمديد", idempotency_key: "bad-amend-date", ...dates }),
    )).resolves.toMatchObject({ status: "invalid" });
  }
  expect(mocks.loadMembership).not.toHaveBeenCalled();
});

test("marks an idempotency-key conflict invalid and explicitly requests a fresh key", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: { code: "23505" } }) });

  await expect(bookingActions.createBookingDraftAction(
    { status: "idle", message: "" },
    draft("poisoned-key"),
  )).resolves.toMatchObject({ status: "invalid", resetIdempotencyKey: true });

  expect(mocks.reportFailure).not.toHaveBeenCalled();
});

test("keeps serialization failures retryable so the same logical command can be replayed", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  const error = { code: "40001", message: "serialization failure" };
  mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error }) });

  await expect(bookingActions.createBookingDraftAction(
    { status: "idle", message: "" },
    draft("stable-retry-key"),
  )).resolves.toEqual({ status: "retry", message: "تعذر حفظ المسودة الآن. حاول مرة أخرى." });

  expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.booking.create", error, expect.any(String));
});

test.each(["22003", "22008", "22023", "22P02", "23503", "23514", "23P01"])(
  "maps deterministic booking SQLSTATE %s to invalid without operational noise",
  async (code) => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: { code } }) });

    await expect(bookingActions.createBookingDraftAction(
      { status: "idle", message: "" },
      draft(`draft-${code}`),
    )).resolves.toMatchObject({ status: "invalid" });

    expect(mocks.reportFailure).not.toHaveBeenCalled();
  },
);
