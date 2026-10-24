import { redirect } from "next/navigation";
import { MfaPage } from "@/features/auth/mfa-page";
import { loadActiveWorkspaceMemberships, loadMfaAssurance } from "@/features/auth/workspace-context";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

type SearchParams = Promise<{ reason?: string; add?: string }>;

export default async function SecurityMfaPage({ searchParams }: Readonly<{ searchParams: SearchParams }>) {
  const memberships = await loadActiveWorkspaceMemberships();
  if (memberships.state === "signed_out") redirect("/sign-in");

  const assurance = await loadMfaAssurance();
  const params = await searchParams;
  const client = await createServerSupabaseClient();
  const factors = await client.auth.mfa.listFactors();
  const verifiedFactors = (factors.data?.all ?? []).filter(
    (factor) => factor.factor_type === "totp" && factor.status === "verified",
  );
  // An AAL2 session may add one backup authenticator (max two verified).
  if (assurance.state === "satisfied" && params.add === "backup" && verifiedFactors.length < 2) {
    return <MfaPage reason="backup" verifiedFactorId={verifiedFactors[0]?.id ?? null} />;
  }
  if (assurance.state === "satisfied") redirect(memberships.memberships.some((membership) => membership.status === "active") ? "/workspace" : "/onboarding");
  const verifiedFactorId = verifiedFactors[0]?.id ?? null;
  const reason: "enrollment" | "challenge" = assurance.state === "required"
    ? assurance.reason
    : params.reason === "challenge" ? "challenge" : "enrollment";
  return <MfaPage reason={reason} verifiedFactorId={verifiedFactorId} />;
}
