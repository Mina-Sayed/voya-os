import { randomUUID } from "node:crypto";
import { isAuthSessionMissingError } from "@supabase/supabase-js";
import { cookies } from "next/headers";
import { connection } from "next/server";
import { reportOperationalError } from "@/lib/observability/operational-error";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

export const ORGANIZATION_COOKIE = "voya-organization-id";

export type WorkspaceMembership = Readonly<{
  id: string;
  organizationId: string;
  organizationName: string;
  role: string;
  status: "active" | "suspended";
}>;

export type WorkspaceContextResult =
  | Readonly<{ state: "signed_out" }>
  | Readonly<{ state: "pending" }>
  | Readonly<{ state: "selection_required"; memberships: readonly WorkspaceMembership[] }>
  | Readonly<{ state: "ready"; membership: WorkspaceMembership }>;

export type ActiveWorkspaceMembershipsResult =
  | Readonly<{ state: "signed_out" }>
  | Readonly<{ state: "authenticated"; memberships: readonly WorkspaceMembership[] }>;

export class WorkspaceDependencyError extends Error {
  readonly code: string;

  constructor(code: string, cause?: unknown) {
    super("Workspace dependency is unavailable.");
    void cause;
    this.name = "WorkspaceDependencyError";
    this.code = code;
  }

  toJSON() {
    return { name: this.name, code: this.code, message: this.message };
  }
}

export function isSignedOutUserResult(user: unknown, error: unknown): boolean {
  return user == null && (error == null || isAuthSessionMissingError(error));
}

export function isMissingSupabasePublicConfiguration(error: unknown): boolean {
  return error instanceof SupabaseConfigurationError
    && error.message === "Supabase public configuration is incomplete.";
}

export function resolveWorkspaceContext(
  memberships: readonly WorkspaceMembership[],
  selectedOrganizationId: string | null,
): WorkspaceContextResult {
  const activeMemberships = memberships.filter((membership) => membership.status === "active");
  if (activeMemberships.length === 0) return { state: "pending" };
  if (activeMemberships.length === 1) return { state: "ready", membership: activeMemberships[0] };

  const selectedMembership = activeMemberships.find(
    (membership) => membership.organizationId === selectedOrganizationId,
  );
  return selectedMembership
    ? { state: "ready", membership: selectedMembership }
    : { state: "selection_required", memberships: activeMemberships };
}

type MembershipRow = Readonly<{
  id: string;
  organization_id: string;
  role: string;
  status: "active" | "suspended";
  organizations: { name: string } | { name: string }[] | null;
}>;

function organizationName(row: MembershipRow): string {
  const organization = Array.isArray(row.organizations) ? row.organizations[0] : row.organizations;
  return organization?.name?.trim() || row.organization_id;
}

export async function loadActiveWorkspaceMemberships(): Promise<ActiveWorkspaceMembershipsResult> {
  await connection();
  const requestId = randomUUID();
  let client: Awaited<ReturnType<typeof createServerSupabaseClient>>;
  try {
    client = await createServerSupabaseClient();
  } catch (cause) {
    if (isMissingSupabasePublicConfiguration(cause)) {
      reportOperationalError({ operation: "workspace.user", requestId, code: "auth_config_missing", outcome: "unavailable", cause });
      return { state: "signed_out" };
    }
    reportOperationalError({ operation: "workspace.user", requestId, code: "auth_client_failed", outcome: "unavailable", cause });
    throw new WorkspaceDependencyError("auth_client_failed", cause);
  }
  const { data: userData, error: userError } = await client.auth.getUser().catch((cause: unknown): never => {
    reportOperationalError({ operation: "workspace.user", requestId, code: "auth_user_failed", outcome: "unavailable", cause });
    throw new WorkspaceDependencyError("auth_user_failed", cause);
  });
  if (isSignedOutUserResult(userData.user, userError)) return { state: "signed_out" };
  if (userError) {
    reportOperationalError({ operation: "workspace.user", requestId, code: "auth_user_failed", outcome: "unavailable", cause: userError });
    throw new WorkspaceDependencyError("auth_user_failed", userError);
  }
  if (!userData.user) {
    reportOperationalError({ operation: "workspace.user", requestId, code: "auth_user_missing", outcome: "unavailable" });
    throw new WorkspaceDependencyError("auth_user_missing");
  }

  let membershipQuery;
  try {
    membershipQuery = await client
      .from("organization_memberships")
      .select("id, organization_id, role, status, organizations(name)")
      .eq("user_id", userData.user.id)
      .eq("status", "active")
      .order("created_at", { ascending: true });
  } catch (cause) {
    reportOperationalError({ operation: "workspace.memberships", requestId, code: "membership_query_failed", outcome: "unavailable", cause });
    throw new WorkspaceDependencyError("membership_query_failed", cause);
  }
  const { data, error } = membershipQuery;
  if (error) {
    reportOperationalError({ operation: "workspace.memberships", requestId, code: "membership_query_failed", outcome: "unavailable", cause: error });
    throw new WorkspaceDependencyError("membership_query_failed", error);
  }

  return { state: "authenticated", memberships: ((data ?? []) as MembershipRow[]).map((row) => ({
    id: row.id,
    organizationId: row.organization_id,
    organizationName: organizationName(row),
    role: row.role,
    status: row.status,
  })) };
}

export async function loadWorkspaceContext(): Promise<WorkspaceContextResult> {
  const result = await loadActiveWorkspaceMemberships();
  if (result.state === "signed_out") return result;
  const selectedOrganizationId = (await cookies()).get(ORGANIZATION_COOKIE)?.value ?? null;
  return resolveWorkspaceContext(result.memberships, selectedOrganizationId);
}

export async function loadActionWorkspaceMembership(): Promise<WorkspaceMembership | null> {
  const context = await loadWorkspaceContext();
  return context.state === "ready" ? context.membership : null;
}

export function reportWorkspaceActionFailure(operation: string, cause: unknown, requestId = randomUUID()): void {
  reportOperationalError({
    operation,
    requestId,
    code: "workspace_action_failed",
    outcome: "failed",
    cause,
  });
}

export function throwWorkspaceOperationError(operation: string, cause: unknown): never {
  const requestId = randomUUID();
  reportOperationalError({ operation, requestId, code: "workspace_read_failed", outcome: "unavailable", cause });
  throw new WorkspaceDependencyError("workspace_read_failed", cause);
}
