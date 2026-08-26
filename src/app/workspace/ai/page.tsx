import { visibleAgentDefinitions } from "@/domain/ai/agent-registry";
import { parseDataEntryApplicationResult } from "@/domain/ai/data-entry-application";
import { isDataEntryRole } from "@/domain/ai/data-entry-contract";
import { AgentCenterPage, type AiRunItem, type AiToolCallItem } from "@/features/ai/agent-center-page";
import type { DataEntryDraftReview, DataEntryInputReview } from "@/features/ai/data-entry-review";
import type { DataEntryDraftSummary as DataEntryDraftListItem } from "@/features/ai/data-entry-intake";
import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { parseEditableDataEntryPayload } from "@/lib/ai/data-entry-payload";
import { createAiRunRequestAction } from "./actions";
import { confirmAiDataEntryDraftAction, createAiDataEntryDraftAction, rejectAiDataEntryDraftAction, submitAiDataEntryDraftAction } from "./data-entry-actions";

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

type AiResultRow = Readonly<{ status: string; result_summary: { provider?: string; model?: string; output?: string } | null }>;

type ToolRow = Readonly<{
  id: string;
  tool_name: string;
  tool_version: string;
  effect: "read" | "proposal";
  policy_decision: "allowed" | "denied";
  status: string;
  created_at: string;
}>;

type DraftRow = Readonly<{
  id: string;
  status: DataEntryDraftListItem["status"];
  source_kind: DataEntryDraftListItem["sourceKind"];
  version: number;
  input_count: number;
  created_at: string;
}>;

type DraftDetailRow = Readonly<{
  id: string;
  status: DataEntryDraftReview["status"];
  version: number;
  source_text: string;
  extraction_payload: unknown;
  confirmation_payload: unknown;
  application_result: unknown;
}>;

type InputDetailRow = Readonly<{
  id: string;
  mime_type: DataEntryInputReview["mimeType"];
  byte_size: number;
  status: DataEntryInputReview["status"];
  mapped_property_id: string | null;
}>;

