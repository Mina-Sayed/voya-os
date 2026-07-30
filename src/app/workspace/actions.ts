"use server";

import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { loadActiveWorkspaceMemberships, ORGANIZATION_COOKIE } from "@/features/auth/workspace-context";

export async function selectOrganizationAction(formData: FormData): Promise<void> {
  const organizationId = formData.get("organization_id");
  if (typeof organizationId !== "string") redirect("/access-pending");

  const result = await loadActiveWorkspaceMemberships();
  if (result.state === "signed_out") redirect("/sign-in");
  if (!result.memberships.some((membership) => membership.organizationId === organizationId)) {
    redirect("/access-pending");
  }

  (await cookies()).set(ORGANIZATION_COOKIE, organizationId, {
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    path: "/",
    maxAge: 60 * 60 * 24 * 30,
  });
  redirect("/workspace");
}
