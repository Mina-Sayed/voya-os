import { NextResponse, type NextRequest } from "next/server";
import { createServiceRoleSupabaseClient } from "@/lib/supabase/server-auth";
import { parseOpenWaMessageEvent, verifyOpenWaSignature } from "@/lib/whatsapp/openwa-webhook";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const MAX_BODY_BYTES = 256 * 1024;

type BoundedRawBodyResult =
  | Readonly<{ status: "ok"; bytes: Uint8Array }>
  | Readonly<{ status: "too_large" | "read_failed" }>;

async function readBoundedRawBody(
  request: NextRequest,
  maximumBytes: number,
): Promise<BoundedRawBodyResult> {
  const contentLength = request.headers.get("content-length");
  if (contentLength && /^\d+$/u.test(contentLength)) {
    const declaredLength = Number(contentLength);
    if (Number.isSafeInteger(declaredLength) && declaredLength > maximumBytes) {
      return { status: "too_large" };
    }
  }

  if (!request.body) return { status: "ok", bytes: new Uint8Array() };

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > maximumBytes) {
        await reader.cancel();
        return { status: "too_large" };
      }
      chunks.push(value);
    }
  } catch {
    return { status: "read_failed" };
  }

  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { status: "ok", bytes };
}

function json(body: Readonly<Record<string, unknown>>, status = 200) {
  return NextResponse.json(body, { status, headers: { "cache-control": "no-store" } });
}

function record(value: unknown): Readonly<Record<string, unknown>> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Readonly<Record<string, unknown>>
    : null;
}

export async function POST(request: NextRequest) {
  const secret = process.env.OPENWA_WEBHOOK_SECRET?.trim();
  if (!secret) return json({ error: "not_configured" }, 503);

  const body = await readBoundedRawBody(request, MAX_BODY_BYTES);
  if (body.status !== "ok") {
    return body.status === "too_large"
      ? json({ error: "payload_too_large" }, 413)
      : json({ error: "invalid_payload" }, 400);
  }

  const signature = request.headers.get("x-openwa-signature");
  if (!verifyOpenWaSignature(body.bytes, signature, secret)) {
    return json({ error: "invalid_signature" }, 401);
  }

  let payload: unknown;
  try {
    payload = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(body.bytes));
  } catch {
    return json({ error: "invalid_payload" }, 400);
  }

  const envelope = record(payload);
  const signedIdempotencyKey = envelope?.idempotencyKey;
  const headerIdempotencyKey = request.headers.get("x-openwa-idempotency-key");
  if (typeof signedIdempotencyKey !== "string" || !headerIdempotencyKey || headerIdempotencyKey !== signedIdempotencyKey) {
    return json({ error: "invalid_idempotency_key" }, 401);
  }

  const parsed = parseOpenWaMessageEvent(payload);
  if (parsed.kind === "ignored") return json({ accepted: true, ignored: true }, 202);

  try {
    const client = createServiceRoleSupabaseClient();
    const resolution = await client.rpc("resolve_whatsapp_webhook_provider_v1", {
      p_external_channel_id: parsed.event.sessionId,
      p_preferred_provider: "openwa",
    });
    if (resolution.error || resolution.data !== "openwa") {
      return json({ error: "ingestion_failed" }, 503);
    }

    const ingestion = await client.rpc("ingest_whatsapp_openwa_event_v1", {
      p_external_channel_id: parsed.event.sessionId,
      p_chat_id: parsed.event.chatId,
      p_event_key: parsed.event.eventKey,
      p_provider_message_id: parsed.event.messageId,
      p_contact_jid: parsed.event.contactJid,
      p_contact_phone: parsed.event.contactPhone,
      p_contact_display: parsed.event.contactDisplay,
      p_direction: parsed.event.direction,
      p_message_type: parsed.event.messageType,
      p_body_text: parsed.event.bodyText,
      p_provider_media_id: parsed.event.providerMediaId,
      p_media_mime_hint: parsed.event.mediaMimeHint,
      p_caption: parsed.event.caption,
      p_received_at: parsed.event.receivedAt,
    });
    if (ingestion.error || typeof ingestion.data !== "string" || ingestion.data.length === 0) {
      return json({ error: "ingestion_failed" }, 503);
    }
  } catch {
    return json({ error: "ingestion_failed" }, 503);
  }

  return json({ accepted: true, events: 1 }, 202);
}
