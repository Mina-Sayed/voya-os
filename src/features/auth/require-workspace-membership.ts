import { redirect } from "next/navigation";
import { loadWorkspaceContext, type WorkspaceMembership } from "./workspace-context";

export async function requireWorkspaceMembership(
  allowedRoles?: ReadonlySet<string>,
): Promise<WorkspaceMembership> {
  const context = await loadWorkspaceContext();
  if (context.state === "signed_out") redirect("/sign-in");
  if (context.state === "mfa_required") redirect(`/security/mfa?reason=${context.reason}`);
  if (context.state === "selection_required") redirect("/workspace");
  if (context.state === "pending") redirect("/access-pending");
  if (allowedRoles && !allowedRoles.has(context.membership.role)) redirect("/access-pending");
  return context.membership;
}
