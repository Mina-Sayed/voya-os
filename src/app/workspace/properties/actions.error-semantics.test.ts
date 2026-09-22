import { afterEach, expect, test, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createServerClient: vi.fn(),
  createServiceClient: vi.fn(),
  loadMembership: vi.fn(),
  revalidatePath: vi.fn(),
  reportFailure: vi.fn(),
}));

vi.mock("next/cache", () => ({ revalidatePath: mocks.revalidatePath }));
vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({
  createServerSupabaseClient: mocks.createServerClient,
  createServiceRoleSupabaseClient: mocks.createServiceClient,
}));

import {
  archivePropertyAction,
  assignPropertyOwnerAction,
  createPropertyAction,
  updatePropertyAction,
} from "./actions";

function form(values: Record<string, string>) {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

const idle = { status: "idle" as const, message: "" };

afterEach(() => vi.clearAllMocks());

const createForm = (key: string) => form({
  code: "NASR-101",
  name: "شقة 101",
  timezone: "Africa/Cairo",
  idempotency_key: key,
});

test("keeps property serialization failures retryable and observable", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  const error = { code: "40001", message: "serialization failure" };
  mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error }) });

  await expect(createPropertyAction(idle, createForm("same-logical-command")))
    .resolves.toEqual({ status: "retry", message: "تعذر حفظ العقار الآن. حاول مرة أخرى." });
  expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.property.create", error, expect.any(String));
});

test("marks a property idempotency conflict invalid and requests a fresh key", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: { code: "23505" } }) });

  await expect(createPropertyAction(idle, createForm("poisoned-key")))
    .resolves.toMatchObject({ status: "invalid", resetIdempotencyKey: true });
  expect(mocks.reportFailure).not.toHaveBeenCalled();
});

test("treats archive serialization failures as retryable rather than invalid", async () => {
  mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
  const error = { code: "40001", message: "serialization failure" };
  mocks.createServerClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error }) });

  await expect(archivePropertyAction(idle, form({
    property_id: "property",
    reason: "maintenance",
    expected_version: "2",
    idempotency_key: "archive-key",
  }))).resolves.toMatchObject({ status: "retry" });
  expect(mocks.reportFailure).toHaveBeenCalledWith("workspace.property.archive", error, expect.any(String));
});

test("rejects an empty update timezone before loading tenant context", async () => {
  await expect(updatePropertyAction(idle, form({
    property_id: "property",
    code: "NASR-101",
    name: "شقة 101",
    timezone: "",
    status: "active",
    expected_version: "2",
    idempotency_key: "update-key",
  }))).resolves.toMatchObject({ status: "invalid" });
  expect(mocks.loadMembership).not.toHaveBeenCalled();
});

test("rejects impossible owner-assignment dates before loading tenant context", async () => {
  await expect(assignPropertyOwnerAction(idle, form({
    property_id: "property",
    property_owner_id: "owner",
    start_date: "2050-02-30",
    end_date: "2050-03-02",
    idempotency_key: "owner-link-key",
  }))).resolves.toMatchObject({ status: "invalid" });
  expect(mocks.loadMembership).not.toHaveBeenCalled();
});
