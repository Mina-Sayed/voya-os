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
    const signed = await serviceClient.storage.from("ai-intake").createSignedUrl(media.storage_path, 300);
    if (signed.error || !signed.data?.signedUrl) return json({ error: "media_unavailable" }, 503);
    return NextResponse.redirect(signed.data.signedUrl, {
      status: 302,
      headers: { "cache-control": "no-store", "x-content-type-options": "nosniff" },
    });
  } catch {
    return json({ error: "media_unavailable" }, 503);
  }
}
