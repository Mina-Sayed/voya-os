"use server";

import { revalidatePath } from "next/cache";
import { loadActionWorkspaceMembership, reportWorkspaceActionFailure } from "@/features/auth/workspace-context";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

export async function markNotificationReadAction(notificationId: string): Promise<void> {
  const requestId = randomUUID();
  try {
    const membership = await loadActionWorkspaceMembership();
    if (!membership) return;
    const client = await createServerSupabaseClient();
    const { error } = await client.rpc("mark_notification_read", { p_organization_id: membership.organizationId, p_notification_id: notificationId });
    if (error) {
      if (["42501", "22023", "23503"].includes(error.code ?? "")) return;
      reportWorkspaceActionFailure("workspace.notification.read", error, requestId);
      return;
    }
    revalidatePath("/workspace/notifications");
  } catch (error) {
    reportWorkspaceActionFailure("workspace.notification.read", error, requestId);
  }
}
import { randomUUID } from "node:crypto";
