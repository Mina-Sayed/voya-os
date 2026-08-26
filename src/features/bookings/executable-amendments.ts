export type AmendmentApprovalProjection = Readonly<{
  id: string;
  resource_id: string;
  proposed_action: string;
  status: string;
  expires_at: string | null;
}>;

export function selectLatestExecutableAmendments(
  approvals: readonly AmendmentApprovalProjection[],
  nowMs = Date.now(),
) {
  const byBooking = new Map<string, string>();
  for (const item of approvals) {
    const expiresAt = item.expires_at ? Date.parse(item.expires_at) : Number.NaN;
    if (
      item.proposed_action === "booking.amend"
      && item.status === "approved"
      && Number.isFinite(expiresAt)
      && expiresAt > nowMs
      && !byBooking.has(item.resource_id)
    ) byBooking.set(item.resource_id, item.id);
  }
  return byBooking;
}