async function loadAgentCenter(organizationId: string): Promise<AiRunItem[]> {
  const client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("list_ai_runs", { p_organization_id: organizationId, p_limit: 30 });
  if (error) throwWorkspaceOperationError("workspace.ai.read", error);
  const rows = (data ?? []) as RunRow[];
  const runs = await Promise.all(rows.slice(0, 12).map(async (run): Promise<AiRunItem> => {
    const toolsResult = await client.rpc("list_ai_tool_calls", { p_organization_id: organizationId, p_run_id: run.id });
    if (toolsResult.error) throwWorkspaceOperationError("workspace.ai.tools.read", toolsResult.error);
    let resultRow: AiResultRow | undefined;
    if (run.agent_kind !== "data_entry") {
      const resultSummary = await client.rpc("get_ai_run_result_v1", { p_organization_id: organizationId, p_run_id: run.id });
      if (resultSummary.error) throwWorkspaceOperationError("workspace.ai.result.read", resultSummary.error);
      resultRow = ((resultSummary.data ?? []) as AiResultRow[])[0];
    }
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
      resultSummary: resultRow?.result_summary?.output ? {
        provider: resultRow.result_summary.provider ?? "unknown",
        model: resultRow.result_summary.model ?? "unknown",
        output: resultRow.result_summary.output,
      } : null,
      toolCalls: ((toolsResult.data ?? []) as ToolRow[]).map((tool): AiToolCallItem => ({
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

async function loadDataEntryDrafts(organizationId: string): Promise<DataEntryDraftListItem[]> {
  const client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("list_ai_data_entry_drafts_v1", { p_organization_id: organizationId, p_limit: 20 });
  if (error) throwWorkspaceOperationError("workspace.ai.data_entry.read", error);
  return ((data ?? []) as DraftRow[]).map((draft) => ({
    id: draft.id,
    status: draft.status,
    sourceKind: draft.source_kind,
    version: draft.version,
    inputCount: Number(draft.input_count ?? 0),
    createdAt: draft.created_at,
  }));
}

async function loadDataEntryReviews(organizationId: string, drafts: readonly DataEntryDraftListItem[]): Promise<DataEntryDraftReview[]> {
  const reviewable = drafts.filter((draft) => ["ready_for_review", "partially_applied", "confirmed", "applied", "rejected", "expired"].includes(draft.status));
  const reviews = await Promise.all(reviewable.map(async (draft) => {
    const client = await createServerSupabaseClient();
    const [detailResult, inputsResult] = await Promise.all([
      client.rpc("get_ai_data_entry_draft_v1", { p_organization_id: organizationId, p_draft_id: draft.id }),
      client.rpc("list_ai_data_entry_inputs_v1", { p_organization_id: organizationId, p_draft_id: draft.id }),
    ]);
    if (detailResult.error) throwWorkspaceOperationError("workspace.ai.data_entry.detail.read", detailResult.error);
    if (inputsResult.error) throwWorkspaceOperationError("workspace.ai.data_entry.inputs.read", inputsResult.error);
    const detail = ((detailResult.data ?? []) as DraftDetailRow[])[0];
    if (!detail) return null;
    const inputs = ((inputsResult.data ?? []) as InputDetailRow[]).map((input): DataEntryInputReview => ({
      id: input.id,
      mimeType: input.mime_type,
      byteSize: Number(input.byte_size),
      status: input.status,
      mappedPropertyId: input.mapped_property_id,
    }));
    const candidate = detail.confirmation_payload && typeof detail.confirmation_payload === "object" && Object.keys(detail.confirmation_payload as object).length > 0
      ? detail.confirmation_payload
      : detail.extraction_payload;
    const parsed = parseEditableDataEntryPayload(candidate, inputs.map((input) => input.id));
    if (!parsed.ok && detail.status !== "expired") return null;
    const payload = parsed.ok ? parsed.value : { clients: [], properties: [], unresolved: [], warnings: [] };
    return {
      id: detail.id,
      status: detail.status,
      version: detail.version,
      sourceText: detail.source_text,
      payload,
      inputs,
      applicationResult: parseDataEntryApplicationResult(detail.application_result),
    } as DataEntryDraftReview;
  }));
  return reviews.filter((review): review is DataEntryDraftReview => review !== null);
}

export default async function AgentCenterWorkspacePage() {
  const membership = await requireWorkspaceMembership(new Set(["owner", "manager", "sales_agent", "operations", "accountant"]));
  const runs = await loadAgentCenter(membership.organizationId);
  const dataEntryEnabled = isDataEntryRole(membership.role);
  const dataEntryDrafts = dataEntryEnabled ? await loadDataEntryDrafts(membership.organizationId) : [];
  const dataEntryReviews = dataEntryEnabled ? await loadDataEntryReviews(membership.organizationId, dataEntryDrafts) : [];
  const canWriteDataEntryProperties = membership.role === "owner" || membership.role === "manager" || membership.role === "operations";
  return <WorkspaceShell activeHref="/workspace/ai" organizationName={membership.organizationName} role={membership.role}><AgentCenterPage canWriteDataEntryProperties={canWriteDataEntryProperties} agents={visibleAgentDefinitions(membership.role as Parameters<typeof visibleAgentDefinitions>[0])} confirmDataEntryDraft={dataEntryEnabled ? confirmAiDataEntryDraftAction : undefined} createDataEntryDraft={dataEntryEnabled ? createAiDataEntryDraftAction : undefined} dataEntryDrafts={dataEntryDrafts} dataEntryReviews={dataEntryReviews} rejectDataEntryDraft={dataEntryEnabled ? rejectAiDataEntryDraftAction : undefined} requestRun={createAiRunRequestAction} runs={runs} submitDataEntryDraft={dataEntryEnabled ? submitAiDataEntryDraftAction : undefined} /></WorkspaceShell>;
}
