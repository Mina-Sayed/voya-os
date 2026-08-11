import { redirect } from "next/navigation";

type AuthCallbackSearchParams = Readonly<{
  code?: string;
  token_hash?: string;
  type?: string;
}>;

function callbackPath(params: AuthCallbackSearchParams): string | null {
  const query = new URLSearchParams();
  if (params.code) {
    query.set("code", params.code);
  } else if (params.token_hash) {
    query.set("token_hash", params.token_hash);
    if (params.type) query.set("type", params.type);
  } else {
    return null;
  }
  return `/auth/callback?${query.toString()}`;
}

export default async function Home({
  searchParams,
}: Readonly<{ searchParams: Promise<AuthCallbackSearchParams> }>) {
  const callback = callbackPath(await searchParams);
  if (callback) redirect(callback);
  redirect("/workspace");
}
