import { redirect } from "next/navigation";
import { MfaPage } from "@/features/auth/mfa-page";
import { loadActiveWorkspaceMemberships, loadMfaAssurance } from "@/features/auth/workspace-context";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

type SearchParams = Promise<{ reason?: string }>;

export default async function SecurityMfaPage({ searchParams }: Readonly<{ searchParams: SearchParams }>) {
  const memberships = await loadActiveWorkspaceMemberships();
  if (memberships.state === "signed_out") redirect("/sign-in");

  const assurance = await loadMfaAssurance();
  if (assurance.state === "satisfied") redirect(memberships.memberships.length === 0 ? "/onboarding" : "/workspace");
  const client = await createServerSupabaseClient();
  const factors = await client.auth.mfa.listFactors();
  const verifiedFactorId = (factors.data?.all ?? []).find(
    (factor) => factor.factor_type === "totp" && factor.status === "verified",
  )?.id ?? null;
  const params = await searchParams;
  const reason: "enrollment" | "challenge" = assurance.state === "required"
    ? assurance.reason
    : params.reason === "challenge" ? "challenge" : "enrollment";
  return <MfaPage reason={reason} verifiedFactorId={verifiedFactorId} />;
}
