import { redirect } from "next/navigation";
import { VoyaStayHomePage } from "@/features/stay/voya-stay-home-page";
import type { Metadata } from "next";
import { getVoyaStayRequestConfig, listVoyaStayPublicListings } from "@/lib/stay/public-catalog";

export const metadata: Metadata = {
  title: "VOYA Stay | إقامات مفروشة بطلب مراجعة واضح",
  description: "استكشف الإقامات المنشورة من VOYA، وابحث بالتواريخ ثم أرسل طلباً يراجعه الفريق قبل أي تأكيد.",
};

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
  const [featuredListings, requestConfig] = await Promise.all([
    listVoyaStayPublicListings({ destination: null, checkIn: null, checkOut: null, guests: null, bedrooms: null }),
    getVoyaStayRequestConfig(),
  ]);
  return <VoyaStayHomePage featuredListings={featuredListings.slice(0, 3)} requestsEnabled={requestConfig.requestsEnabled} />;
}
