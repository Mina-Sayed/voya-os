"use server";

import { cookies } from "next/headers";
import { redirect } from "next/navigation";
import { ORGANIZATION_COOKIE, reportWorkspaceActionFailure } from "./workspace-context";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";

export async function signOutAction(): Promise<never> {
  try {
    const client = await createServerSupabaseClient();
    const { error } = await client.auth.signOut();
    if (error) reportWorkspaceActionFailure("auth.sign_out", error);
  } catch (error) {
    reportWorkspaceActionFailure("auth.sign_out", error);
  } finally {
    (await cookies()).delete(ORGANIZATION_COOKIE);
    redirect("/sign-in");
  }
}
