import { afterEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  createServerClient: vi.fn(),
  createServiceClient: vi.fn(),
  loadMembership: vi.fn(),
  reportFailure: vi.fn(),
  revalidatePath: vi.fn(),
}));

vi.mock("next/cache", () => ({ revalidatePath: mocks.revalidatePath }));
vi.mock("@/features/auth/workspace-context", () => ({
  loadActionWorkspaceMembership: mocks.loadMembership,
  reportWorkspaceActionFailure: mocks.reportFailure,
}));
vi.mock("@/lib/supabase/server-auth", () => ({ createServerSupabaseClient: mocks.createServerClient, createServiceRoleSupabaseClient: mocks.createServiceClient }));

import { archivePropertyAction, assignPropertyOwnerAction, createPropertyAction, updatePropertyAction, uploadPropertyImageAction } from "./actions";

function formData(values: Record<string, string>): FormData {
  const data = new FormData();
  for (const [key, value] of Object.entries(values)) data.set(key, value);
  return data;
}

const propertyFields = {
  property_id: "property",
  code: "A-101",
  name: "شقة النيل",
  timezone: "Africa/Cairo",
  address: "12 شارع النيل",
  city: "القاهرة",
  unit_label: "A-101",
  bedrooms: "2",
  max_guests: "4",
  operational_notes: "ملاحظة",
  bathrooms: "2",
  area_sqm: "90.50",
  floor: "3",
  furnished: "true",
  district: "مدينة نصر",
  rent_monthly: "true",
  monthly_price: "35000",
  currency: "EGP",
  amenities: "wifi, تكييف",
  minimum_stay_nights: "2",
  marketing_description: "شقة مفروشة",
  status: "inactive",
  expected_version: "3",
  idempotency_key: "property-update-1",
};

afterEach(() => vi.clearAllMocks());

