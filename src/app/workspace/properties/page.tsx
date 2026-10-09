import { requireWorkspaceMembership } from "@/features/auth/require-workspace-membership";
import { throwWorkspaceOperationError } from "@/features/auth/workspace-context";
import { PropertiesPage, type PropertyListItem, type PropertyOwnerChoice } from "@/features/properties/properties-page";
import { WorkspaceShell } from "@/features/workspace/workspace-shell";
import { createServerSupabaseClient } from "@/lib/supabase/server-auth";
import { archivePropertyAction, assignPropertyOwnerAction, createPropertyAction, updatePropertyAction, uploadPropertyImageAction } from "./actions";

type PropertyRpcRecord = Readonly<{
  id: string;
  code: string;
  name: string;
  timezone: string;
  address: string | null;
  city: string | null;
  unit_label: string | null;
  bedrooms: number | null;
  max_guests: number | null;
  operational_notes: string | null;
  bathrooms: number | null;
  area_sqm: number | null;
  floor: string | null;
  furnished: boolean | null;
  district: string | null;
  rent_daily: boolean;
  rent_weekly: boolean;
  rent_monthly: boolean;
  daily_price: number | null;
  weekly_price: number | null;
  monthly_price: number | null;
  currency: string | null;
  amenities: string[] | null;
  minimum_stay_nights: number | null;
  marketing_description: string | null;
  status: "active" | "inactive" | "archived";
  version: number;
  created_at: string;
  updated_at: string;
  archived_at: string | null;
  current_property_owner_name: string | null;
  image_count: number;
}>;

type PropertyPageRpcRecord = Readonly<{ property_data: PropertyRpcRecord; created_at: string; id: string }>;
type PropertyImageRpcRecord = Readonly<{ property_id: string; image_ids: string[] }>;
type PropertyOwnerRpcRecord = Readonly<{
  id: string;
  display_name: string;
  status: "active" | "inactive" | "archived";
}>;

const PROPERTY_PAGE_SIZE = 50;

async function loadProperties(
  membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>,
  cursor: Readonly<{ createdAt: string; id: string }> | null,
): Promise<Readonly<{ properties: PropertyListItem[]; nextCursor: string | null }>> {
  let client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("list_properties_v1_page", {
    p_organization_id: membership.organizationId,
    p_after_created_at: cursor?.createdAt ?? null,
    p_after_id: cursor?.id ?? null,
    p_limit: PROPERTY_PAGE_SIZE + 1,
  });
  if (error) throwWorkspaceOperationError("workspace.properties.read", error);

  const fetchedRows = (data ?? []) as PropertyPageRpcRecord[];
  const rows = fetchedRows.slice(0, PROPERTY_PAGE_SIZE);
  const hasMore = fetchedRows.length > PROPERTY_PAGE_SIZE;
  const records = rows.map(({ property_data: property }) => ({
    id: property.id,
    code: property.code,
    name: property.name,
    timezone: property.timezone,
    address: property.address,
    city: property.city,
    unitLabel: property.unit_label,
    bedrooms: property.bedrooms,
    maxGuests: property.max_guests,
    operationalNotes: property.operational_notes,
    bathrooms: property.bathrooms,
    areaSqm: property.area_sqm,
    floor: property.floor,
    furnished: property.furnished,
    district: property.district,
    rentDaily: property.rent_daily,
    rentWeekly: property.rent_weekly,
    rentMonthly: property.rent_monthly,
    dailyPrice: property.daily_price,
    weeklyPrice: property.weekly_price,
    monthlyPrice: property.monthly_price,
    currency: property.currency,
    amenities: property.amenities,
    minimumStayNights: property.minimum_stay_nights,
    marketingDescription: property.marketing_description,
    status: property.status,
    version: property.version,
    createdAt: property.created_at,
    updatedAt: property.updated_at,
    archivedAt: property.archived_at,
    currentPropertyOwnerName: property.current_property_owner_name,
    imageCount: property.image_count,
    imageIds: [] as readonly string[],
  }));

  let imageResult = records.length > 0
    ? await client.rpc("list_property_image_ids_v1", {
      p_organization_id: membership.organizationId,
      p_property_ids: records.map((property) => property.id),
    })
    : { data: [], error: null };
  // Re-verify once on a fresh SSR client after cookie rotation before treating
  // an AAL2 denial from the stale client as a real workspace authorization failure.
  if (imageResult.error?.code === "42501") {
    client = await createServerSupabaseClient();
    const userResult = await client.auth.getUser();
    if (!userResult.error && userResult.data.user && records.length > 0) {
      imageResult = await client.rpc("list_property_image_ids_v1", {
        p_organization_id: membership.organizationId,
        p_property_ids: records.map((property) => property.id),
      });
    }
  }
  if (imageResult.error) throwWorkspaceOperationError("workspace.property.images.read", imageResult.error);
  const imageIdsByProperty = new Map(((imageResult.data ?? []) as PropertyImageRpcRecord[]).map((item) => [item.property_id, item.image_ids]));
  const properties = records.map((property) => ({ ...property, imageIds: imageIdsByProperty.get(property.id) ?? [] }));
  const lastRow = rows.at(-1);
  return { properties, nextCursor: hasMore && lastRow ? `${lastRow.created_at}|${lastRow.id}` : null };
}

async function loadPropertyOwnerChoices(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<PropertyOwnerChoice[]> {
  const client = await createServerSupabaseClient();
  const { data, error } = await client.rpc("list_property_owners_v1", {
    p_organization_id: membership.organizationId,
  });
  if (error) throwWorkspaceOperationError("workspace.property_owners.read", error);
  return ((data ?? []) as PropertyOwnerRpcRecord[])
    .filter((owner) => owner.status === "active")
    .map((owner) => ({ id: owner.id, displayName: owner.display_name }));
}

function parsePropertyCursor(value: string | string[] | undefined): Readonly<{ createdAt: string; id: string }> | null {
  if (typeof value !== "string" || value.length > 160) return null;
  const separator = value.lastIndexOf("|");
  if (separator < 1) return null;
  const createdAt = value.slice(0, separator);
  const id = value.slice(separator + 1);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/u.test(createdAt)
    || !Number.isFinite(Date.parse(createdAt))
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(id)) return null;
  return { createdAt, id };
}

export default async function PropertiesWorkspacePage({
  searchParams,
}: Readonly<{ searchParams: Promise<{ after?: string | string[] }> }>) {
  const query = await searchParams;
  const cursor = parsePropertyCursor(query.after);
  const membership = await requireWorkspaceMembership();
  const [pageData, ownerChoices] = await Promise.all([
    loadProperties(membership, cursor),
    loadPropertyOwnerChoices(membership),
  ]);
  const canManage = ["owner", "manager", "operations"].includes(membership.role);
  return <WorkspaceShell activeHref="/workspace/properties" organizationName={membership.organizationName} role={membership.role}><PropertiesPage archiveProperty={canManage ? archivePropertyAction : undefined} assignPropertyOwner={canManage ? assignPropertyOwnerAction : undefined} canManage={canManage} createProperty={canManage ? createPropertyAction : undefined} nextCursor={pageData.nextCursor} ownerChoices={ownerChoices} properties={pageData.properties} updateProperty={canManage ? updatePropertyAction : undefined} uploadPropertyImage={canManage ? uploadPropertyImageAction : undefined} /></WorkspaceShell>;
}
