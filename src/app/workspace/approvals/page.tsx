import Link from "next/link";
import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { ApprovalRequestsPage, type ApprovalRequestItem } from "@/features/approvals/approval-requests-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { decideBookingApprovalAction } from "./actions";

type ApprovalProposalSummary = NonNullable<ApprovalRequestItem["proposalSummary"]>;

function proposalText(record: Record<string, unknown>, key: string) {
  const value = record[key];
  return typeof value === "string" && value.length > 0 ? value : null;
}

function normalizeProposalSummary(value: unknown): ApprovalProposalSummary | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  return {
    checkIn: proposalText(record, "checkIn"),
    checkOut: proposalText(record, "checkOut"),
    amountMinor: proposalText(record, "amountMinor"),
    currency: proposalText(record, "currency"),
    reason: proposalText(record, "reason"),
    propertyId: proposalText(record, "propertyId"),
    clientId: proposalText(record, "clientId"),
    propertyLabel: proposalText(record, "propertyLabel"),
    clientLabel: proposalText(record, "clientLabel"),
  };
}

const pageSize = 50;
const pagePath = "/workspace/approvals";
const uuidPattern = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/iu;

type ApprovalCursor = Readonly<{ createdAt: string; id: string }>;
function readCursor(value: string | string[] | undefined): ApprovalCursor | null {
  if (typeof value !== "string" || value.length > 85) return null;
  const [createdAt, id, extra] = value.split("|");
  return extra === undefined && id && uuidPattern.test(id) && Number.isFinite(Date.parse(createdAt))
    ? { createdAt, id } : null;
}

async function loadApprovalRequests(
  membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>,
  pendingOnly: boolean,
  cursor: ApprovalCursor | null,
): Promise<ApprovalRequestItem[]> {
  const client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("list_approval_requests_v3", {
    p_organization_id: membership.organizationId,
    p_limit: pageSize + 1,
    p_pending_only: pendingOnly,
    p_before_created_at: cursor?.createdAt ?? null,
    p_before_id: cursor?.id ?? null,
  });
  if (error) throwWorkspaceOperationError("workspace.read", error);
  return ((data ?? []) as { id: string; resource_type: string; resource_id: string; proposed_action: string; status: ApprovalRequestItem["status"]; expires_at: string | null; created_at: string; proposal_summary: unknown; requester_display_name: string | null }[]).map((item) => ({
    id: item.id,
    resourceId: item.resource_id,
    resourceType: item.resource_type,
    proposedAction: item.proposed_action,
    status: item.status,
    expiresAt: item.expires_at,
    createdAt: item.created_at,
    proposalSummary: normalizeProposalSummary(item.proposal_summary),
    requesterDisplayName: item.requester_display_name,
  }));
}

export default async function ApprovalsWorkspacePage({ searchParams }: Readonly<{
  searchParams: Promise<{ status?: string | string[]; before?: string | string[] }>;
}>) {
  const membership = await requireWorkspaceMembership(new Set(["owner", "manager", "sales_agent", "operations", "accountant"]));
  const params = await searchParams;
  const pendingOnly = params.status !== "all";
  const cursor = readCursor(params.before);
  const rows = await loadApprovalRequests(membership, pendingOnly, cursor);
  const requests = rows.slice(0, pageSize);
  const last = requests.at(-1);
  const nextQuery = last && rows.length > pageSize
    ? new URLSearchParams({ status: pendingOnly ? "pending" : "all", before: `${last.createdAt}|${last.id}` })
    : null;

  return <WorkspaceShell activeHref={pagePath} organizationName={membership.organizationName} role={membership.role}>
    <nav aria-label="تصفية طلبات الاعتماد" className="flex flex-wrap gap-4 border-b border-line bg-white px-6 py-3 text-sm font-bold text-tide">
      <Link aria-current={pendingOnly ? "page" : undefined} className={pendingOnly ? "underline" : ""} href={pagePath}>بانتظار القرار</Link>
      <Link aria-current={pendingOnly ? undefined : "page"} className={pendingOnly ? "" : "underline"} href={`${pagePath}?status=all`}>كل الطلبات</Link>
    </nav>
    <ApprovalRequestsPage canDecide={membership.role === "owner" || membership.role === "manager"} decide={decideBookingApprovalAction} requests={requests} />
    {nextQuery || cursor ? <nav aria-label="صفحات طلبات الاعتماد" className="flex gap-4 px-6 py-4 text-sm font-bold text-tide">
      {cursor ? <Link href={pendingOnly ? pagePath : `${pagePath}?status=all`}>أول صفحة</Link> : null}
      {nextQuery ? <Link href={`${pagePath}?${nextQuery.toString()}`}>الصفحة التالية</Link> : null}
    </nav> : null}
  </WorkspaceShell>;
}
