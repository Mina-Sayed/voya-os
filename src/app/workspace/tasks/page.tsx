import { OperationsTasksPage, type OperationsTaskItem, type TaskAssignee } from "@/features/tasks/operations-tasks-page";
import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { createOperationsTaskAction, updateOperationsTaskStatusAction } from "./actions";

type TaskRow = Readonly<{ id: string; task_type: string; title: string; description: string | null; status: OperationsTaskItem["status"]; due_at: string | null; booking_id: string | null; assigned_membership_id: string | null; created_at: string; updated_at: string }>;
type MemberRow = Readonly<{ id: string; display_name: string; role: TaskAssignee["role"]; status: TaskAssignee["status"] }>;

async function loadTaskData(organizationId: string): Promise<Readonly<{ tasks: OperationsTaskItem[]; assignees: TaskAssignee[] }>> {
  const client = await createServerSupabaseClient();
  const [tasksResult, membersResult] = await Promise.all([
    client.rpc("list_operations_tasks", { p_organization_id: organizationId, p_limit: 100 }),
    client.rpc("list_organization_members", { p_organization_id: organizationId }),
  ]);
  if (tasksResult.error) throwWorkspaceOperationError("workspace.tasks.read", tasksResult.error);
  if (membersResult.error) throwWorkspaceOperationError("workspace.tasks.assignees.read", membersResult.error);
  const assignees = ((membersResult.data ?? []) as MemberRow[]).filter((member) => member.status === "active");
  const assigneeNames = new Map(assignees.map((member) => [member.id, member.display_name]));
  return {
    assignees,
    tasks: ((tasksResult.data ?? []) as TaskRow[]).map((task) => ({
      id: task.id, taskType: task.task_type, title: task.title, description: task.description,
      status: task.status, dueAt: task.due_at, bookingId: task.booking_id,
      assignedMembershipId: task.assigned_membership_id,
      assignedDisplayName: task.assigned_membership_id ? assigneeNames.get(task.assigned_membership_id) ?? null : null,
      createdAt: task.created_at, updatedAt: task.updated_at,
    })),
  };
}

export default async function OperationsTasksWorkspacePage() {
  const membership = await requireWorkspaceMembership(new Set(["owner", "manager", "operations"]));
  const taskData = await loadTaskData(membership.organizationId);
  return <WorkspaceShell activeHref="/workspace/tasks" organizationName={membership.organizationName} role={membership.role}><OperationsTasksPage assignees={taskData.assignees} createTask={createOperationsTaskAction} tasks={taskData.tasks} updateStatus={updateOperationsTaskStatusAction} /></WorkspaceShell>;
}
