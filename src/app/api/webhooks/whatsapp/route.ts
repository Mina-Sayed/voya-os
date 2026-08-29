import { NextResponse, type NextRequest } from "next/server";
import { createServiceRoleSupabaseClient } from "@/lib/supabase/server-auth";
import { parseInboundWhatsAppEvents, verifyMetaWebhookSignature } from "@/lib/whatsapp/meta-webhook";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const MAX_BODY_BYTES = 256 * 1024;

type BoundedBodyResult =
  | Readonly<{ status: "ok"; rawBody: string }>
  | Readonly<{ status: "too_large" | "read_failed" }>;

async function readBoundedBody(request: NextRequest): Promise<BoundedBodyResult> {
  const contentLength = request.headers.get("content-length");
  if (contentLength) {
    const declaredLength = Number(contentLength);
    if (Number.isSafeInteger(declaredLength) && declaredLength > MAX_BODY_BYTES) {
      return { status: "too_large" };
    }
  }

  if (!request.body) return { status: "ok", rawBody: "" };

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > MAX_BODY_BYTES) {
        await reader.cancel();
        return { status: "too_large" };
      }
      chunks.push(value);
    }
  } catch {
    return { status: "read_failed" };
  }

  const body = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { status: "ok", rawBody: new TextDecoder().decode(body) };
}

function json(body: Readonly<Record<string, unknown>>, status = 200) {
  return NextResponse.json(body, { status, headers: { "cache-control": "no-store" } });
}

export async function GET(request: NextRequest) {
  const verifyToken = process.env.WHATSAPP_VERIFY_TOKEN?.trim();
  if (!verifyToken) return json({ error: "not_configured" }, 503);
  const mode = request.nextUrl.searchParams.get("hub.mode");
  const token = request.nextUrl.searchParams.get("hub.verify_token");
  const challenge = request.nextUrl.searchParams.get("hub.challenge");
  if (mode !== "subscribe" || token !== verifyToken || !challenge || challenge.length > 256) return json({ error: "forbidden" }, 403);
  return new Response(challenge, { status: 200, headers: { "cache-control": "no-store", "content-type": "text/plain; charset=utf-8" } });
}

export async function POST(request: NextRequest) {
  const appSecret = process.env.META_WHATSAPP_APP_SECRET?.trim();
  if (!appSecret) return json({ error: "not_configured" }, 503);
  const body = await readBoundedBody(request);
  if (body.status !== "ok") {
    return body.status === "too_large"
      ? json({ error: "payload_too_large" }, 413)
      : json({ error: "invalid_payload" }, 400);
  }
  const rawBody = body.rawBody;
  if (!verifyMetaWebhookSignature(rawBody, request.headers.get("x-hub-signature-256"), appSecret)) return json({ error: "invalid_signature" }, 401);

  let payload: unknown;
  try { payload = JSON.parse(rawBody); } catch { return json({ error: "invalid_payload" }, 400); }
  const events = parseInboundWhatsAppEvents(payload);
  if (events.length === 0) return json({ accepted: true, events: 0 }, 202);

  let client: ReturnType<typeof createServiceRoleSupabaseClient>;
  try { client = createServiceRoleSupabaseClient(); } catch { return json({ error: "not_configured" }, 503); }
  try {
    for (const event of events) {
      const { error } = await client.rpc("ingest_whatsapp_webhook_event_v1", {
        p_provider: event.provider,
        p_external_channel_id: event.externalChannelId,
        p_external_conversation_key: event.externalConversationKey,
        p_event_key: event.eventKey,
        p_sender_phone: event.senderPhone,
        p_message_type: event.messageType,
        p_body_text: event.bodyText,
        p_provider_media_id: event.providerMediaId,
        p_media_mime_hint: event.mediaMimeTypeHint,
        p_caption: event.caption,
        p_received_at: event.receivedAt,
      });
      if (error) return json({ error: "ingestion_failed" }, 503);
    }
  } catch { return json({ error: "ingestion_failed" }, 503); }
  return json({ accepted: true, events: events.length }, 202);
}
