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

type PropertyImageRpcRecord = Readonly<{ id: string }>;

type PropertyOwnerRpcRecord = Readonly<{
  id: string;
  display_name: string;
  status: "active" | "inactive" | "archived";
}>;

async function loadProperties(membership: Awaited<ReturnType<typeof requireWorkspaceMembership>>): Promise<PropertyListItem[]> {
  {
    const client = await createServerSupabaseClient();
    const { data, error } = await client.rpc("list_properties_v1_extended", {
      p_organization_id: membership.organizationId,
    });
    if (error) throwWorkspaceOperationError("workspace.properties.read", error);

    const records = ((data ?? []) as PropertyRpcRecord[]).map((property) => ({
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
    return Promise.all(records.map(async (property) => {
      let imageClient = client;
      let { data: imageData, error: imageError } = await imageClient.rpc("list_property_images_v1", {
        p_organization_id: membership.organizationId,
        p_property_id: property.id,
      });

      // A Server Action can rotate the auth cookie while its revalidated page
      // is rendering. A stale client may then reach the tenant RPC with no
      // usable auth.uid(), which surfaces as 42501. Re-verify once on a fresh
      // SSR client before treating the read as a real authorization failure.
      if (imageError?.code === "42501") {
        imageClient = await createServerSupabaseClient();
        const userResult = await imageClient.auth.getUser();
        if (!userResult.error && userResult.data.user) {
          ({ data: imageData, error: imageError } = await imageClient.rpc("list_property_images_v1", {
            p_organization_id: membership.organizationId,
            p_property_id: property.id,
          }));
        }
      }
      if (imageError) throwWorkspaceOperationError("workspace.property.images.read", imageError);
      return { ...property, imageIds: ((imageData ?? []) as PropertyImageRpcRecord[]).map((image) => image.id) };
    }));
  }
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

export default async function PropertiesWorkspacePage() {
  const membership = await requireWorkspaceMembership();
  const [properties, ownerChoices] = await Promise.all([loadProperties(membership), loadPropertyOwnerChoices(membership)]);
  const canManage = ["owner", "manager", "operations"].includes(membership.role);
  return <WorkspaceShell activeHref="/workspace/properties" organizationName={membership.organizationName} role={membership.role}><PropertiesPage archiveProperty={canManage ? archivePropertyAction : undefined} assignPropertyOwner={canManage ? assignPropertyOwnerAction : undefined} canManage={canManage} createProperty={canManage ? createPropertyAction : undefined} ownerChoices={ownerChoices} properties={properties} updateProperty={canManage ? updatePropertyAction : undefined} uploadPropertyImage={canManage ? uploadPropertyImageAction : undefined} /></WorkspaceShell>;
}
