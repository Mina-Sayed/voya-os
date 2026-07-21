export type MembershipCandidate = Readonly<{
  id: string;
  organizationId: string;
  role: string;
  status: "active" | "suspended";
}>;

export function resolveActiveMembership(memberships: readonly MembershipCandidate[]): MembershipCandidate | null {
  const activeMemberships = memberships.filter((membership) => membership.status === "active");
  return activeMemberships.length === 1 ? activeMemberships[0] : null;
}
