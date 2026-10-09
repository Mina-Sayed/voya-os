import { NextResponse, type NextRequest } from "next/server";
import { loadActionWorkspaceMembership } from "@/features/auth/workspace-context";
import { createServiceRoleSupabaseClient, createServerSupabaseClient } from "@/lib/supabase/server-auth";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

type RouteContext = Readonly<{ params: Promise<{ messageId: string }> }>;
type MediaRow = Readonly<{
  message_id: string;
  storage_bucket: string;
  storage_path: string;
  mime_type: string;
  media_status?: string;
}>;
const MAX_MEDIA_BYTES = 10 * 1024 * 1024;

function imageSignatureMatches(mimeType: string, bytes: Uint8Array): boolean {
  if (mimeType === "image/jpeg") return bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (mimeType === "image/png") return bytes.length >= 8
    && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47
    && bytes[4] === 0x0d && bytes[5] === 0x0a && bytes[6] === 0x1a && bytes[7] === 0x0a;
  if (mimeType === "image/webp") return bytes.length >= 12
    && String.fromCharCode(...bytes.slice(0, 4)) === "RIFF"
    && String.fromCharCode(...bytes.slice(8, 12)) === "WEBP";
  return false;
}

function json(body: Readonly<Record<string, string>>, status: number) {
  return NextResponse.json(body, { status, headers: { "cache-control": "no-store", "x-content-type-options": "nosniff" } });
}

export async function GET(_request: NextRequest, context: RouteContext) {
  const { messageId } = await context.params;
  if (!messageId || messageId.length > 120) return json({ error: "not_found" }, 404);
  const membership = await loadActionWorkspaceMembership();
  if (!membership) return json({ error: "unauthorized" }, 401);

  try {
    const client = await createServerSupabaseClient();
    const { data, error } = await client.rpc("get_whatsapp_media_v1", {
      p_organization_id: membership.organizationId,
      p_message_id: messageId,
    });
    if (error) return json({ error: "media_unavailable" }, 503);
    const media = ((data ?? []) as MediaRow[]).find((row) => row.message_id === messageId);
    if (!media || media.storage_bucket !== "ai-intake" || !["image/jpeg", "image/png", "image/webp"].includes(media.mime_type)) {
      return json({ error: "not_found" }, 404);
    }
    const serviceClient = createServiceRoleSupabaseClient();
    const downloaded = await serviceClient.storage.from("ai-intake").download(media.storage_path);
    if (downloaded.error || !downloaded.data || downloaded.data.size > MAX_MEDIA_BYTES) {
      return json({ error: "media_unavailable" }, 503);
    }
    const bytes = new Uint8Array(await downloaded.data.arrayBuffer());
    if (bytes.byteLength > MAX_MEDIA_BYTES || !imageSignatureMatches(media.mime_type, bytes)) {
      return json({ error: "media_unavailable" }, 503);
    }
    return new NextResponse(bytes, {
      status: 200,
      headers: {
        "cache-control": "no-store",
        "content-type": media.mime_type,
        "content-length": String(bytes.byteLength),
        "content-disposition": "inline",
        "x-content-type-options": "nosniff",
      },
    });
  } catch {
    return json({ error: "media_unavailable" }, 503);
  }
}
