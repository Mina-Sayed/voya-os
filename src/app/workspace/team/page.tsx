import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { TeamPage, type TeamInvitationListItem, type TeamMemberListItem } from "@/features/team/team-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { inviteTeamMemberAction, teamMemberCommandAction } from "./actions";

type MemberRpcRow = Readonly<{ id: string; user_id: string; display_name: string; role: TeamMemberListItem["role"]; status: TeamMemberListItem["status"]; created_at: string }>;
type InvitationRpcRow = Readonly<{ id: string; normalized_email: string; role: TeamInvitationListItem["role"]; status: TeamInvitationListItem["status"]; expires_at: string; created_at: string; accepted_at: string | null; delivery_status: TeamInvitationListItem["deliveryStatus"] }>;

async function loadTeam(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>) {
  const client = await createServerSupabaseClient();
  const [membersResult, invitationsResult] = await Promise.all([
    client.rpc("list_organization_members", { p_organization_id: membership.organizationId }),
    client.rpc("list_organization_invitations", { p_organization_id: membership.organizationId }),
  ]);
  if (membersResult.error) throwWorkspaceOperationError("workspace.team.members.read", membersResult.error);
  if (invitationsResult.error) throwWorkspaceOperationError("workspace.team.invitations.read", invitationsResult.error);
  return {
    members: ((membersResult.data ?? []) as MemberRpcRow[]).map((member) => ({ id: member.id, displayName: member.display_name, role: member.role, status: member.status, createdAt: member.created_at })),
    invitations: ((invitationsResult.data ?? []) as InvitationRpcRow[]).map((invitation) => ({ id: invitation.id, email: invitation.normalized_email, role: invitation.role, status: invitation.status, expiresAt: invitation.expires_at, createdAt: invitation.created_at, acceptedAt: invitation.accepted_at, deliveryStatus: invitation.delivery_status })),
  };
}

export default async function TeamWorkspacePage() {
  const membership = await requireWorkspaceMembership(new Set(["owner", "manager"]));
  const team = await loadTeam(membership);
  return <WorkspaceShell activeHref="/workspace/team" organizationName={membership.organizationName} role={membership.role}><TeamPage canManage={membership.role === "owner"} command={teamMemberCommandAction} invite={inviteTeamMemberAction} invitations={team.invitations} members={team.members} /></WorkspaceShell>;
}
