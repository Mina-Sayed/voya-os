import { randomUUID } from "node:crypto";
import { NextResponse, type NextRequest } from "next/server";
import { internalApplicationUrl, resolveApplicationOrigin } from "@/features/auth/application-origin";
import { reportOperationalError } from "@/lib/observability/operational-error";
import { SupabaseConfigurationError } from "@/lib/supabase/public-config";
import { createRouteSupabaseClient } from "@/lib/supabase/route-client";

function redirectTo(origin: URL, path: "/workspace" | "/access-pending") {
  return NextResponse.redirect(internalApplicationUrl(origin, path));
}

function linkSessionUrl(origin: URL): URL {
  const url = new URL("/sign-in", origin);
  url.searchParams.set("error", "link_session");
  return url;
}

function redirectToFixedLinkSessionPath() {
  return new NextResponse(null, { status: 307, headers: { location: "/sign-in?error=link_session" } });
}

export async function GET(request: NextRequest) {
  const requestId = randomUUID();
  let origin: URL;
  try {
    origin = resolveApplicationOrigin({ environment: process.env, requestUrl: request.url });
  } catch (error) {
    reportOperationalError({ operation: "auth.callback.origin", requestId, code: "callback_configuration_failed", outcome: "unavailable", cause: error });
    return redirectToFixedLinkSessionPath();
  }

  const code = request.nextUrl.searchParams.get("code");
  if (!code) return NextResponse.redirect(linkSessionUrl(origin));

  const response = redirectTo(origin, "/access-pending");
  try {
    const client = createRouteSupabaseClient(request, response);
    const { error: exchangeError } = await client.auth.exchangeCodeForSession(code);
    if (exchangeError) {
      reportOperationalError({ operation: "auth.callback.exchange", requestId, code: "callback_exchange_failed", outcome: "unavailable", cause: exchangeError });
      response.headers.set("location", linkSessionUrl(origin).toString());
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
      .select("id, status")
      .eq("user_id", userData.user.id);
    if (membershipError) {
      reportOperationalError({ operation: "auth.callback.memberships", requestId, code: "callback_membership_query_failed", outcome: "unavailable", cause: membershipError });
      return response;
    }

    if (!Array.isArray(memberships)) return response;
    if (memberships.some((membership) => membership.status === "active")) {
      response.headers.set("location", internalApplicationUrl(origin, "/workspace").toString());
      return response;
    }
    if (memberships.length > 0 || !userData.user.email_confirmed_at) return response;

    if (memberships.length === 0) {
      const { error: bootstrapError } = await client.rpc("bootstrap_personal_workspace", {
        p_request_id: requestId,
      });
      if (bootstrapError) {
        reportOperationalError({ operation: "auth.callback.bootstrap", requestId, code: "workspace_bootstrap_failed", outcome: "unavailable", cause: bootstrapError });
        return response;
      }
    }

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
