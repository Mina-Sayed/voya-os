import { randomUUID } from "node:crypto";
import { reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import { createServiceRoleSupabaseClient } from "@/lib/supabase/server-auth";
import {
  hmacStayContactFingerprint,
  hmacStayRequestFingerprint,
  validateVoyaStayRequest,
} from "@/lib/stay/public-request";

export const runtime = "nodejs";

const maxRequestBytes = 8 * 1024;
const receipt = {
  status: "received",
  message: "وصل طلبك إلى فريق VOYA لمراجعته والتواصل معك. لم يتم تأكيد الحجز.",
} as const;

function json(body: unknown, status: number, extraHeaders: Record<string, string> = {}): Response {
  return Response.json(body, {
    status,
    headers: { "Cache-Control": "no-store", ...extraHeaders },
  });
}

function originIsAllowed(request: Request): boolean {
  const rawOrigin = request.headers.get("origin");
  if (!rawOrigin) return false;
  try {
    const origin = new URL(rawOrigin);
    if (origin.origin !== rawOrigin || origin.username || origin.password || origin.pathname !== "/" || origin.search || origin.hash) return false;
    const canonical = process.env.VOYA_APP_URL?.trim();
    const expectedOrigin = canonical ? new URL(canonical).origin : new URL(request.url).origin;
    return origin.origin === expectedOrigin;
  } catch {
    return false;
  }
}

async function readBoundedJson(request: Request): Promise<Readonly<{ status: "ok"; value: unknown }> | Readonly<{ status: "too_large" | "invalid" }>> {
  const rawLength = request.headers.get("content-length");
  if (rawLength !== null) {
    if (!/^\d+$/u.test(rawLength)) return { status: "invalid" };
    if (Number(rawLength) > maxRequestBytes) return { status: "too_large" };
  }
  const reader = request.body?.getReader();
  if (!reader) return { status: "invalid" };
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) break;
      size += chunk.value.byteLength;
      if (size > maxRequestBytes) {
        await reader.cancel();
        return { status: "too_large" };
      }
      chunks.push(chunk.value);
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return { status: "ok", value: JSON.parse(new TextDecoder().decode(bytes)) as unknown };
  } catch {
    return { status: "invalid" };
  } finally {
    reader.releaseLock();
  }
}

function requestConfig(value: unknown): Readonly<{ enabled: boolean; noticeUrl: string; noticeVersion: string }> | null {
  const row = Array.isArray(value) ? value[0] : value;
  if (!row || typeof row !== "object") return null;
  const config = row as { requests_enabled?: unknown; privacy_notice_url?: unknown; privacy_notice_version?: unknown };
  if (config.requests_enabled !== true || typeof config.privacy_notice_url !== "string" || typeof config.privacy_notice_version !== "string") return null;
  if (process.env.NODE_ENV === "production" && process.env.VOYA_STAY_EDGE_RATE_LIMIT_ENABLED !== "1") return null;
  try {
    const noticeUrl = new URL(config.privacy_notice_url);
    if (noticeUrl.protocol !== "https:" || !/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/u.test(config.privacy_notice_version)) return null;
    return { enabled: true, noticeUrl: noticeUrl.toString(), noticeVersion: config.privacy_notice_version };
  } catch {
    return null;
  }
}

export async function POST(request: Request): Promise<Response> {
  if (!originIsAllowed(request)) return json({ status: "error", message: "تعذر التحقق من مصدر الطلب." }, 403);
  const contentType = request.headers.get("content-type") ?? "";
  if (!/^application\/json(?:\s*;.*)?$/iu.test(contentType)) return json({ status: "error", message: "صيغة الطلب غير مدعومة." }, 415);

  const body = await readBoundedJson(request);
  if (body.status === "too_large") return json({ status: "error", message: "حجم الطلب أكبر من المسموح." }, 413);
  if (body.status !== "ok") return json({ status: "error", message: "تعذر قراءة بيانات الطلب." }, 400);
  if (typeof body.value === "object" && body.value !== null && !Array.isArray(body.value)) {
    const company = (body.value as Record<string, unknown>).company;
    if (typeof company === "string" && company.trim() !== "") return json(receipt, 202);
  }
  const guestRequest = validateVoyaStayRequest(body.value);
  if (!guestRequest) return json({ status: "error", message: "تحقق من وسيلة التواصل والتواريخ والموافقة." }, 400);

  const requestSecret = process.env.VOYA_STAY_REQUEST_HMAC_SECRET?.trim();
  if (!requestSecret || Buffer.byteLength(requestSecret, "utf8") < 32) {
    return json({ status: "error", message: "طلبات الإقامة غير مهيأة حاليًا." }, 503);
  }

  const requestId = randomUUID();
  try {
    const serviceClient = createServiceRoleSupabaseClient();
    const { data: configData, error: configError } = await serviceClient.rpc("get_voya_stay_public_request_config_v1");
    const config = configError ? null : requestConfig(configData);
    if (!config?.enabled) return json({ status: "error", message: "طلبات الإقامة غير مفعلة حاليًا." }, 503);

    const { error } = await serviceClient.rpc("capture_voya_stay_lead_v1", {
      p_slug: guestRequest.slug,
      p_guest_name: guestRequest.name,
      p_phone: guestRequest.phone,
      p_email: guestRequest.email,
      p_check_in: guestRequest.checkIn,
      p_check_out: guestRequest.checkOut,
      p_guests: guestRequest.guests,
      p_message: guestRequest.message,
      p_consent_version: config.noticeVersion,
      p_contact_consent: guestRequest.consent,
      p_contact_fingerprint: hmacStayContactFingerprint(requestSecret, guestRequest),
      p_payload_fingerprint: hmacStayRequestFingerprint(requestSecret, guestRequest, config.noticeVersion),
      p_idempotency_key: guestRequest.idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      if (error.code === "P0002") return json({ status: "error", message: "وصلت إلى الحد المؤقت لإرسال الطلبات. حاول لاحقًا." }, 429, { "Retry-After": "3600" });
      if (error.code === "22023") return json({ status: "error", message: "تعذر اعتماد بيانات الطلب. راجع الإقامة والتواريخ." }, 400);
      if (error.code === "23505") return json({ status: "error", message: "تعذر إعادة استخدام رقم الطلب ببيانات مختلفة." }, 409);
      reportWorkspaceActionFailure("voya_stay.guest_request.capture", error, requestId);
      return json({ status: "error", message: "تعذر إرسال طلبك الآن. حاول مرة أخرى." }, 503);
    }
    return json(receipt, 201);
  } catch (error) {
    reportWorkspaceActionFailure("voya_stay.guest_request.capture", error, requestId);
    return json({ status: "error", message: "تعذر إرسال طلبك الآن. حاول مرة أخرى." }, 503);
  }
}
