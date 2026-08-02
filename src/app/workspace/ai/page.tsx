import { visibleAgentDefinitions } from "@/domain/ai/agent-registry";
import { AgentCenterPage, type AiRunItem, type AiToolCallItem } from "@/features/ai/agent-center-page";
import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { createAiRunRequestAction } from "./actions";

type RunRow = Readonly<{
  id: string;
  agent_kind: string;
  agent_version: string;
  status: string;
  purpose: string;
  model_name: string;
  prompt_version: string;
  initiated_by_membership_id: string;
  created_at: string;
  started_at: string | null;
  finished_at: string | null;
  error_code: string | null;
  tool_call_count: number;
}>;

type ToolRow = Readonly<{
  id: string;
  tool_name: string;
  tool_version: string;
  effect: "read" | "proposal";
  policy_decision: "allowed" | "denied";
  status: string;
  created_at: string;
}>;

async function loadAgentCenter(organizationId: string): Promise<AiRunItem[]> {
  const client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("list_ai_runs", { p_organization_id: organizationId, p_limit: 30 });
  if (error) throwWorkspaceOperationError("workspace.ai.read", error);
  const rows = (data ?? []) as RunRow[];
  const runs = await Promise.all(rows.slice(0, 12).map(async (run): Promise<AiRunItem> => {
    const result = await client.rpc("list_ai_tool_calls", { p_organization_id: organizationId, p_run_id: run.id });
    if (result.error) throwWorkspaceOperationError("workspace.ai.tools.read", result.error);
    return {
      id: run.id,
      agentKind: run.agent_kind,
      agentVersion: run.agent_version,
      status: run.status,
      purpose: run.purpose,
      modelName: run.model_name,
      promptVersion: run.prompt_version,
      initiatedByMembershipId: run.initiated_by_membership_id,
      createdAt: run.created_at,
      startedAt: run.started_at,
      finishedAt: run.finished_at,
      errorCode: run.error_code,
      toolCalls: ((result.data ?? []) as ToolRow[]).map((tool): AiToolCallItem => ({
        id: tool.id,
        toolName: tool.tool_name,
        toolVersion: tool.tool_version,
        effect: tool.effect,
        policyDecision: tool.policy_decision,
        status: tool.status,
        createdAt: tool.created_at,
      })),
    };
  }));
  return runs;
}

export default async function AgentCenterWorkspacePage() {
  const membership = await requireWorkspaceMembership(new Set(["owner", "manager", "sales_agent", "operations", "accountant"]));
  const runs = await loadAgentCenter(membership.organizationId);
  return <WorkspaceShell activeHref="/workspace/ai" organizationName={membership.organizationName} role={membership.role}><AgentCenterPage agents={visibleAgentDefinitions(membership.role as Parameters<typeof visibleAgentDefinitions>[0])} requestRun={createAiRunRequestAction} runs={runs} /></WorkspaceShell>;
}
