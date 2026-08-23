import { randomUUID } from "node:crypto";
import { NextResponse } from "next/server";
import { reportOperationalError } from "@/lib/observability/operational-error";
import { assertProductionPublicConfiguration } from "@/lib/supabase/public-config";
import { createServiceRoleSupabaseClient } from "@/lib/supabase/server-auth";

export const dynamic = "force-dynamic";

function healthResponse(status: number, body: Readonly<{ status: "ok" | "not_ready" }>) {
  return NextResponse.json(body, {
    status,
    headers: { "cache-control": "no-store, max-age=0", "x-content-type-options": "nosniff" },
  });
}

export async function GET() {
  if (process.env.NODE_ENV !== "production") return healthResponse(200, { status: "ok" });

  const requestId = randomUUID();
  try {
    assertProductionPublicConfiguration(process.env);
  } catch (cause) {
    reportOperationalError({ operation: "runtime.health.ready", requestId, code: "runtime_configuration_missing", outcome: "unavailable", cause });
    return healthResponse(503, { status: "not_ready" });
  }

  try {
    const client = createServiceRoleSupabaseClient();
    const { error } = await client.from("organizations").select("id").limit(1);
    if (error) throw error;
    return healthResponse(200, { status: "ok" });
  } catch (cause) {
    reportOperationalError({ operation: "runtime.health.ready", requestId, code: "runtime_dependency_unavailable", outcome: "unavailable", cause });
    return healthResponse(503, { status: "not_ready" });
  }
}
