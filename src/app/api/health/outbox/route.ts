import { NextRequest, NextResponse } from "next/server";
import { createServiceRoleSupabaseClient } from "@/lib/supabase/server-auth";
import { resolveRequestId } from "@/lib/observability/request-id";

export const dynamic = "force-dynamic";
export const runtime = "nodejs";

// Operational backlog gauge for the outbox dispatcher. This is NOT a
// readiness gate: it always answers 200 when the database is reachable,
// however large the backlog is. Alert thresholds consume these numbers
// later; they are deliberately not decided here.
// Retry policy lives in the dispatcher (MAX_ATTEMPTS + backoff, then
// fail_outbox_event moves the event to dead_letter). needs_review is the other
// terminal state (unsupported/disabled delivery). Both need an operator, so
// `dead` reports their sum for a single alert threshold.
type BacklogState = "pending" | "processing" | "retry_wait" | "completed" | "dead_letter" | "needs_review";

const COUNTED_STATES: readonly BacklogState[] = [
  "pending",
  "processing",
  "retry_wait",
  "completed",
  "dead_letter",
  "needs_review",
];

const ACTIONABLE_STATES: readonly BacklogState[] = ["pending", "retry_wait"];

const GAUGE_TIMEOUT_MS = 3_000;

// Origin-side shield for the per-hit DB fan-out below (6 counts + 1 lookup).
// Instance-local and short-lived: on serverless it bounds repeats per isolate
// without pretending to be global rate limiting. Clients still always
// revalidate (no-store); only the database is spared repeat work.
const GAUGE_TTL_MS = 20_000;

type GaugeBody = Readonly<{
  status: "ok";
  states: Record<BacklogState, number>;
  dead: number;
  oldest_actionable_age_seconds: number | null;
  checked_at: string;
}>;

let cachedGauge: { expiresAt: number; body: GaugeBody } | null = null;

function gaugeResponse(status: number, body: Readonly<Record<string, unknown>>) {
  return NextResponse.json(body, {
    status,
    headers: { "cache-control": "no-store, max-age=0", "x-content-type-options": "nosniff" },
  });
}

export async function GET(request: NextRequest) {
  const requestId = resolveRequestId(request.headers.get("x-request-id") ?? null);
  if (cachedGauge && Date.now() < cachedGauge.expiresAt) {
    return gaugeResponse(200, cachedGauge.body);
  }
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), GAUGE_TIMEOUT_MS);
  try {
    const client = createServiceRoleSupabaseClient({
      fetch: (input, init) => fetch(input, { ...init, signal: controller.signal }),
    });
    const states: Record<BacklogState, number> = {
      pending: 0,
      processing: 0,
      retry_wait: 0,
      completed: 0,
      dead_letter: 0,
      needs_review: 0,
    };
    for (const state of COUNTED_STATES) {
      const { count, error } = await client
        .from("outbox_events")
        .select("id", { count: "exact", head: true })
        .eq("state", state);
      if (error) throw error;
      states[state] = count ?? 0;
    }
    const { data: oldest, error: oldestError } = await client
      .from("outbox_events")
      .select("created_at")
      .in("state", [...ACTIONABLE_STATES])
      .order("created_at", { ascending: true })
      .limit(1)
      .maybeSingle();
    if (oldestError) throw oldestError;
    const oldestActionableAgeSeconds = oldest?.created_at
      ? Math.max(0, Math.floor((Date.now() - new Date(oldest.created_at).getTime()) / 1000))
      : null;
    const body: GaugeBody = {
      status: "ok",
      states,
      dead: states.dead_letter + states.needs_review,
      oldest_actionable_age_seconds: oldestActionableAgeSeconds,
      checked_at: new Date().toISOString(),
    };
    cachedGauge = { expiresAt: Date.now() + GAUGE_TTL_MS, body };
    return gaugeResponse(200, body);
  } catch {
    console.error(JSON.stringify({
      level: "error",
      event: "outbox_gauge_unavailable",
      request_id: requestId,
    }));
    return gaugeResponse(503, { status: "unavailable" });
  } finally {
    clearTimeout(timeoutId);
  }
}
