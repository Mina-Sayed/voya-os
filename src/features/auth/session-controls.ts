"use server";

import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { ORGANIZATION_COOKIE, reportWorkspaceActionFailure } from "./workspace-context";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

export async function signOutAllSessionsAction(): Promise<never> {
  try {
    const client = await createServerSupabaseClient();
    const { error } = await client.auth.signOut({ scope: "global" });
    if (error) reportWorkspaceActionFailure("auth.sign_out_all", error);
  } catch (error) {
    reportWorkspaceActionFailure("auth.sign_out_all", error);
  } finally {
    (await cookies()).delete(ORGANIZATION_COOKIE);
    redirect("/sign-in");
  }
}
