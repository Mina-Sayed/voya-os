"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import type { WhatsAppActionState } from "@/features/whatsapp/whatsapp-inbox-page";
import { parseWhatsappPropertyConfirmation } from "@/lib/whatsapp/whatsapp-property-confirmation";
import { createServiceRoleSupabaseClient, createServerSupabaseClient } from "@/lib/supabase/server-auth";

const value = (formData: FormData, key: string) => {
  const raw = formData.get(key);
  return typeof raw === "string" ? raw.trim() : null;
};

function mapError(error: { code?: string | null }, deniedMessage: string, invalidMessage: string): WhatsAppActionState {
  if (error.code === "42501") return { status: "denied", message: deniedMessage };
  if (["22003", "22008", "22023", "22P02", "23503", "23505", "23514", "23P01", "40001"].includes(error.code ?? "")) return { status: "invalid", message: invalidMessage };
  return { status: "retry", message: "تعذر حفظ التغيير الآن. حاول مرة أخرى." };
}

// Mirrors the database-owned cap enforced by register_property_image_v1
// (supabase/migrations/20260813000100_property_inventory_v1.sql): at most 20
// active images per property. The confirmation must fail closed before any
// inventory write when the incoming conversation images no longer fit,
// otherwise the 21st registration aborts the flow after partial writes and
// every retry collides with the same cap.
const MAX_CONFIRMATION_IMAGES = 20;

type ConfirmableConversationImage = Readonly<{
  id: string;
  storagePath: string;
  mimeHint: string;
}>;

function confirmableConversationImages(items: unknown): ConfirmableConversationImage[] {
  if (!Array.isArray(items)) return [];
  const images: ConfirmableConversationImage[] = [];
  for (const item of items) {
    if (typeof item !== "object" || item === null || Array.isArray(item)) continue;
    const image = item as Record<string, unknown>;
    if (image.message_type !== "image" || image.media_status !== "stored" || typeof image.id !== "string" || image.media_storage_bucket !== "ai-intake" || typeof image.media_storage_path !== "string" || typeof image.media_mime_hint !== "string") continue;
    images.push({ id: image.id, storagePath: image.media_storage_path, mimeHint: image.media_mime_hint });
  }
  return images;
}

export async function createWhatsappChannelAction(
  _previousState: WhatsAppActionState,
  formData: FormData,
): Promise<WhatsAppActionState> {
  const provider = value(formData, "provider");
  const externalChannelId = value(formData, "external_channel_id");
  const displayName = value(formData, "display_name");
  const requestId = randomUUID();
  if (!provider || !externalChannelId || !displayName) return { status: "invalid", message: "أكمل تعريف القناة قبل الحفظ." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership || !["owner", "manager"].includes(membership.role)) return { status: "denied", message: "إضافة القنوات متاحة لمالك المؤسسة والمدير فقط." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_whatsapp_channel", {
      p_organization_id: membership.organizationId,
      p_provider: provider,
      p_external_channel_id: externalChannelId,
      p_display_name: displayName,
      p_request_id: requestId,
    });
    if (error) {
      const result = mapError(error, "لا تملك صلاحية إضافة قناة.", "تحقق من بيانات القناة أو وجود قناة مكررة.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.whatsapp.channel.create", error, requestId);
      return result;
    }
    revalidatePath("/workspace/whatsapp");
    return { status: "success", message: "تم حفظ تعريف القناة. الإرسال الخارجي ما زال متوقفاً حتى تفعيل worker موثوق." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.whatsapp.channel.create", error, requestId);
    return { status: "retry", message: "تعذر حفظ القناة الآن." };
  }
}

