import type { Metadata } from "next";
import { parseStaySearchCriteria } from "@/features/stay/stay-search-criteria";
import { stayDemoModeEnabled } from "@/features/stay/stay-demo-mode";
import { StayLiveSearchPage, StaySearchExamplesPage, demoMetadata, metadata as liveMetadata } from "@/features/stay/stay-search-page";
import { listVoyaStayPublicListings } from "@/lib/stay/public-catalog";

type SearchPageProps = Readonly<{
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}>;

export async function generateMetadata(): Promise<Metadata> {
  return stayDemoModeEnabled(process.env) ? demoMetadata : liveMetadata;
}

export default async function StaySearchPage({ searchParams }: SearchPageProps) {
  const rawParams = await searchParams;
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(rawParams)) {
    if (typeof value === "string") params.set(key, value);
    else if (Array.isArray(value)) value.forEach((item) => params.append(key, item));
  }
  const criteria = parseStaySearchCriteria(params);
  if (!criteria) {
    return <StayLiveSearchPage criteria={{ destination: null, checkIn: null, checkOut: null, guests: null, bedrooms: null }} invalidSearch listings={[]} />;
  }
  const listings = await listVoyaStayPublicListings(criteria);
  if (listings.length === 0 && stayDemoModeEnabled(process.env)) return <StaySearchExamplesPage />;
  return <StayLiveSearchPage criteria={criteria} listings={listings} />;
}
