import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMemberships: vi.fn(),
  createClient: vi.fn(),
  redirect: vi.fn((path: string) => { throw new Error(`REDIRECT:${path}`); }),
}));

vi.mock("@/features/auth/workspace-context", () => ({ loadActiveWorkspaceMemberships: mocks.loadMemberships }));
vi.mock("@/lib/supabase/server-auth", () => ({ createServerSupabaseClient: mocks.createClient }));
vi.mock("next/navigation", () => ({ redirect: mocks.redirect }));

import { createOrganizationAction } from "./actions";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";

function formData(values: Record<string, string>): FormData {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

beforeEach(() => {
  mocks.loadMemberships.mockResolvedValue({ state: "authenticated", memberships: [] });
});

afterEach(() => vi.clearAllMocks());

describe("createOrganizationAction", () => {
  it("rejects malformed onboarding input before database access", async () => {
    await expect(createOrganizationAction({ status: "idle", message: "" }, formData({ name: "x", timezone: "Africa/Cairo", default_currency: "EGP" })))
      .resolves.toEqual({ status: "invalid", message: "أدخل اسم المؤسسة والمنطقة الزمنية والعملة بشكل صحيح." });
    expect(mocks.createClient).not.toHaveBeenCalled();
  });

  it("creates the organization through the RPC and redirects to workspace", async () => {
    const rpc = vi.fn().mockResolvedValue({ data: [{ organization_id: "org" }], error: null });
    mocks.createClient.mockResolvedValue({ rpc });

    await expect(createOrganizationAction({ status: "idle", message: "" }, formData({ name: "Voya Operations", timezone: "Africa/Cairo", default_currency: "EGP" })))
      .rejects.toThrow("REDIRECT:/workspace");
    expect(rpc).toHaveBeenCalledWith("create_organization", {
      p_name: "Voya Operations",
      p_timezone: "Africa/Cairo",
      p_default_currency: "EGP",
      p_request_id: expect.any(String),
    });
  });

  it("does not create a second organization for an existing member", async () => {
    mocks.loadMemberships.mockResolvedValue({ state: "authenticated", memberships: [{ id: "membership" }] });

    await expect(createOrganizationAction({ status: "idle", message: "" }, formData({ name: "Voya Operations", timezone: "Africa/Cairo", default_currency: "EGP" })))
      .resolves.toEqual({ status: "denied", message: "لديك مؤسسة مرتبطة بالحساب بالفعل." });
    expect(mocks.createClient).not.toHaveBeenCalled();
  });

  it("denies signed-out and provider permission failures without calling the RPC", async () => {
    mocks.loadMemberships.mockResolvedValue({ state: "signed_out", memberships: [] });
    await expect(createOrganizationAction({ status: "idle", message: "" }, formData({ name: "Voya Operations", timezone: "Africa/Cairo", default_currency: "EGP" })))
      .resolves.toEqual({ status: "denied", message: "انتهت جلسة الدخول. أعد تسجيل الدخول." });
    expect(mocks.createClient).not.toHaveBeenCalled();

    mocks.loadMemberships.mockResolvedValue({ state: "authenticated", memberships: [] });
    const rpc = vi.fn().mockResolvedValue({ error: { code: "42501" } });
    mocks.createClient.mockResolvedValue({ rpc });
    await expect(createOrganizationAction({ status: "idle", message: "" }, formData({ name: "Voya Operations", timezone: "Africa/Cairo", default_currency: "EGP" })))
      .resolves.toEqual({ status: "denied", message: "لا يمكن إنشاء المؤسسة لهذا الحساب." });
  });

  it.each([
    ["22023", "invalid", "تحقق من بيانات المؤسسة."],
    ["XX000", "retry", "تعذر إنشاء المؤسسة الآن. حاول مرة أخرى."],
  ] as const)("maps create organization error %s safely", async (code, status, message) => {
    mocks.loadMemberships.mockResolvedValue({ state: "authenticated", memberships: [] });
    mocks.createClient.mockResolvedValue({ rpc: vi.fn().mockResolvedValue({ error: { code, message: "provider secret" } }) });

    await expect(createOrganizationAction({ status: "idle", message: "" }, formData({ name: "Voya Operations", timezone: "Africa/Cairo", default_currency: "EGP" })))
      .resolves.toEqual({ status, message });
  });

  it("maps dependency failures without exposing provider details", async () => {
    mocks.createClient.mockRejectedValueOnce(new SupabaseConfigurationError());
    await expect(createOrganizationAction({ status: "idle", message: "" }, formData({ name: "Voya Operations", timezone: "Africa/Cairo", default_currency: "EGP" })))
      .resolves.toEqual({ status: "retry", message: "الخدمة غير مهيأة في هذه البيئة." });

    mocks.createClient.mockRejectedValueOnce(new Error("provider secret"));
    await expect(createOrganizationAction({ status: "idle", message: "" }, formData({ name: "Voya Operations", timezone: "Africa/Cairo", default_currency: "EGP" })))
      .resolves.toEqual({ status: "retry", message: "تعذر إنشاء المؤسسة الآن. حاول مرة أخرى." });
  });
});
