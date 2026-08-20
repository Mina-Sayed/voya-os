import { NextResponse, type NextRequest } from "next/server";
import { loadActionWorkspaceMembership } from "@/features/auth/workspace-context";
import { createServiceRoleSupabaseClient, createServerSupabaseClient } from "@/lib/supabase/server-auth";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

type RouteContext = Readonly<{ params: Promise<{ propertyId: string; imageId: string }> }>;
type ImageRow = Readonly<{ id: string; storage_bucket: string; storage_path: string }>;

function json(body: Readonly<Record<string, string>>, status: number) {
  return NextResponse.json(body, { status, headers: { "cache-control": "no-store", "x-content-type-options": "nosniff" } });
}

export async function GET(_request: NextRequest, context: RouteContext) {
  const { propertyId, imageId } = await context.params;
  const membership = await loadActionWorkspaceMembership();
  if (!membership) return json({ error: "unauthorized" }, 401);

  const client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("list_property_images_v1", {
    p_organization_id: membership.organizationId,
    p_property_id: propertyId,
  });
  if (error) return json({ error: "image_unavailable" }, 503);
  const image = ((data ?? []) as ImageRow[]).find((row) => row.id === imageId);
  if (!image || image.storage_bucket !== "property-images") return json({ error: "not_found" }, 404);

  try {
    const serviceClient = createServiceRoleSupabaseClient();
    const signed = await serviceClient.storage.from(image.storage_bucket).createSignedUrl(image.storage_path, 300);
    if (signed.error || !signed.data?.signedUrl) return json({ error: "image_unavailable" }, 503);
    return NextResponse.redirect(signed.data.signedUrl, {
      status: 302,
      headers: { "cache-control": "no-store", "x-content-type-options": "nosniff" },
    });
  } catch {
    return json({ error: "image_unavailable" }, 503);
  }
}
