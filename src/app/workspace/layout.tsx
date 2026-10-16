import type { ReactNode } from "react";
import { redirect } from "next/navigation";
import { loadActiveWorkspaceMemberships } from "@/features/auth/workspace-context";

// Defense in depth: every /workspace route already gates itself (pages call
// requireWorkspaceMembership with their own roles; /workspace handles MFA and
// organization selection). This layout only guarantees that a signed-out
// visitor never renders anything under /workspace, even if a future page
// forgets its own check. It deliberately does not resolve the organization or
// role, so the selection flow and page-specific role checks are unchanged.
export default async function WorkspaceLayout({ children }: Readonly<{ children: ReactNode }>) {
  const result = await loadActiveWorkspaceMemberships();
  if (result.state === "signed_out") redirect("/sign-in");
  return children;
}
