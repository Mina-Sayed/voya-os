import { NextResponse, type NextRequest } from "next/server";
import { createServiceRoleSupabaseClient } from "@/lib/supabase/server-auth";
import { parseInboundWhatsAppEvents, verifyMetaWebhookSignature } from "@/lib/whatsapp/meta-webhook";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const MAX_BODY_BYTES = 256 * 1024;

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
  const rawBody = await request.text();
  if (new TextEncoder().encode(rawBody).byteLength > MAX_BODY_BYTES) return json({ error: "payload_too_large" }, 413);
  if (!verifyMetaWebhookSignature(rawBody, request.headers.get("x-hub-signature-256"), appSecret)) return json({ error: "invalid_signature" }, 401);

  let payload: unknown;
  try { payload = JSON.parse(rawBody); } catch { return json({ error: "invalid_payload" }, 400); }
  const events = parseInboundWhatsAppEvents(payload);
  if (events.length === 0) return json({ accepted: true, events: 0 }, 202);

  let client: ReturnType<typeof createServiceRoleSupabaseClient>;
  try { client = createServiceRoleSupabaseClient(); } catch { return json({ error: "not_configured" }, 503); }
  try {
    for (const event of events) {
      const { error } = await client.rpc("ingest_whatsapp_webhook_event", {
        p_provider: event.provider,
        p_external_channel_id: event.externalChannelId,
        p_external_conversation_key: event.externalConversationKey,
        p_event_key: event.eventKey,
        p_sender_phone: event.senderPhone,
        p_body_text: event.bodyText,
      });
      if (error) return json({ error: "ingestion_failed" }, 503);
    }
  } catch { return json({ error: "ingestion_failed" }, 503); }
  return json({ accepted: true, events: events.length }, 202);
}
