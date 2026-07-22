"use server";

import { revalidatePath } from "next/cache";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

export async function markNotificationReadAction(notificationId: string): Promise<void> {
  const client = await createServerSupabaseClient(); const { data: userData } = await client.auth.getUser(); if (!userData.user) return;
  const { data: memberships } = await client.from("organization_memberships").select("id, organization_id, role, status").eq("user_id", userData.user.id).limit(2);
  const membership = resolveActiveMembership((memberships ?? []).map((item) => ({ id: item.id, organizationId: item.organization_id, role: item.role, status: item.status })));
  if (!membership) return;
  const { error } = await client.rpc("mark_notification_read", { p_organization_id: membership.organizationId, p_notification_id: notificationId });
  if (!error) revalidatePath("/workspace/notifications");
}
