import { createHash, randomUUID } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { isDataEntryRole } from "@/domain/ai/data-entry-contract";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServiceRoleSupabaseClient, createServerSupabaseClient } from "@/lib/supabase/server-auth";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

const MAX_FILE_BYTES = 10 * 1024 * 1024;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;
const MIME_EXTENSIONS: Readonly<Record<string, string>> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
};

type BoundedBodyResult =
  | Readonly<{ status: "ok"; bytes: Uint8Array }>
  | Readonly<{ status: "too_large" | "read_failed" | "empty" }>;

function json(body: Readonly<Record<string, unknown>>, status: number) {
  return NextResponse.json(body, { status, headers: { "cache-control": "no-store", "x-content-type-options": "nosniff" } });
}

function stableObjectId(organizationId: string, draftId: string, idempotencyKey: string): string {
  const hex = createHash("sha256")
    .update(`${organizationId}\u0000${draftId}\u0000${idempotencyKey}`)
    .digest("hex")
    .slice(0, 32);
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}

async function readBoundedBody(request: NextRequest): Promise<BoundedBodyResult> {
  const contentLength = request.headers.get("content-length");
  if (contentLength) {
    const declaredLength = Number(contentLength);
    if (!Number.isSafeInteger(declaredLength) || declaredLength > MAX_FILE_BYTES) return { status: "too_large" };
  }
  if (!request.body) return { status: "empty" };
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      totalBytes += value.byteLength;
      if (totalBytes > MAX_FILE_BYTES) {
        await reader.cancel();
        return { status: "too_large" };
      }
      chunks.push(value);
    }
  } catch {
    return { status: "read_failed" };
  }
  if (totalBytes < 1) return { status: "empty" };
  const bytes = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return { status: "ok", bytes };
}

export async function POST(request: NextRequest) {
  const requestId = randomUUID();
  const draftId = request.nextUrl.searchParams.get("draft_id")?.trim() ?? "";
  const idempotencyKey = request.headers.get("x-idempotency-key")?.trim() ?? "";
  const mimeType = (request.headers.get("content-type")?.split(";", 1)[0] ?? "").trim().toLowerCase();
  const extension = MIME_EXTENSIONS[mimeType];
  if (!UUID_PATTERN.test(draftId) || !extension || !idempotencyKey || idempotencyKey.length > 160) return json({ error: "invalid_input" }, 400);

  let membership;
  try {
    membership = await loadActionWorkspaceMembership();
  } catch (error) {
    reportWorkspaceActionFailure("workspace.ai.data_entry.input.auth", error, requestId);
    return json({ error: "service_unavailable" }, 503);
  }
  if (!membership) return json({ error: "unauthorized" }, 401);
  if (!isDataEntryRole(membership.role)) return json({ error: "forbidden" }, 403);

  const body = await readBoundedBody(request);
  if (body.status === "too_large") return json({ error: "payload_too_large" }, 413);
  if (body.status !== "ok") return json({ error: "invalid_payload" }, 400);

  const objectId = stableObjectId(membership.organizationId, draftId, idempotencyKey);
  const storagePath = `${membership.organizationId}/${draftId}/${objectId}.${extension}`;
  const checksum = createHash("sha256").update(body.bytes).digest("hex");
  let serviceClient: ReturnType<typeof createServiceRoleSupabaseClient> | null = null;
  let uploaded = false;
  let registered = false;
  try {
    serviceClient = createServiceRoleSupabaseClient();
    const storage = serviceClient.storage.from("ai-intake");
    const uploadResult = await storage.upload(storagePath, body.bytes, { contentType: mimeType, upsert: false });
    if (uploadResult.error) {
      const existing = await storage.download(storagePath);
      if (existing.error || !existing.data) {
        reportWorkspaceActionFailure("workspace.ai.data_entry.input.upload", uploadResult.error, requestId);
        return json({ error: "storage_unavailable" }, 503);
      }
      const existingBytes = new Uint8Array(await existing.data.arrayBuffer());
      const existingChecksum = createHash("sha256").update(existingBytes).digest("hex");
      if (existingChecksum !== checksum) return json({ error: "invalid_input" }, 400);
    } else {
      uploaded = true;
    }

    const client = await createServerSupabaseClient();
    const { data, error } = await client.rpc("register_ai_data_entry_input_v1", {
      p_organization_id: membership.organizationId,
      p_draft_id: draftId,
      p_storage_path: storagePath,
      p_mime_type: mimeType,
      p_byte_size: body.bytes.byteLength,
      p_checksum_sha256: checksum,
      p_idempotency_key: idempotencyKey,
      p_request_id: requestId,
    });
    if (error) {
      if (error.code === "42501") return json({ error: "forbidden" }, 403);
      if (["22023", "23503", "23505", "40001"].includes(error.code ?? "")) return json({ error: "invalid_input" }, 400);
      reportWorkspaceActionFailure("workspace.ai.data_entry.input.register", error, requestId);
      return json({ error: "registration_failed" }, 503);
    }
    if (typeof data !== "string" || !UUID_PATTERN.test(data)) {
      reportWorkspaceActionFailure("workspace.ai.data_entry.input.register", new Error("input id missing"), requestId);
      return json({ error: "registration_failed" }, 503);
    }
    registered = true;
    return json({ input_id: data }, 201);
  } catch (error) {
    reportWorkspaceActionFailure("workspace.ai.data_entry.input", error, requestId);
    if (error instanceof SupabaseConfigurationError) return json({ error: "not_configured" }, 503);
    return json({ error: "service_unavailable" }, 503);
  } finally {
    if (uploaded && !registered && serviceClient) {
      try {
        const cleanup = await serviceClient.storage.from("ai-intake").remove([storagePath]);
        if (cleanup.error) reportWorkspaceActionFailure("workspace.ai.data_entry.input.cleanup", cleanup.error, requestId);
      } catch (cleanupError) {
        reportWorkspaceActionFailure("workspace.ai.data_entry.input.cleanup", cleanupError, requestId);
      }
    }
  }
}
