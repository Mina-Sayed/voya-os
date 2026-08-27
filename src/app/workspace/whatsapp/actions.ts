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
  if (["22023", "23503", "23505", "23514"].includes(error.code ?? "")) return { status: "invalid", message: invalidMessage };
  return { status: "retry", message: "تعذر حفظ التغيير الآن. حاول مرة أخرى." };
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
  const requestId = randomUUID();
  if (!conversationId || !noteText) return { status: "invalid", message: "اكتب الملاحظة قبل حفظها." };
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return { status: "denied", message: "لا تملك مساحة عمل نشطة." };
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("add_whatsapp_internal_note", {
      p_organization_id: membership.organizationId,
      p_conversation_id: conversationId,
      p_note_text: noteText,
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
  if (["22023", "23503", "23505", "40001"].includes(error.code ?? "")) return { status: "invalid", message: invalidMessage };
  return { status: "retry", message: "تعذر تسجيل تأكيد العقار الآن. راجع الحالة وحاول مرة أخرى." };
}

async function finalizeWhatsappConfirmationFailure(
  client: Awaited<ReturnType<typeof createServerSupabaseClient>>,
  organizationId: string,
  conversationId: string,
  confirmationToken: string,
  propertyOwnerId: string | null,
  propertyId: string | null,
  errorCode: string,
  requestId: ReturnType<typeof randomUUID>,
): Promise<void> {
  const result = await client.rpc("finalize_whatsapp_property_confirmation_v1", {
    p_organization_id: organizationId,
    p_conversation_id: conversationId,
    p_confirmation_token: confirmationToken,
    p_property_owner_id: propertyOwnerId,
    p_property_id: propertyId,
    p_status: "partially_applied",
    p_confirmation_result: { errorCode, propertyOwnerId, propertyId },
    p_request_id: requestId,
  });
  if (result.error) reportWorkspaceActionFailure("workspace.whatsapp.property.confirm.finalize", result.error, requestId);
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
  if (!conversationId || !confirmationKey || !expectedVersion || !parsed.ok) {
    return { status: "invalid", message: parsed.ok ? "بيانات تأكيد العقار غير مكتملة." : "أكمل بيانات المالك والعقار ونطاق الملكية قبل التأكيد." };
  }
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership || !["owner", "manager", "operations"].includes(membership.role)) {
      return { status: "denied", message: "تأكيد المالك والعقار متاح لمدير المخزون فقط." };
    }
    const client = await createServerSupabaseClient();
    const fields = parsed.value;
    const confirmationPayload = {
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
      confirmation_result: Record<string, unknown>;
    }>)[0];
    if (!claim) return { status: "retry", message: "تعذر بدء تأكيد العقار الآن." };
    if (claim.outcome === "confirmed") return { status: "success", message: "تم تأكيد المالك والعقار وربط الصور." };
    if (claim.outcome === "in_progress" || !claim.confirmation_token) return { status: "retry", message: "يجري تنفيذ تأكيد هذه المسودة بالفعل. أعد تحميل الصفحة." };
    const confirmationToken = claim.confirmation_token;
    let propertyOwnerId: string | null = typeof claim.confirmation_result.propertyOwnerId === "string" ? claim.confirmation_result.propertyOwnerId : null;
    let propertyId: string | null = typeof claim.confirmation_result.propertyId === "string" ? claim.confirmation_result.propertyId : null;

    if (!propertyOwnerId) {
      const ownerResult = await client.rpc("create_property_owner_v1", {
        p_organization_id: membership.organizationId,
        p_display_name: fields.ownerDisplayName,
        p_phone: fields.ownerPhone,
        p_whatsapp: fields.ownerWhatsapp,
        p_email: fields.ownerEmail,
        p_preferred_contact_method: fields.ownerPreferredContactMethod,
        p_notes: fields.ownerNotes,
        p_idempotency_key: `whatsapp:${conversationId}:owner`,
        p_request_id: requestId,
      });
      if (ownerResult.error || typeof ownerResult.data !== "string") {
        if (ownerResult.error) await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, propertyOwnerId, propertyId, ownerResult.error.code ?? "property_owner_command_failed", requestId);
        return ownerResult.error ? confirmationError(ownerResult.error, "تعذر إنشاء سجل المالك من بيانات التأكيد.") : { status: "retry", message: "تعذر إنشاء سجل المالك الآن." };
      }
      propertyOwnerId = ownerResult.data;
    }

    if (!propertyId) {
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
        p_idempotency_key: `whatsapp:${conversationId}:property`,
        p_request_id: requestId,
      });
      if (propertyResult.error || typeof propertyResult.data !== "string") {
        if (propertyResult.error) await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, propertyOwnerId, propertyId, propertyResult.error.code ?? "property_command_failed", requestId);
        return propertyResult.error ? confirmationError(propertyResult.error, "تعذر إنشاء سجل العقار من بيانات التأكيد.") : { status: "retry", message: "تعذر إنشاء سجل العقار الآن." };
      }
      propertyId = propertyResult.data;
    }

    const ownershipResult = await client.rpc("assign_property_owner_v1", {
      p_organization_id: membership.organizationId,
      p_property_id: propertyId,
      p_property_owner_id: propertyOwnerId,
      p_start_date: fields.ownershipStartDate,
      p_end_date: fields.ownershipEndDate,
      p_is_primary_contact: true,
      p_idempotency_key: `whatsapp:${conversationId}:ownership`,
      p_request_id: requestId,
    });
    if (ownershipResult.error || typeof ownershipResult.data !== "string") {
      if (ownershipResult.error) await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, propertyOwnerId, propertyId, ownershipResult.error.code ?? "ownership_command_failed", requestId);
      return ownershipResult.error ? confirmationError(ownershipResult.error, "تعذر ربط المالك بالعقار. تحقق من نطاق الملكية.") : { status: "retry", message: "تعذر ربط المالك بالعقار الآن." };
    }

    const inboxResult = await client.rpc("list_whatsapp_conversations_ai_v1", { p_organization_id: membership.organizationId });
    if (inboxResult.error) {
      await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, propertyOwnerId, propertyId, "whatsapp_media_read_failed", requestId);
      return { status: "retry", message: "تم إنشاء السجلين لكن تعذر قراءة صور المحادثة لاستكمال الربط." };
    }
    const conversation = ((inboxResult.data ?? []) as ReadonlyArray<{ id: string; recent_messages: unknown }>).find((item) => item.id === conversationId);
    const recentMessages = Array.isArray(conversation?.recent_messages) ? conversation.recent_messages : [];
    const serviceClient = createServiceRoleSupabaseClient();
    for (const item of recentMessages) {
      if (typeof item !== "object" || item === null || Array.isArray(item)) continue;
      const image = item as Record<string, unknown>;
      if (image.message_type !== "image" || image.media_status !== "stored" || typeof image.id !== "string" || image.media_storage_bucket !== "ai-intake" || typeof image.media_storage_path !== "string" || typeof image.media_mime_hint !== "string") continue;
      const extension = imageExtension(image.media_mime_hint);
      if (!extension) continue;
      const source = await serviceClient.storage.from("ai-intake").download(image.media_storage_path);
      if (source.error || !source.data) {
        await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, propertyOwnerId, propertyId, "whatsapp_media_download_failed", requestId);
        return { status: "retry", message: "تعذر قراءة إحدى الصور الخاصة. أعد المحاولة لاحقًا." };
      }
      const targetPath = `${membership.organizationId}/${propertyId}/${image.id}.${extension}`;
      const upload = await serviceClient.storage.from("property-images").upload(targetPath, new Uint8Array(await source.data.arrayBuffer()), { contentType: image.media_mime_hint, upsert: true });
      if (upload.error) {
        await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, propertyOwnerId, propertyId, "whatsapp_property_image_upload_failed", requestId);
        return { status: "retry", message: "تعذر نقل إحدى الصور إلى صور العقار." };
      }
      const registered = await client.rpc("register_property_image_v1", {
        p_organization_id: membership.organizationId,
        p_property_id: propertyId,
        p_storage_path: targetPath,
        p_mime_type: image.media_mime_hint,
        p_byte_size: source.data.size,
        p_width_px: null,
        p_height_px: null,
        p_idempotency_key: `whatsapp:${conversationId}:image:${image.id}`,
        p_request_id: requestId,
      });
      if (registered.error || typeof registered.data !== "string") {
        if (registered.error) await finalizeWhatsappConfirmationFailure(client, membership.organizationId, conversationId, confirmationToken, propertyOwnerId, propertyId, registered.error.code ?? "property_image_register_failed", requestId);
        return registered.error ? confirmationError(registered.error, "تعذر تسجيل إحدى صور العقار.") : { status: "retry", message: "تعذر تسجيل إحدى صور العقار الآن." };
      }
    }

    const finalized = await client.rpc("finalize_whatsapp_property_confirmation_v1", {
      p_organization_id: membership.organizationId,
      p_conversation_id: conversationId,
      p_confirmation_token: confirmationToken,
      p_property_owner_id: propertyOwnerId,
      p_property_id: propertyId,
      p_status: "confirmed",
      p_confirmation_result: { propertyOwnerId, propertyId, ownershipPeriodId: ownershipResult.data },
      p_request_id: requestId,
    });
    if (finalized.error || finalized.data !== true) {
      if (finalized.error) reportWorkspaceActionFailure("workspace.whatsapp.property.confirm.finalize", finalized.error, requestId);
      return { status: "retry", message: "تم حفظ البيانات لكن تعذر تسجيل حالة التأكيد. أعد المحاولة." };
    }
    revalidatePath("/workspace/whatsapp");
    revalidatePath("/workspace/properties");
    revalidatePath("/workspace/property-owners");
    return { status: "success", message: "تم تأكيد المالك والعقار وربط الصور في المخزون." };
  } catch (error) {
    reportWorkspaceActionFailure("workspace.whatsapp.property.confirm", error, requestId);
    return { status: "retry", message: "تعذر تأكيد المالك والعقار الآن." };
  }
}
