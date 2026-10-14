import { notFound } from "next/navigation";
import type { Metadata } from "next";
import { findStayDemoExample } from "@/features/stay/stay-demo-content";
import { stayDemoModeEnabled } from "@/features/stay/stay-demo-mode";
import { StayLivePropertyDetailPage } from "@/features/stay/stay-live-property-detail-page";
import { StayPropertyDetailPage, stayDemoDetailMetadata } from "@/features/stay/stay-property-detail-page";
import { parseStaySearchCriteria } from "@/features/stay/stay-search-criteria";
import { getVoyaStayPublicListing, getVoyaStayRequestConfig } from "@/lib/stay/public-catalog";

type StayPropertyPageProps = Readonly<{
  params: Promise<{ slug: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}>;

function toSearchParams(value: Record<string, string | string[] | undefined>): URLSearchParams {
  const params = new URLSearchParams();
  for (const [key, item] of Object.entries(value)) {
    if (typeof item === "string") params.set(key, item);
    else if (Array.isArray(item)) item.forEach((part) => params.append(key, part));
  }
  return params;
}

export async function generateMetadata({ params }: StayPropertyPageProps): Promise<Metadata> {
  const { slug } = await params;
  const listing = await getVoyaStayPublicListing(slug);
  if (listing) return { title: `${listing.title} | VOYA Stay`, description: listing.description };
  const example = findStayDemoExample(slug);
  if (stayDemoModeEnabled(process.env) && example) return stayDemoDetailMetadata(example);
  return { title: "إقامة غير متاحة | VOYA Stay", description: "هذه الإقامة غير منشورة حاليًا." };
}

export default async function StayPropertyPage({ params, searchParams }: StayPropertyPageProps) {
  const { slug } = await params;
  const rawSearchParams = await searchParams;
  const criteria = parseStaySearchCriteria(toSearchParams(rawSearchParams));
  const listing = await getVoyaStayPublicListing(
    slug,
    criteria?.checkIn ?? null,
    criteria?.checkOut ?? null,
  );
  if (listing) {
    const requestConfig = await getVoyaStayRequestConfig();
    return <StayLivePropertyDetailPage
      initialCheckIn={criteria?.checkIn ?? undefined}
      initialCheckOut={criteria?.checkOut ?? undefined}
      initialGuests={criteria?.guests ?? undefined}
      listing={listing}
      requestConfig={requestConfig}
    />;
  }
  if (stayDemoModeEnabled(process.env)) {
    const example = findStayDemoExample(slug);
    if (example) return <StayPropertyDetailPage example={example} />;
  }
  notFound();
}
