import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { SystemHealthPage, type SystemHealthData } from "@/features/health/system-health-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { readReleaseInfo } from "@/lib/release/version";

type HealthRow = Readonly<{
  database_status: SystemHealthData["databaseStatus"];
  last_worker_run_at: string | null;
  last_worker_status: SystemHealthData["lastWorkerStatus"];
  pending_outbox_count: number;
  oldest_due_event_at: string | null;
  dead_letter_count: number;
  email_failure_count: number;
  whatsapp_failure_count: number;
  ai_failure_count: number;
}>;

async function loadSystemHealth(organizationId: string): Promise<SystemHealthData> {
  const client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("get_system_health_v1", { p_organization_id: organizationId });
  if (error) throwWorkspaceOperationError("workspace.health.read", error);
  const row = (data?.[0] ?? null) as HealthRow | null;
  if (!row) throwWorkspaceOperationError("workspace.health.read", new Error("System health aggregate is empty."));
  return {
    databaseStatus: row.database_status,
    lastWorkerRunAt: row.last_worker_run_at,
    lastWorkerStatus: row.last_worker_status,
    pendingOutboxCount: Number(row.pending_outbox_count),
    oldestDueEventAt: row.oldest_due_event_at,
    deadLetterCount: Number(row.dead_letter_count),
    emailFailureCount: Number(row.email_failure_count),
    whatsappFailureCount: Number(row.whatsapp_failure_count),
    aiFailureCount: Number(row.ai_failure_count),
  };
}

export default async function SystemHealthWorkspacePage() {
  const membership = await requireWorkspaceMembership(new Set(["owner", "manager"]));
  const health = await loadSystemHealth(membership.organizationId);
  return <WorkspaceShell activeHref="/workspace/health" organizationName={membership.organizationName} role={membership.role}><SystemHealthPage health={health} release={readReleaseInfo()} /></WorkspaceShell>;
}
