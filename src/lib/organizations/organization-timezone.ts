import type { createServerSupabaseClient } from "@/lib/supabase/server-auth";

type ServerSupabaseClient = Awaited<ReturnType<typeof createServerSupabaseClient>>;

export async function readOrganizationTimezone(client: ServerSupabaseClient, organizationId: string): Promise<string | null> {
  const { data, error } = await client.from("organizations").select("timezone").eq("id", organizationId).maybeSingle();
  if (error) throw error;
  const timezone = (data as { timezone?: unknown } | null)?.timezone;
  return typeof timezone === "string" && timezone.trim() ? timezone.trim() : null;
}
