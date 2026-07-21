declare const organizationIdBrand: unique symbol;

export type OrganizationId = string & {
  readonly [organizationIdBrand]: true;
};

export function isOrganizationId(value: string): boolean {
  return value.trim().length > 0;
}

export function createOrganizationId(value: string): OrganizationId {
  if (!isOrganizationId(value)) {
    throw new Error("Organization ID is required");
  }

  return value as OrganizationId;
}