describe("property V1 commands", () => {
  it("creates a property only after validating the tenant-owned command", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(createPropertyAction({ status: "idle", message: "" }, formData({
      code: " A-101 ", name: " شقة النيل ", timezone: "Africa/Cairo", bedrooms: "2", max_guests: "4", bathrooms: "2", area_sqm: "90.50", furnished: "true", rent_monthly: "true", monthly_price: "35000", currency: "EGP", idempotency_key: "property-create-1",
    }))).resolves.toEqual({ status: "success", message: "تمت إضافة العقار." });
    expect(rpc).toHaveBeenCalledWith("create_property_v1", expect.objectContaining({
      p_code: "A-101", p_name: "شقة النيل", p_bedrooms: 2, p_max_guests: 4, p_bathrooms: 2, p_area_sqm: 90.5, p_furnished: true, p_rent_monthly: true, p_monthly_price: 35000, p_currency: "EGP", p_organization_id: "organization",
    }));
  });

  it("rejects an incomplete update before loading workspace context", async () => {
    await expect(updatePropertyAction({ status: "idle", message: "" }, formData({ property_id: "property" })))
      .resolves.toEqual({ status: "invalid", message: "أكمل بيانات العقار قبل الحفظ." });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
  });

  it("rejects malformed furnished-rental fields before loading workspace context", async () => {
    await expect(createPropertyAction({ status: "idle", message: "" }, formData({
      code: "A-101", name: "شقة", timezone: "Africa/Cairo", area_sqm: "not-a-number", idempotency_key: "property-create-invalid",
    }))).resolves.toMatchObject({ status: "invalid" });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
  });

  it("rejects currencies and timezones outside the shared contracts before database access", async () => {
    await expect(createPropertyAction({ status: "idle", message: "" }, formData({
      code: "A-101", name: "شقة", timezone: "Factory", monthly_price: "35000", currency: "XYZ", idempotency_key: "property-contract-invalid",
    }))).resolves.toMatchObject({ status: "invalid" });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
  });

  it("sends the complete property snapshot and version to the V1 RPC", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(updatePropertyAction({ status: "idle", message: "" }, formData(propertyFields)))
      .resolves.toEqual({ status: "success", message: "تم تحديث بيانات العقار." });
    expect(rpc).toHaveBeenCalledWith("update_property_v1", expect.objectContaining({
      p_organization_id: "organization",
      p_property_id: "property",
      p_expected_version: 3,
      p_bedrooms: 2,
      p_max_guests: 4,
      p_bathrooms: 2,
      p_area_sqm: 90.5,
      p_furnished: true,
      p_rent_monthly: true,
      p_monthly_price: 35000,
      p_currency: "EGP",
      p_status: "inactive",
      p_request_id: expect.any(String),
    }));
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/properties");
  });

  it("archives a property with a required reason", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(archivePropertyAction({ status: "idle", message: "" }, formData({
      property_id: "property",
      reason: "لم يعد ضمن المخزون التشغيلي",
      expected_version: "3",
      idempotency_key: "property-archive-1",
    }))).resolves.toEqual({ status: "success", message: "تمت أرشفة العقار." });
    expect(rpc).toHaveBeenCalledWith("archive_property_v1", expect.objectContaining({
      p_property_id: "property",
      p_reason: "لم يعد ضمن المخزون التشغيلي",
      p_expected_version: 3,
    }));
  });

  it("assigns an active owner for a bounded ownership period", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });

    await expect(assignPropertyOwnerAction({ status: "idle", message: "" }, formData({
      property_id: "property",
      property_owner_id: "owner",
      start_date: "2026-08-01",
      end_date: "2027-08-01",
      is_primary_contact: "on",
      idempotency_key: "owner-period-1",
    }))).resolves.toEqual({ status: "success", message: "تم ربط المالك بالعقار." });
    expect(rpc).toHaveBeenCalledWith("assign_property_owner_v1", expect.objectContaining({
      p_property_id: "property",
      p_property_owner_id: "owner",
      p_is_primary_contact: true,
      p_request_id: expect.any(String),
    }));
    expect(mocks.revalidatePath).toHaveBeenCalledWith("/workspace/properties");
  });

  it("rejects unsupported image files before touching storage", async () => {
    const file = new File(["svg"], "floor.svg", { type: "image/svg+xml" });
    const data = formData({ property_id: "property", idempotency_key: "image-1" });
    data.set("file", file);
    await expect(uploadPropertyImageAction({ status: "idle", message: "" }, data))
      .resolves.toMatchObject({ status: "invalid" });
    expect(mocks.loadMembership).not.toHaveBeenCalled();
  });

  it("uploads a supported image through the service role and registers metadata through the user RPC", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const rpc = vi.fn().mockResolvedValue({ error: null });
    mocks.createServerClient.mockResolvedValue({ rpc });
    const upload = vi.fn().mockResolvedValue({ error: null });
    const remove = vi.fn().mockResolvedValue({ error: null });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ upload, remove }) } });
    const data = new FormData();
    data.set("property_id", "property");
    data.set("idempotency_key", "image-1");
    data.set("file", new File(["png-data"], "floor.png", { type: "image/png" }));

    await expect(uploadPropertyImageAction({ status: "idle", message: "" }, data))
      .resolves.toEqual({ status: "success", message: "تم حفظ الصورة في التخزين الخاص." });
    expect(upload).toHaveBeenCalledWith("organization/property/5717a195-5e94-8077-a2e7-547389d77108.png", expect.any(File), expect.objectContaining({ contentType: "image/png", upsert: false }));
    expect(rpc).toHaveBeenCalledWith("register_property_image_v1", expect.objectContaining({ p_organization_id: "organization", p_property_id: "property", p_mime_type: "image/png", p_byte_size: 8 }));
    expect(remove).not.toHaveBeenCalled();
  });

  it("replays image registration after a lost response using the same private object and command key", async () => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
    const registeredPaths: string[] = [];
    const rpc = vi.fn().mockImplementation(async (_name: string, params: { p_storage_path: string }) => {
      if (registeredPaths.length === 0) {
        registeredPaths.push(params.p_storage_path);
        return { error: { message: "response lost after commit" } };
      }
      if (params.p_storage_path !== registeredPaths[0]) return { error: { code: "23505", message: "same key with another path" } };
      return { error: null };
    });
    mocks.createServerClient.mockResolvedValue({ rpc });
    const upload = vi.fn()
      .mockResolvedValueOnce({ error: null })
      .mockResolvedValueOnce({ error: { code: "Duplicate", message: "object already exists" } })
      .mockResolvedValueOnce({ error: { code: "Duplicate", message: "object already exists" } });
    const download = vi.fn().mockResolvedValue({ data: new Blob(["same-image-bytes"]), error: null });
    const remove = vi.fn().mockResolvedValue({ error: null });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ upload, download, remove }) } });
    const data = new FormData();
    data.set("property_id", "property");
    data.set("idempotency_key", "image-response-lost");
    data.set("file", new File(["same-image-bytes"], "floor.png", { type: "image/png" }));

    await expect(uploadPropertyImageAction({ status: "idle", message: "" }, data)).resolves.toMatchObject({ status: "retry" });
    await expect(uploadPropertyImageAction({ status: "retry", message: "" }, data)).resolves.toMatchObject({ status: "success" });

    expect(upload).toHaveBeenCalledTimes(2);
    expect(upload.mock.calls[1]?.[0]).toBe(upload.mock.calls[0]?.[0]);
    expect(rpc.mock.calls[1]?.[1].p_storage_path).toBe(rpc.mock.calls[0]?.[1].p_storage_path);
    expect(remove).not.toHaveBeenCalled();

    const changedFile = new FormData();
    changedFile.set("property_id", "property");
    changedFile.set("idempotency_key", "image-response-lost");
    changedFile.set("file", new File(["different-image-bytes"], "floor.png", { type: "image/png" }));
    await expect(uploadPropertyImageAction({ status: "success", message: "" }, changedFile)).resolves.toMatchObject({ status: "invalid" });
    expect(rpc).toHaveBeenCalledTimes(2);
  });

  it.each([
    ["update", updatePropertyAction, propertyFields, "update_property_v1"],
    ["archive", archivePropertyAction, { property_id: "property", reason: "سبب", expected_version: "3", idempotency_key: "property-archive-2" }, "archive_property_v1"],
    ["assign", assignPropertyOwnerAction, { property_id: "property", property_owner_id: "owner", start_date: "2026-08-01", end_date: "2027-08-01", idempotency_key: "owner-period-2" }, "assign_property_owner_v1"],
  ] as const)("maps expected %s command errors without leaking provider details", async (_name, action, values, rpcName) => {
    for (const [code, expectedStatus] of [["42501", "denied"], ["22023", "invalid"], ["XX000", "retry"]] as const) {
      vi.clearAllMocks();
      mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "owner" });
      const rpcError = { code, message: "provider detail" };
      const rpc = vi.fn().mockResolvedValue({ error: rpcError });
      mocks.createServerClient.mockResolvedValue({ rpc });

      await expect(action({ status: "idle", message: "" }, formData(values))).resolves.toMatchObject({ status: expectedStatus });
      expect(rpc).toHaveBeenCalledWith(rpcName, expect.any(Object));
      if (expectedStatus === "retry") expect(mocks.reportFailure).toHaveBeenCalled();
      else expect(mocks.reportFailure).not.toHaveBeenCalled();
    }
  });

  it.each(["57014", "42501", "client-setup"])("preserves the image registered by a concurrent replay when the first attempt fails (%s)", async (failure) => {
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
    const objects = new Map<string, File>();
    const upload = vi.fn(async (path: string, file: File) => {
      if (objects.has(path)) return { error: { message: "duplicate" } };
      objects.set(path, file);
      return { error: null };
    });
    const download = vi.fn(async (path: string) => ({ data: objects.get(path), error: null }));
    const remove = vi.fn(async (paths: string[]) => {
      paths.forEach((path) => objects.delete(path));
      return { error: null };
    });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ upload, download, remove }) } });
    let signalStarted!: () => void;
    const started = new Promise<void>((resolve) => { signalStarted = resolve; });
    let failFirst!: () => void;
    let registeredPath: string | undefined;
    const successRpc = vi.fn(async (_name: string, payload: { p_storage_path: string }) => {
      registeredPath = payload.p_storage_path;
      return { error: null };
    });
    if (failure === "client-setup") {
      mocks.createServerClient.mockImplementationOnce(() => new Promise((_resolve, reject) => {
        failFirst = () => reject(new Error("client setup failed"));
        signalStarted();
      }));
    } else {
      mocks.createServerClient.mockResolvedValueOnce({ rpc: vi.fn(() => new Promise((resolve) => {
        failFirst = () => resolve({ error: { code: failure, message: "registration failed" } });
        signalStarted();
      })) });
    }
    mocks.createServerClient.mockResolvedValue({ rpc: successRpc });
    const data = formData({ property_id: "property", idempotency_key: "image-concurrent" });
    data.set("file", new File(["png-data"], "floor.png", { type: "image/png" }));
    const first = uploadPropertyImageAction({ status: "idle", message: "" }, data);
    await started;
    await expect(uploadPropertyImageAction({ status: "idle", message: "" }, data)).resolves.toMatchObject({ status: "success" });
    failFirst();
    await first;
    expect(registeredPath).toBeDefined();
    expect(objects.has(registeredPath!)).toBe(true);
    expect(remove).not.toHaveBeenCalled();
  });

  it("denies image uploads without an eligible inventory membership and retains shared objects after failed registration", async () => {
    const image = new File(["png-data"], "floor.png", { type: "image/png" });
    const deniedData = formData({ property_id: "property", idempotency_key: "image-denied" });
    deniedData.set("file", image);
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "viewer" });
    await expect(uploadPropertyImageAction({ status: "idle", message: "" }, deniedData)).resolves.toMatchObject({ status: "denied" });
    expect(mocks.createServiceClient).not.toHaveBeenCalled();

    vi.clearAllMocks();
    mocks.loadMembership.mockResolvedValue({ organizationId: "organization", role: "manager" });
    const upload = vi.fn().mockResolvedValue({ error: null });
    const remove = vi.fn().mockResolvedValue({ error: null });
    const rpc = vi.fn().mockResolvedValue({ error: { code: "23505", message: "duplicate" } });
    mocks.createServiceClient.mockReturnValue({ storage: { from: vi.fn().mockReturnValue({ upload, remove }) } });
    mocks.createServerClient.mockResolvedValue({ rpc });
    const registerData = formData({ property_id: "property", idempotency_key: "image-register" });
    registerData.set("file", image);

    await expect(uploadPropertyImageAction({ status: "idle", message: "" }, registerData)).resolves.toMatchObject({ status: "invalid" });
    expect(remove).not.toHaveBeenCalled();
  });
});
