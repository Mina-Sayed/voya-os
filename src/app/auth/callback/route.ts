import { NextResponse, type NextRequest } from "next/server";
import { resolveActiveMembership } from "@/features/auth/active-membership";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createRouteSupabaseClient } from "@/lib/supabase/route-client";

function redirectTo(request: NextRequest, path: "/workspace" | "/access-pending") {
  return NextResponse.redirect(new URL(path, request.url));
}

export async function GET(request: NextRequest) {
  const code = request.nextUrl.searchParams.get("code");
  if (!code) return redirectTo(request, "/access-pending");

  const response = redirectTo(request, "/access-pending");
  try {
    const client = createRouteSupabaseClient(request, response);
    const { error: exchangeError } = await client.auth.exchangeCodeForSession(code);
    if (exchangeError) return response;

    const { data: userData, error: userError } = await client.auth.getUser();
    if (userError || !userData.user) return response;

    const { data: memberships, error: membershipError } = await client
      .from("organization_memberships")
      .select("id, organization_id, role, status")
      .eq("user_id", userData.user.id)
      .limit(2);
    if (membershipError) return response;

    const membership = resolveActiveMembership((memberships ?? []).map((item) => ({
      id: item.id,
      organizationId: item.organization_id,
      role: item.role,
      status: item.status,
    })));
    if (!membership) return response;

    response.headers.set("location", new URL("/workspace", request.url).toString());
    return response;
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) return response;
    return response;
  }
}
