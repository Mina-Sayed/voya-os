import { randomUUID } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { internalApplicationUrl, resolveApplicationOrigin } from "@/features/auth/application-origin";
import { reportOperationalError } from "@/lib/observability/operational-error";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createRouteSupabaseClient } from "@/lib/supabase/route-client";

function redirectTo(origin: URL, path: "/workspace" | "/access-pending") {
  return NextResponse.redirect(internalApplicationUrl(origin, path));
}

function redirectToFixedPendingPath() {
  return new NextResponse(null, { status: 307, headers: { location: "/access-pending" } });
}

const tokenHashTypes = new Set(["email", "magiclink", "invite", "signup"] as const);
type TokenHashType = "email" | "magiclink" | "invite" | "signup";

function resolveTokenHashType(value: string | null): TokenHashType {
  return value && tokenHashTypes.has(value as TokenHashType) ? value as TokenHashType : "email";
}

export async function GET(request: NextRequest) {
  const requestId = randomUUID();
  let origin: URL;
  try {
    origin = resolveApplicationOrigin({ environment: process.env, requestUrl: request.url });
  } catch (error) {
    reportOperationalError({ operation: "auth.callback.origin", requestId, code: "callback_configuration_failed", outcome: "unavailable", cause: error });
    return redirectToFixedPendingPath();
  }

  const code = request.nextUrl.searchParams.get("code");
  const tokenHash = request.nextUrl.searchParams.get("token_hash");
  if (!code && !tokenHash) return redirectTo(origin, "/access-pending");

  const response = redirectTo(origin, "/access-pending");
  try {
    const client = createRouteSupabaseClient(request, response);
    const authResult = code
      ? await client.auth.exchangeCodeForSession(code)
      : await client.auth.verifyOtp({
        token_hash: tokenHash!,
        type: resolveTokenHashType(request.nextUrl.searchParams.get("type")),
      });
    if (authResult.error) {
      reportOperationalError({ operation: code ? "auth.callback.exchange" : "auth.callback.verify", requestId, code: code ? "callback_exchange_failed" : "callback_verify_failed", outcome: "unavailable", cause: authResult.error });
      return response;
    }

    const { data: userData, error: userError } = await client.auth.getUser();
    if (userError) {
      reportOperationalError({ operation: "auth.callback.user", requestId, code: "callback_user_failed", outcome: "unavailable", cause: userError });
      return response;
    }
    if (!userData.user) return response;

    const { data: memberships, error: membershipError } = await client
      .from("organization_memberships")
      .select("id")
      .eq("user_id", userData.user.id)
      .eq("status", "active")
      .limit(1);
    if (membershipError) {
      reportOperationalError({ operation: "auth.callback.memberships", requestId, code: "callback_membership_query_failed", outcome: "unavailable", cause: membershipError });
      return response;
    }

    if (!memberships?.length) return response;

    response.headers.set("location", internalApplicationUrl(origin, "/workspace").toString());
    return response;
  } catch (error) {
    if (error instanceof SupabaseConfigurationError) {
      reportOperationalError({ operation: "auth.callback.client", requestId, code: "callback_configuration_failed", outcome: "unavailable", cause: error });
      return response;
    }
    reportOperationalError({ operation: "auth.callback.dependency", requestId, code: "callback_dependency_failed", outcome: "unavailable", cause: error });
    return response;
  }
}
