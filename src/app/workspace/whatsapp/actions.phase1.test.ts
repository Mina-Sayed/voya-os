import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  loadMembership: vi.fn(),
  createServerClient: vi.fn(),
  createServiceClient: vi.fn(),
  revalidatePath: vi.fn(),
  reportFailure: vi.fn(),
}));

vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({ createServerSupabaseClient: mocks.createServerClient, createServiceRoleSupabaseClient: mocks.createServiceClient }));
vi.mock("next/cache", () => ({ revalidatePath: mocks.revalidatePath }));

import { confirmWhatsappPropertyAction, setWhatsappAiEnabledAction } from "./actions";

afterEach(() => vi.clearAllMocks());

const idle = { status: "idle" as const, message: "" };

function formData(values: Record<string, string>) {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

const confirmationFields = {
  conversation_id: "conversation",
  expected_version: "3",
  confirmation_key: "confirmation-key",
  owner_display_name: "مالك تجريبي",
  owner_phone: "+201000000000",
  owner_whatsapp: "+201000000000",
  owner_preferred_contact_method: "whatsapp",
  code: "WA-001",
  name: "شقة واتساب",
  timezone: "Africa/Cairo",
  city: "القاهرة",
  district: "مدينة نصر",
  bedrooms: "3",
  bathrooms: "2",
  max_guests: "5",
  area_sqm: "90.50",
  floor: "3",
  furnished: "true",
  rent_monthly: "true",
  monthly_price: "35000",
  currency: "EGP",
  amenities: "wifi, تكييف",
  minimum_stay_nights: "2",
  ownership_start_date: "2026-08-27",
  ownership_end_date: "2099-12-31",
};

describe("WhatsApp AI takeover action", () => {
  it("rejects incomplete state changes before loading workspace context", async () => {
    await expect(setWhatsappAiEnabledAction(idle, formData({ conversation_id: "", enabled: "" }))).resolves.toMatchObject({ status: "invalid" });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
  });

  it("persists a human takeover through the tenant-scoped RPC", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "sales_agent" });
    const rpc = vi.fn().mockResolvedValue({ data: true, error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(setWhatsappAiEnabledAction(idle, formData({ conversation_id: "conversation", enabled: "false" }))).resolves.toMatchObject({ status: "success" });
    expect(rpc).toHaveBeenCalledWith("set_whatsapp_ai_enabled_v1", expect.objectContaining({
      p_organization_id: "organization",
      p_conversation_id: "conversation",
      p_enabled: false,
    }));
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/whatsapp");
  });

  it("maps authorization failures without logging expected denials", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "viewer" });
    await expect(setWhatsappAiEnabledAction(idle, formData({ conversation_id: "conversation", enabled: "false" }))).resolves.toMatchObject({ status: "denied" });
    expect(mocks.createServerClient).not.toHaveBeenCalled();
  });

  it("confirms the reviewed owner/property through existing commands and moves stored images", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    const rpcResults: Record<string, unknown> = {
      claim_whatsapp_property_confirmation_v1: { data: [{ outcome: "claimed", confirmation_token: "token", confirmation_result: {} }], error: null },
      create_property_owner_v1: { data: "owner-id", error: null },
      create_property_v1: { data: "property-id", error: null },
      assign_property_owner_v1: { data: "ownership-id", error: null },
      list_whatsapp_confirmation_media_v1: { data: [{ id: "message-id", message_type: "image", media_status: "stored", media_storage_bucket: "ai-intake", media_storage_path: "organization/conversation/message-id.jpg", media_mime_hint: "image/jpeg" }], error: null },
      register_property_image_v1: { data: "property-image-id", error: null },
      finalize_whatsapp_property_confirmation_v1: { data: true, error: null },
    };
    const rpc = vi.fn().mockImplementation(async (name: string) => rpcResults[name] ?? { data: null, error: { code: "XX000" } });
    mocks.createServerClient.mockResolvedValue({ rpc });
    const download = vi.fn().mockResolvedValue({ data: new Blob([new Uint8Array([0xff, 0xd8, 0xff])], { type: "image/jpeg" }), error: null });
    const upload = vi.fn().mockResolvedValue({ error: null });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ download, upload }) } });

    await expect(confirmWhatsappPropertyAction({ status: "idle", message: "" }, formData(confirmationFields)))
      .resolves.toEqual({ status: "success", message: "تم تأكيد المالك والعقار وربط الصور في المخزون." });
    expect(rpc).toHaveBeenCalledWith("list_whatsapp_confirmation_media_v1", {
      p_organization_id: "organization",
      p_conversation_id: "conversation",
    });
    expect(rpc).not.toHaveBeenCalledWith("list_whatsapp_conversations_ai_v1", expect.anything());
    expect(rpc).toHaveBeenCalledWith("create_property_owner_v1", expect.objectContaining({ p_organization_id: "organization", p_display_name: "مالك تجريبي" }));
    expect(rpc).toHaveBeenCalledWith("create_property_v1", expect.objectContaining({ p_code: "WA-001", p_bathrooms: 2, p_monthly_price: 35000, p_furnished: true }));
    expect(upload).toHaveBeenCalledWith("organization/property-id/message-id.jpg", expect.any(Uint8Array), expect.objectContaining({ contentType: "image/jpeg", upsert: true }));
    expect(rpc).toHaveBeenCalledWith("register_property_image_v1", expect.objectContaining({ p_property_id: "property-id", p_storage_path: "organization/property-id/message-id.jpg", p_mime_type: "image/jpeg" }));
    expect(rpc).toHaveBeenCalledWith("finalize_whatsapp_property_confirmation_v1", expect.objectContaining({ p_confirmation_token: "token", p_status: "confirmed", p_property_owner_id: "owner-id", p_property_id: "property-id" }));
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/properties");
  });

  it("binds confirmation sub-command keys to the draft attempt", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    const rpcResults: Record<string, unknown> = {
      claim_whatsapp_property_confirmation_v1: { data: [{ outcome: "claimed", confirmation_token: "token", confirmation_result: {} }], error: null },
      create_property_owner_v1: { data: "owner-id", error: null },
      create_property_v1: { data: "property-id", error: null },
      assign_property_owner_v1: { data: "ownership-id", error: null },
      list_whatsapp_confirmation_media_v1: { data: [], error: null },
      finalize_whatsapp_property_confirmation_v1: { data: true, error: null },
    };
    const rpc = vi.fn().mockImplementation(async (name: string) => rpcResults[name] ?? { data: null, error: { code: "XX000" } });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(confirmWhatsappPropertyAction({ status: "idle", message: "" }, formData(confirmationFields)))
      .resolves.toMatchObject({ status: "success" });
    expect(rpc).toHaveBeenCalledWith("create_property_owner_v1", expect.objectContaining({ p_idempotency_key: "whatsapp:conversation:confirmation-key:owner" }));
    expect(rpc).toHaveBeenCalledWith("create_property_v1", expect.objectContaining({ p_idempotency_key: "whatsapp:conversation:confirmation-key:property" }));
    expect(rpc).toHaveBeenCalledWith("assign_property_owner_v1", expect.objectContaining({ p_idempotency_key: "whatsapp:conversation:confirmation-key:ownership" }));
  });

  it.each([
    ["partially_applied", "invalid", "هذه المسودة تحتاج مراجعة بشرية قبل التأكيد. أعد تحميل الصفحة."],
    ["needs_review", "invalid", "هذه المسودة تحتاج مراجعة بشرية قبل التأكيد. أعد تحميل الصفحة."],
    ["in_progress", "retry", "يجري تنفيذ تأكيد هذه المسودة بالفعل. أعد تحميل الصفحة."],
    ["expired", "retry", "يجري تنفيذ تأكيد هذه المسودة بالفعل. أعد تحميل الصفحة."],
  ] as const)("maps a %s claim outcome without creating inventory", async (outcome, status, message) => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    const rpc = vi.fn().mockResolvedValue({
      data: [{ outcome, confirmation_token: "token", confirmation_result: {} }],
      error: null,
    });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(confirmWhatsappPropertyAction({ status: "idle", message: "" }, formData(confirmationFields)))
      .resolves.toEqual({ status, message });
    expect(rpc).toHaveBeenCalledTimes(1);
    expect(rpc).toHaveBeenCalledWith("claim_whatsapp_property_confirmation_v1", expect.anything());
  });

  it("fails closed before any inventory write when conversation images exceed the property cap", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    const existingImages = Array.from({ length: 20 }, (_, index) => ({ id: `existing-${index}` }));
    const rpcResults: Record<string, unknown> = {
      claim_whatsapp_property_confirmation_v1: { data: [{ outcome: "claimed", confirmation_token: "token", confirmation_result: { propertyId: "property-id", propertyOwnerId: "owner-id" } }], error: null },
      list_whatsapp_confirmation_media_v1: { data: [{ id: "message-id", message_type: "image", media_status: "stored", media_storage_bucket: "ai-intake", media_storage_path: "organization/conversation/message-id.jpg", media_mime_hint: "image/jpeg" }], error: null },
      list_property_images_v1: { data: existingImages, error: null },
      finalize_whatsapp_property_confirmation_v1: { data: true, error: null },
    };
    const rpc = vi.fn().mockImplementation(async (name: string) => rpcResults[name] ?? { data: null, error: { code: "XX000" } });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(confirmWhatsappPropertyAction({ status: "idle", message: "" }, formData(confirmationFields)))
      .resolves.toEqual({ status: "invalid", message: "تعذر التأكيد: صور المحادثة مع الصور الحالية تتجاوز الحد الأقصى لصور العقار (٢٠ صورة نشطة). راجع الصور ثم أعد المحاولة." });
    expect(rpc).not.toHaveBeenCalledWith("create_property_owner_v1", expect.anything());
    expect(rpc).not.toHaveBeenCalledWith("create_property_v1", expect.anything());
    expect(rpc).not.toHaveBeenCalledWith("register_property_image_v1", expect.anything());
    expect(rpc).toHaveBeenCalledWith("finalize_whatsapp_property_confirmation_v1", expect.objectContaining({ p_confirmation_token: "token", p_status: "partially_applied" }));
  });

  it("loads every stored image for the claimed conversation instead of the inbox projection", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    const rpcResults: Record<string, unknown> = {
      claim_whatsapp_property_confirmation_v1: { data: [{ outcome: "claimed", confirmation_token: "token", confirmation_result: {} }], error: null },
      create_property_owner_v1: { data: "owner-id", error: null },
      create_property_v1: { data: "property-id", error: null },
      assign_property_owner_v1: { data: "ownership-id", error: null },
      list_whatsapp_confirmation_media_v1: { data: [{ id: "older-image", message_type: "image", media_status: "stored", media_storage_bucket: "ai-intake", media_storage_path: "organization/conversation/older-image.jpg", media_mime_hint: "image/jpeg" }], error: null },
      register_property_image_v1: { data: "property-image-id", error: null },
      finalize_whatsapp_property_confirmation_v1: { data: true, error: null },
    };
    const rpc = vi.fn().mockImplementation(async (name: string) => rpcResults[name] ?? { data: null, error: { code: "XX000" } });
    mocks.createServerClient.mockResolvedValue({ rpc });
    const download = vi.fn().mockResolvedValue({ data: new Blob([new Uint8Array([0xff, 0xd8, 0xff])], { type: "image/jpeg" }), error: null });
    const upload = vi.fn().mockResolvedValue({ error: null });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ download, upload }) } });

    await expect(confirmWhatsappPropertyAction(idle, formData(confirmationFields))).resolves.toMatchObject({ status: "success" });
    expect(rpc).toHaveBeenCalledWith("list_whatsapp_confirmation_media_v1", {
      p_organization_id: "organization",
      p_conversation_id: "conversation",
    });
    expect(rpc).not.toHaveBeenCalledWith("list_whatsapp_conversations_ai_v1", expect.anything());
    expect(upload).toHaveBeenCalledWith("organization/property-id/older-image.jpg", expect.any(Uint8Array), expect.any(Object));
  });

  it("removes the copied property image when database registration fails", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "operations" });
    const registrationError = { code: "23514", message: "image registration rejected" };
    const rpc = vi.fn().mockImplementation(async (name: string) => {
      if (name === "claim_whatsapp_property_confirmation_v1") return { data: [{ outcome: "claimed", confirmation_token: "token", confirmation_result: {} }], error: null };
      if (name === "create_property_owner_v1") return { data: "owner-id", error: null };
      if (name === "create_property_v1") return { data: "property-id", error: null };
      if (name === "assign_property_owner_v1") return { data: "ownership-id", error: null };
      if (name === "list_whatsapp_confirmation_media_v1") return { data: [{ id: "message-id", message_type: "image", media_status: "stored", media_storage_bucket: "ai-intake", media_storage_path: "organization/conversation/message-id.jpg", media_mime_hint: "image/jpeg" }], error: null };
      if (name === "register_property_image_v1") return { data: null, error: registrationError };
      if (name === "finalize_whatsapp_property_confirmation_v1") return { data: true, error: null };
      return { data: null, error: { code: "XX000" } };
    });
    mocks.createServerClient.mockResolvedValue({ rpc });

    const download = vi.fn().mockResolvedValue({ data: new Blob([new Uint8Array([0xff, 0xd8, 0xff])], { type: "image/jpeg" }), error: null });
    const upload = vi.fn().mockResolvedValue({ error: null });
    const remove = vi.fn().mockResolvedValue({ error: null });
    const storageFrom = vi.fn().mockImplementation((bucket: string) => bucket === "ai-intake"
      ? { download }
      : { upload, remove });
    const maybeSingle = vi.fn().mockResolvedValue({ data: null, error: null });
    const from = vi.fn().mockReturnValue({
      select: vi.fn().mockReturnValue({
        eq: vi.fn().mockReturnValue({
          eq: vi.fn().mockReturnValue({
            eq: vi.fn().mockReturnValue({
              eq: vi.fn().mockReturnValue({ maybeSingle }),
            }),
          }),
        }),
      }),
    });
    mocks.createServiceClient.mockReturnValue({ from, storage: { from: storageFrom } });

    const result = await confirmWhatsappPropertyAction(idle, formData(confirmationFields));
    expect(result.status).not.toBe("success");
    expect(rpc).toHaveBeenCalledWith("list_whatsapp_confirmation_media_v1", {
      p_organization_id: "organization",
      p_conversation_id: "conversation",
    });
    expect(from).toHaveBeenCalledWith("property_images");
    expect(remove).toHaveBeenCalledWith(["organization/property-id/message-id.jpg"]);
  });
});
