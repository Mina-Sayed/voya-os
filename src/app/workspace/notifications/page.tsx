import { redirect } from "next/navigation";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import { NotificationsPage, type NotificationItem } from "@/features/notifications/notifications-page";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { markNotificationReadAction } from "./actions";

async function loadNotifications(): Promise<NotificationItem[]> {
  try { const client = await createServerSupabaseClient(); const { data: userData } = await client.auth.getUser(); if (!userData.user) redirect("/sign-in"); const { data: memberships } = await client.from("organization_memberships").select("id, organization_id, role, status").eq("user_id", userData.user.id).limit(2); const membership = resolveActiveMembership((memberships ?? []).map((item) => ({ id: item.id, organizationId: item.organization_id, role: item.role, status: item.status }))); if (!membership) redirect("/access-pending"); const { data, error } = await client.rpc("list_my_notifications", { p_organization_id: membership.organizationId, p_limit: 50 }); if (error) throw error; return ((data ?? []) as { id: string; category: NotificationItem["category"]; title: string; body: string; read_at: string | null; created_at: string }[]).map((item) => ({ id: item.id, category: item.category, title: item.title, body: item.body, readAt: item.read_at, createdAt: item.created_at })); } catch (error) { if (error instanceof SupabaseConfigurationError) redirect("/sign-in"); throw error; }
}
export default async function NotificationsWorkspacePage() { return <NotificationsPage markRead={markNotificationReadAction} notifications={await loadNotifications()} />; }
