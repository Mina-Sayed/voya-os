import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { NotificationsPage, type NotificationItem } from "@/features/notifications/notifications-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { markNotificationReadAction } from "./actions";

async function loadNotifications(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<NotificationItem[]> {
  const client = await createServerSupabaseClient(); const { data, error } = await client.rpc("list_my_notifications", { p_organization_id: membership.organizationId, p_limit: 50 }); if (error) throwWorkspaceOperationError("workspace.read", error); return ((data ?? []) as { id: string; category: NotificationItem["category"]; title: string; body: string; read_at: string | null; created_at: string }[]).map((item) => ({ id: item.id, category: item.category, title: item.title, body: item.body, readAt: item.read_at, createdAt: item.created_at }));
}
export default async function NotificationsWorkspacePage() { const membership = await requireWorkspaceMembership(); return <WorkspaceShell activeHref="/workspace/notifications" organizationName={membership.organizationName} role={membership.role}><NotificationsPage markRead={markNotificationReadAction} notifications={await loadNotifications(membership)} /></WorkspaceShell>; }
