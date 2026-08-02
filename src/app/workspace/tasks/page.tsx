import { OperationsTasksPage, type OperationsTaskItem } from "@/features/tasks/operations-tasks-page";
import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { createOperationsTaskAction, updateOperationsTaskStatusAction } from "./actions";

type TaskRow = Readonly<{ id: string; task_type: string; title: string; description: string | null; status: OperationsTaskItem["status"]; due_at: string | null; booking_id: string | null; assigned_membership_id: string | null; created_at: string; updated_at: string }>;

async function loadTasks(organizationId: string): Promise<OperationsTaskItem[]> {
  const client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("list_operations_tasks", { p_organization_id: organizationId, p_limit: 100 });
  if (error) throwWorkspaceOperationError("workspace.tasks.read", error);
  return ((data ?? []) as TaskRow[]).map((task) => ({ id: task.id, taskType: task.task_type, title: task.title, description: task.description, status: task.status, dueAt: task.due_at, bookingId: task.booking_id, assignedMembershipId: task.assigned_membership_id, createdAt: task.created_at, updatedAt: task.updated_at }));
}

export default async function OperationsTasksWorkspacePage() {
  const membership = await requireWorkspaceMembership(new Set(["owner", "manager", "operations"]));
  return <WorkspaceShell activeHref="/workspace/tasks" organizationName={membership.organizationName} role={membership.role}><OperationsTasksPage createTask={createOperationsTaskAction} tasks={await loadTasks(membership.organizationId)} updateStatus={updateOperationsTaskStatusAction} /></WorkspaceShell>;
}