export async function createWhatsappMessageAction(
  _previousState: WhatsAppActionState,
  formData: FormData,
): Promise<WhatsAppActionState> {
  const conversationId = value(formData, "conversation_id");
  const bodyText = value(formData, "body_text");
  const idempotencyKey = value(formData, "idempotency_key");
  const requestId = randomUUID();
  if (!conversationId || !bodyText || !idempotencyKey) return { status: "invalid", message: "اكتب الرد قبل تسجيله." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("create_whatsapp_message", {
      p_organization_id: membership.organizationId,
      p_conversation_id: conversationId,
      p_body_text: bodyText,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = mapError(error, "لا تملك صلاحية الرد على هذه المحادثة.", "تحقق من المحادثة أو نص الرد.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.whatsapp.message.create", error, requestId);
      return result;
    }
    revalidatePath("/workspace/whatsapp");
    return { status: "success", message: "تم تسجيل الرد في قائمة الإرسال؛ لم يتم ادعاء تسليمه بعد." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.whatsapp.message.create", error, requestId);
    return { status: "retry", message: "تعذر تسجيل الرد الآن." };
  }
}

export async function addWhatsappNoteAction(
  _previousState: WhatsAppActionState,
  formData: FormData,
): Promise<WhatsAppActionState> {
  const conversationId = value(formData, "conversation_id");
  const noteText = value(formData, "note_text");
  const idempotencyKey = value(formData, "idempotency_key");
  const requestId = randomUUID();
  if (!conversationId || !noteText || !idempotencyKey) return { status: "invalid", message: "اكتب الملاحظة قبل حفظها." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("add_whatsapp_internal_note", {
      p_organization_id: membership.organizationId,
      p_conversation_id: conversationId,
      p_note_text: noteText,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      const result = mapError(error, "لا تملك صلاحية إضافة ملاحظة.", "تحقق من المحادثة ونص الملاحظة.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.whatsapp.note.create", error, requestId);
      return result;
    }
    revalidatePath("/workspace/whatsapp");
    return { status: "success", message: "تم حفظ الملاحظة الداخلية." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.whatsapp.note.create", error, requestId);
    return { status: "retry", message: "تعذر حفظ الملاحظة الآن." };
  }
}

export async function setWhatsappAiEnabledAction(
  _previousState: WhatsAppActionState,
  formData: FormData,
): Promise<WhatsAppActionState> {
  const conversationId = value(formData, "conversation_id");
  const enabledValue = value(formData, "enabled");
  const enabled = enabledValue === "true" ? true : enabledValue === "false" ? false : null;
  const requestId = randomUUID();
  if (!conversationId || enabled === null) return { status: "invalid", message: "حالة الذكاء الاصطناعي غير صالحة." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership || !["owner", "manager", "sales_agent", "operations"].includes(membership.role)) {
      return { status: "denied", message: "لا تملك صلاحية تغيير وضع المحادثة." };
    }
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("set_whatsapp_ai_enabled_v1", {
      p_organization_id: membership.organizationId,
      p_conversation_id: conversationId,
      p_enabled: enabled,
      p_request_id: requestId,
    });
    if (error) {
      const result = mapError(error, "لا تملك صلاحية تغيير وضع المحادثة.", "المحادثة مغلقة أو لم تعد متاحة.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.whatsapp.ai.toggle", error, requestId);
      return result;
    }
    revalidatePath("/workspace/whatsapp");
    return { status: "success", message: enabled ? "تمت إعادة المحادثة إلى الذكاء الاصطناعي." : "تم تسليم المحادثة للفريق، وتوقف رد الذكاء الاصطناعي." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.whatsapp.ai.toggle", error, requestId);
    return { status: "retry", message: "تعذر تغيير وضع المحادثة الآن." };
  }
}

function imageExtension(mimeType: string): string | null {
  if (mimeType === "image/jpeg") return "jpg";
  if (mimeType === "image/png") return "png";
  if (mimeType === "image/webp") return "webp";
  return null;
}

function confirmationError(error: { code?: string | null }, invalidMessage: string): WhatsAppActionState {
  if (error.code === "42501") return { status: "denied", message: "لا تملك صلاحية تأكيد بيانات المالك والعقار." };
  if (["22003", "22008", "22023", "22P02", "23503", "23505", "23514", "23P01", "40001"].includes(error.code ?? "")) return { status: "invalid", message: invalidMessage };
  return { status: "retry", message: "تعذر تسجيل تأكيد العقار الآن. راجع الحالة وحاول مرة أخرى." };
}

type WhatsappPropertyConfirmationProgress = {
  attemptKey: string;
  propertyOwnerId: string | null;
  propertyId: string | null;
  ownershipPeriodId: string | null;
  commandKeys: {
    owner: string;
    property: string;
    ownership: string;
    images: Record<string, string>;
  };
  registeredImages: Record<string, string>;
};

function objectValue(input: unknown): Record<string, unknown> {
  return typeof input === "object" && input !== null && !Array.isArray(input) ? input as Record<string, unknown> : {};
}

function stringEntries(input: unknown): Record<string, string> {
  return Object.fromEntries(Object.entries(objectValue(input)).filter((entry): entry is [string, string] => typeof entry[1] === "string"));
}

function confirmationPayloadFormData(input: unknown): FormData | null {
  const payload = objectValue(input);
  const owner = objectValue(payload.owner);
  const property = objectValue(payload.property);
  if (Object.keys(owner).length === 0 || Object.keys(property).length === 0) return null;

  const formData = new FormData();
  const values: Readonly<Record<string, unknown>> = {
    owner_display_name: owner.displayName,
    owner_phone: owner.phone,
    owner_whatsapp: owner.whatsapp,
    owner_email: owner.email,
    owner_preferred_contact_method: owner.preferredContactMethod,
    owner_notes: owner.notes,
    code: property.code,
    name: property.name,
    timezone: property.timezone,
    address: property.address,
    city: property.city,
    unit_label: property.unitLabel,
    bedrooms: property.bedrooms,
    max_guests: property.maxGuests,
    operational_notes: property.operationalNotes,
    bathrooms: property.bathrooms,
    area_sqm: property.areaSqm,
    floor: property.floor,
    furnished: property.furnished,
    district: property.district,
    rent_daily: property.rentDaily,
    rent_weekly: property.rentWeekly,
    rent_monthly: property.rentMonthly,
    daily_price: property.dailyPrice,
    weekly_price: property.weeklyPrice,
    monthly_price: property.monthlyPrice,
    currency: property.currency,
    amenities: property.amenities,
    minimum_stay_nights: property.minimumStayNights,
    marketing_description: property.marketingDescription,
    ownership_start_date: payload.ownershipStartDate,
    ownership_end_date: payload.ownershipEndDate,
  };
  for (const [key, value] of Object.entries(values)) {
    if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") formData.set(key, String(value));
    else if (Array.isArray(value) && value.every((item) => typeof item === "string")) formData.set(key, value.join(", "));
  }
  return formData;
}

async function finalizeWhatsappConfirmationFailure(
  client: Awaited<ReturnType<typeof createServerSupabaseClient>>,
  organizationId: string,
  conversationId: string,
  confirmationToken: string,
  progress: WhatsappPropertyConfirmationProgress,
  errorCode: string,
  requestId: ReturnType<typeof randomUUID>,
): Promise<void> {
  try {
    const result = await client.rpc("finalize_whatsapp_property_confirmation_v1", {
      p_organization_id: organizationId,
      p_conversation_id: conversationId,
      p_confirmation_token: confirmationToken,
      p_property_owner_id: progress.propertyOwnerId,
      p_property_id: progress.propertyId,
      p_status: "partially_applied",
      p_confirmation_result: { errorCode, ...progress },
      p_request_id: requestId,
    });
    if (result.error) reportWorkspaceActionFailure("workspace.whatsapp.property.confirm.finalize", result.error, requestId);
  } catch (error) {
    reportWorkspaceActionFailure("workspace.whatsapp.property.confirm.finalize", error, requestId);
  }
}

async function canRemoveUnregisteredWhatsappPropertyImage(
  serviceClient: ReturnType<typeof createServiceRoleSupabaseClient>,
  organizationId: string,
  propertyId: string,
  storagePath: string,
  requestId: ReturnType<typeof randomUUID>,
): Promise<boolean> {
  try {
    const peer = await serviceClient
      .from("property_images")
      .select("id")
      .eq("organization_id", organizationId)
      .eq("property_id", propertyId)
      .eq("storage_path", storagePath)
      .eq("status", "active")
      .maybeSingle();
    if (peer.error) {
      reportWorkspaceActionFailure("workspace.whatsapp.property.image.cleanup_guard", peer.error, requestId);
      return false;
    }
    return !peer.data;
  } catch (error) {
    reportWorkspaceActionFailure("workspace.whatsapp.property.image.cleanup_guard", error, requestId);
    return false;
  }
}

export async function confirmWhatsappPropertyAction(
  _previousState: WhatsAppActionState,
  formData: FormData,
): Promise<WhatsAppActionState> {
  const conversationId = value(formData, "conversation_id");
  const expectedVersionValue = value(formData, "expected_version");
  const confirmationKey = value(formData, "confirmation_key");
  const expectedVersion = expectedVersionValue && /^\d+$/u.test(expectedVersionValue) ? Number(expectedVersionValue) : null;
  const parsed = parseWhatsappPropertyConfirmation(formData);
  const requestId = randomUUID();
  if (!conversationId || !confirmationKey || !expectedVersion) return { status: "invalid", message: "بيانات تأكيد العقار غير مكتملة." };
  let recoveryContext: {
    client: Awaited<ReturnType<typeof createServerSupabaseClient>>;
    organizationId: string;
    conversationId: string;
    confirmationToken: string;
    progress: WhatsappPropertyConfirmationProgress;
  } | null = null;
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership || !["owner", "manager", "operations"].includes(membership.role)) {
      return { status: "denied", message: "تأكيد المالك والعقار متاح لمدير المخزون فقط." };
    }
    const client = await createServerSupabaseClient();
    const confirmationPayload = parsed.ok ? (() => {
      const fields = parsed.value;
      return {
        owner: {
          displayName: fields.ownerDisplayName,
          phone: fields.ownerPhone,
          whatsapp: fields.ownerWhatsapp,
          email: fields.ownerEmail,
          preferredContactMethod: fields.ownerPreferredContactMethod,
          notes: fields.ownerNotes,
        },
        property: {
          code: fields.propertyCode,
          name: fields.propertyName,
          timezone: fields.timezone,
          address: fields.address,
          city: fields.city,
          unitLabel: fields.unitLabel,
          bedrooms: fields.bedrooms,
          maxGuests: fields.maxGuests,
          operationalNotes: fields.operationalNotes,
          bathrooms: fields.bathrooms,
          areaSqm: fields.areaSqm,
          floor: fields.floor,
          furnished: fields.furnished,
          district: fields.district,
          rentDaily: fields.rentDaily,
          rentWeekly: fields.rentWeekly,
          rentMonthly: fields.rentMonthly,
          dailyPrice: fields.dailyPrice,
          weeklyPrice: fields.weeklyPrice,
          monthlyPrice: fields.monthlyPrice,
          currency: fields.currency,
          amenities: fields.amenities,
          minimumStayNights: fields.minimumStayNights,
          marketingDescription: fields.marketingDescription,
        },
        ownershipStartDate: fields.ownershipStartDate,
        ownershipEndDate: fields.ownershipEndDate,
      };
    })() : {};
    const claimResult = await client.rpc("claim_whatsapp_property_confirmation_v1", {
      p_organization_id: membership.organizationId,
      p_conversation_id: conversationId,
      p_confirmation_payload: confirmationPayload,
      p_expected_version: expectedVersion,
      p_idempotency_key: confirmationKey,
      p_request_id: requestId,
    });
    if (claimResult.error) {
      const result = confirmationError(claimResult.error, "تغيرت المسودة أو لم تعد قابلة للتأكيد. أعد تحميلها.");
      if (result.status === "retry") reportWorkspaceActionFailure("workspace.whatsapp.property.confirm.claim", claimResult.error, requestId);
      return result;
    }
    const claim = ((claimResult.data ?? []) as ReadonlyArray<{
      outcome: string;
      confirmation_token: string | null;
      confirmation_payload: unknown;
      confirmation_result: unknown;
    }>)[0];
    if (!claim) return { status: "retry", message: "تعذر بدء تأكيد العقار الآن." };
    if (claim.outcome === "confirmed") return { status: "success", message: "تم تأكيد المالك والعقار وربط الصور." };
    // Partial attempts must be reclaimed by the database before the Action
    // resumes. `needs_review` remains terminal; an unknown outcome or a claim
    // held by another attempt is a retry, never permission to write inventory.
    if (claim.outcome === "partially_applied" || claim.outcome === "needs_review") {
      return { status: "invalid", message: "هذه المسودة تحتاج مراجعة بشرية قبل التأكيد. أعد تحميل الصفحة." };
    }
    if (claim.outcome !== "claimed" || !claim.confirmation_token) return { status: "retry", message: "يجري تنفيذ تأكيد هذه المسودة بالفعل. أعد تحميل الصفحة." };
    const confirmationToken = claim.confirmation_token;
    const previousResult = objectValue(claim.confirmation_result);
    const attemptKey = typeof previousResult.attemptKey === "string" ? previousResult.attemptKey : `whatsapp:${conversationId}:${confirmationKey}`;
    const previousCommandKeys = objectValue(previousResult.commandKeys);
    const progress: WhatsappPropertyConfirmationProgress = {
      attemptKey,
      propertyOwnerId: typeof previousResult.propertyOwnerId === "string" ? previousResult.propertyOwnerId : null,
      propertyId: typeof previousResult.propertyId === "string" ? previousResult.propertyId : null,
      ownershipPeriodId: typeof previousResult.ownershipPeriodId === "string" ? previousResult.ownershipPeriodId : null,
      commandKeys: {
        owner: typeof previousCommandKeys.owner === "string" ? previousCommandKeys.owner : `${attemptKey}:owner`,
        property: typeof previousCommandKeys.property === "string" ? previousCommandKeys.property : `${attemptKey}:property`,
        ownership: typeof previousCommandKeys.ownership === "string" ? previousCommandKeys.ownership : `${attemptKey}:ownership`,
        images: stringEntries(previousCommandKeys.images),
      },
      registeredImages: stringEntries(previousResult.registeredImages),
    };
    recoveryContext = {
      client,
      organizationId: membership.organizationId,
      conversationId,
      confirmationToken,
      progress,
    };
    const storedPayload = confirmationPayloadFormData(claim.confirmation_payload);
    const confirmedFields = storedPayload ? parseWhatsappPropertyConfirmation(storedPayload) : parsed;
    if (!confirmedFields.ok) {
      await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, progress, "whatsapp_confirmation_payload_invalid", requestId);
      return { status: "invalid", message: "أكمل بيانات المالك والعقار ونطاق الملكية قبل التأكيد." };
    }
    const fields = confirmedFields.value;

    // Read the conversation media before any inventory write so an
    // over-cap image set fails closed here instead of aborting mid-flow
    // after the owner/property records already exist. The dedicated
    // confirmation-media RPC keeps the service-owned message table behind
    // the tenant boundary instead of scanning full conversation payloads.
    const mediaResult = await client.rpc("list_whatsapp_confirmation_media_v1", {
      p_organization_id: membership.organizationId,
      p_conversation_id: conversationId,
    });
    if (mediaResult.error) {
      reportWorkspaceActionFailure("workspace.whatsapp.property.confirm.media_read", mediaResult.error, requestId);
      await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, progress, "whatsapp_media_read_failed", requestId);
      return { status: "retry", message: "تعذر قراءة صور المحادثة لاستكمال الربط." };
    }
    const candidateImages = confirmableConversationImages(mediaResult.data);
    let existingActiveImages = 0;
    for (const image of candidateImages) {
      progress.commandKeys.images[image.id] ??= `${attemptKey}:image:${image.id}`;
    }
    if (progress.propertyId) {
      const existingImages = await client.rpc("list_property_images_v1", { p_organization_id: membership.organizationId, p_property_id: progress.propertyId });
      if (existingImages.error || !Array.isArray(existingImages.data)) {
        await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, progress, "whatsapp_property_image_count_failed", requestId);
        return { status: "retry", message: "تعذر التحقق من صور العقار الحالية قبل الربط." };
      }
      existingActiveImages = existingImages.data.length;
      for (const image of candidateImages) {
        const extension = imageExtension(image.mimeHint);
        if (!extension) continue;
        const expectedPath = `${membership.organizationId}/${progress.propertyId}/${image.id}.${extension}`;
        const existing = existingImages.data.find((item) => objectValue(item).storage_path === expectedPath);
        const existingId = objectValue(existing).id;
        if (typeof existingId === "string") progress.registeredImages[image.id] = existingId;
        else delete progress.registeredImages[image.id];
      }
    }
    const pendingImageCount = candidateImages.filter((image) => !progress.registeredImages[image.id]).length;
    if (pendingImageCount + existingActiveImages > MAX_CONFIRMATION_IMAGES) {
      await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, progress, "whatsapp_confirmation_image_limit_exceeded", requestId);
      return { status: "invalid", message: "تعذر التأكيد: صور المحادثة مع الصور الحالية تتجاوز الحد الأقصى لصور العقار (٢٠ صورة نشطة). راجع الصور ثم أعد المحاولة." };
    }

    if (!progress.propertyOwnerId) {
      const ownerResult = await client.rpc("create_property_owner_v1", {
        p_organization_id: membership.organizationId,
        p_display_name: fields.ownerDisplayName,
        p_phone: fields.ownerPhone,
        p_whatsapp: fields.ownerWhatsapp,
        p_email: fields.ownerEmail,
        p_preferred_contact_method: fields.ownerPreferredContactMethod,
        p_notes: fields.ownerNotes,
        p_idempotency_key: progress.commandKeys.owner,
        p_request_id: requestId,
      });
      if (ownerResult.error || typeof ownerResult.data !== "string") {
        if (ownerResult.error) await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, progress, ownerResult.error.code ?? "property_owner_command_failed", requestId);
        return ownerResult.error ? confirmationError(ownerResult.error, "تعذر إنشاء سجل المالك من بيانات التأكيد.") : { status: "retry", message: "تعذر إنشاء سجل المالك الآن." };
      }
      progress.propertyOwnerId = ownerResult.data;
    }

    if (!progress.propertyId) {
      const propertyResult = await client.rpc("create_property_v1", {
        p_organization_id: membership.organizationId,
        p_code: fields.propertyCode,
        p_name: fields.propertyName,
        p_timezone: fields.timezone,
        p_address: fields.address,
        p_city: fields.city,
        p_unit_label: fields.unitLabel,
        p_bedrooms: fields.bedrooms,
        p_max_guests: fields.maxGuests,
        p_operational_notes: fields.operationalNotes,
        p_bathrooms: fields.bathrooms,
        p_area_sqm: fields.areaSqm,
        p_floor: fields.floor,
        p_furnished: fields.furnished,
        p_district: fields.district,
        p_rent_daily: fields.rentDaily,
        p_rent_weekly: fields.rentWeekly,
        p_rent_monthly: fields.rentMonthly,
        p_daily_price: fields.dailyPrice,
        p_weekly_price: fields.weeklyPrice,
        p_monthly_price: fields.monthlyPrice,
        p_currency: fields.currency,
        p_amenities: fields.amenities,
        p_minimum_stay_nights: fields.minimumStayNights,
        p_marketing_description: fields.marketingDescription,
        p_idempotency_key: progress.commandKeys.property,
        p_request_id: requestId,
      });
      if (propertyResult.error || typeof propertyResult.data !== "string") {
        if (propertyResult.error) await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, progress, propertyResult.error.code ?? "property_command_failed", requestId);
        return propertyResult.error ? confirmationError(propertyResult.error, "تعذر إنشاء سجل العقار من بيانات التأكيد.") : { status: "retry", message: "تعذر إنشاء سجل العقار الآن." };
      }
      progress.propertyId = propertyResult.data;
    }

    if (!progress.ownershipPeriodId) {
      const ownershipResult = await client.rpc("assign_property_owner_v1", {
        p_organization_id: membership.organizationId,
        p_property_id: progress.propertyId,
        p_property_owner_id: progress.propertyOwnerId,
        p_start_date: fields.ownershipStartDate,
        p_end_date: fields.ownershipEndDate,
        p_is_primary_contact: true,
        p_idempotency_key: progress.commandKeys.ownership,
        p_request_id: requestId,
      });
      if (ownershipResult.error || typeof ownershipResult.data !== "string") {
        if (ownershipResult.error) await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, progress, ownershipResult.error.code ?? "ownership_command_failed", requestId);
        return ownershipResult.error ? confirmationError(ownershipResult.error, "تعذر ربط المالك بالعقار. تحقق من نطاق الملكية.") : { status: "retry", message: "تعذر ربط المالك بالعقار الآن." };
      }
      progress.ownershipPeriodId = ownershipResult.data;
    }

    const propertyOwnerId = progress.propertyOwnerId;
    const propertyId = progress.propertyId;
    if (!propertyOwnerId || !propertyId || !progress.ownershipPeriodId) {
      await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, progress, "whatsapp_confirmation_inventory_incomplete", requestId);
      return { status: "retry", message: "تعذر استعادة بيانات المالك والعقار المحفوظة." };
    }

    const serviceClient = createServiceRoleSupabaseClient();
    for (const image of candidateImages) {
      if (progress.registeredImages[image.id]) continue;
      const extension = imageExtension(image.mimeHint);
      if (!extension) continue;
      const source = await serviceClient.storage.from("ai-intake").download(image.storagePath);
      if (source.error || !source.data) {
        await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, progress, "whatsapp_media_download_failed", requestId);
        return { status: "retry", message: "تعذر قراءة إحدى الصور الخاصة. أعد المحاولة لاحقًا." };
      }
      const targetPath = `${membership.organizationId}/${propertyId}/${image.id}.${extension}`;
      const upload = await serviceClient.storage.from("property-images").upload(targetPath, new Uint8Array(await source.data.arrayBuffer()), { contentType: image.mimeHint, upsert: true });
      if (upload.error) {
        await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, progress, "whatsapp_property_image_upload_failed", requestId);
        return { status: "retry", message: "تعذر نقل إحدى الصور إلى صور العقار." };
      }
      const registered = await client.rpc("register_property_image_v1", {
        p_organization_id: membership.organizationId,
        p_property_id: propertyId,
        p_storage_path: targetPath,
        p_mime_type: image.mimeHint,
        p_byte_size: source.data.size,
        p_width_px: null,
        p_height_px: null,
        p_idempotency_key: progress.commandKeys.images[image.id],
        p_request_id: requestId,
      });
      if (registered.error || typeof registered.data !== "string") {
        if (await canRemoveUnregisteredWhatsappPropertyImage(serviceClient, membership.organizationId, propertyId, targetPath, requestId)) {
          const cleanup = await serviceClient.storage.from("property-images").remove([targetPath]);
          if (cleanup.error) reportWorkspaceActionFailure("workspace.whatsapp.property.image.rollback", cleanup.error, requestId);
        }
        if (registered.error) await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, progress, registered.error.code ?? "property_image_register_failed", requestId);
        return registered.error ? confirmationError(registered.error, "تعذر تسجيل إحدى صور العقار.") : { status: "retry", message: "تعذر تسجيل إحدى صور العقار الآن." };
      }
      progress.registeredImages[image.id] = registered.data;
    }

    const finalized = await client.rpc("finalize_whatsapp_property_confirmation_v1", {
      p_organization_id: membership.organizationId,
      p_conversation_id: conversationId,
      p_confirmation_token: confirmationToken,
      p_property_owner_id: propertyOwnerId,
      p_property_id: propertyId,
      p_status: "confirmed",
      p_confirmation_result: progress,
      p_request_id: requestId,
    });
    if (finalized.error || finalized.data !== true) {
      if (finalized.error) reportWorkspaceActionFailure("workspace.whatsapp.property.confirm.finalize", finalized.error, requestId);
      await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, progress, "whatsapp_confirmation_finalize_failed", requestId);
      return { status: "retry", message: "تم حفظ البيانات لكن تعذر تسجيل حالة التأكيد. أعد المحاولة." };
    }
    revalidatePath("/workspace/whatsapp");
    revalidatePath("/workspace/properties");
    revalidatePath("/workspace/property-owners");
    return { status: "success", message: "تم تأكيد المالك والعقار وربط الصور في المخزون." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.whatsapp.property.confirm", error, requestId);
    if (recoveryContext) {
      await finalizeWhatsappConfirmationFailure(
        recoveryContext.client,
        recoveryContext.organizationId,
        recoveryContext.conversationId,
        recoveryContext.confirmationToken,
        recoveryContext.progress,
        "whatsapp_confirmation_unexpected_failure",
        requestId,
      );
    }
    return { status: "retry", message: "تعذر تأكيد المالك والعقار الآن." };
  }
}
