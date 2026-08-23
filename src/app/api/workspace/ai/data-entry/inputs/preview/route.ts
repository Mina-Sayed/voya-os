import { randomUUID } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { isDataEntryRole } from "@/domain/ai/data-entry-contract";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServiceRoleSupabaseClient, createServerSupabaseClient } from "@/lib/supabase/server-auth";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;

type InputRow = Readonly<{
  id: string;
  storage_bucket: string;
  storage_path: string;
  mime_type: "image/jpeg" | "image/png" | "image/webp";
  byte_size: number;
  status: "active" | "mapped" | "archived";
}>;

function json(body: Readonly<Record<string, unknown>>, status: number) {
  return NextResponse.json(body, { status, headers: { "cache-control": "no-store", "x-content-type-options": "nosniff" } });
}

export async function GET(request: NextRequest) {
  const requestId = randomUUID();
  const draftId = request.nextUrl.searchParams.get("draft_id")?.trim() ?? "";
  const inputId = request.nextUrl.searchParams.get("input_id")?.trim() ?? "";
  if (!UUID_PATTERN.test(draftId) || !UUID_PATTERN.test(inputId)) return json({ error: "invalid_input" }, 400);

  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return json({ error: "unauthorized" }, 401);
    if (!isDataEntryRole(membership.role)) return json({ error: "forbidden" }, 403);

    const client = await createServerSupabaseClient();
    const inputsResult = await client.rpc("list_ai_data_entry_inputs_v1", {
      p_organization_id: membership.organizationId,
      p_draft_id: draftId,
    });
    if (inputsResult.error) {
      if (inputsResult.error.code === "42501") return json({ error: "forbidden" }, 403);
      reportWorkspaceActionFailure("workspace.ai.data_entry.input.preview.read", inputsResult.error, requestId);
      return json({ error: "service_unavailable" }, 503);
    }

    const input = ((inputsResult.data ?? []) as InputRow[]).find((candidate) => candidate.id === inputId);
    if (!input || input.status === "archived" || input.storage_bucket !== "ai-intake") return json({ error: "not_found" }, 404);

    const serviceClient = createServiceRoleSupabaseClient();
    const download = await serviceClient.storage.from(input.storage_bucket).download(input.storage_path);
    if (download.error || !download.data) {
      reportWorkspaceActionFailure("workspace.ai.data_entry.input.preview.download", download.error ?? new Error("input preview missing"), requestId);
      return json({ error: "not_found" }, 404);
    }
    const bytes = new Uint8Array(await download.data.arrayBuffer());
    if (bytes.byteLength !== Number(input.byte_size)) {
      reportWorkspaceActionFailure("workspace.ai.data_entry.input.preview.size", new Error("input preview size mismatch"), requestId);
      return json({ error: "invalid_storage_object" }, 503);
    }

    return new Response(bytes, {
      status: 200,
      headers: {
        "cache-control": "private, no-store, max-age=0",
        "content-length": String(bytes.byteLength),
        "content-type": input.mime_type,
        "x-content-type-options": "nosniff",
      },
    });
  } catch (error) {
    reportWorkspaceActionFailure("workspace.ai.data_entry.input.preview", error, requestId);
    if (error instanceof SupabaseConfigurationError) return json({ error: "not_configured" }, 503);
    return json({ error: "service_unavailable" }, 503);
  }
}
