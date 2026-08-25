export const DATA_ENTRY_MAX_CLIENTS = 50;
export const DATA_ENTRY_MAX_PROPERTIES = 50;
export const DATA_ENTRY_MAX_IMAGES = 20;
export const DATA_ENTRY_MAX_TEXT_LENGTH = 20_000;
export const DATA_ENTRY_MAX_FIELD_LENGTH = 2_000;
export const DATA_ENTRY_MAX_CLIENT_NAME_LENGTH = 160;

export type DataEntryRole = "owner" | "manager" | "sales_agent" | "operations";
export type DataEntryConfidence = "high" | "medium" | "low";

export type DataEntryClientDraft = Readonly<{
  displayName: string | null;
  phone: string | null;
  whatsapp: string | null;
  email: string | null;
  nationality: string | null;
  preferredLanguage: string | null;
  notes: string | null;
  sourceLeadId: string | null;
  confidence: DataEntryConfidence;
  missingRequired: readonly string[];
}>;

export type DataEntryPropertyDraft = Readonly<{
  code: string | null;
  name: string | null;
  timezone: string | null;
  address: string | null;
  city: string | null;
  unitLabel: string | null;
  bedrooms: number | null;
  maxGuests: number | null;
  operationalNotes: string | null;
  imageInputIds: readonly string[];
  confidence: DataEntryConfidence;
  missingRequired: readonly string[];
}>;

export type DataEntryUnresolvedItem = Readonly<{ value: string; reason: string }>;

export type DataEntryPayload = Readonly<{
  clients: readonly DataEntryClientDraft[];
  properties: readonly DataEntryPropertyDraft[];
  unresolved: readonly DataEntryUnresolvedItem[];
  warnings: readonly string[];
}>;

export type DataEntryPayloadValidation =
  | Readonly<{ ok: true; value: DataEntryPayload }>
  | Readonly<{ ok: false; errors: readonly string[] }>;

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNullableText(value: unknown, maximum = DATA_ENTRY_MAX_FIELD_LENGTH): value is string | null {
  return value === null || (typeof value === "string" && value.length <= maximum);
}

function isConfidence(value: unknown): value is DataEntryConfidence {
  return value === "high" || value === "medium" || value === "low";
}

function isSafeNumber(value: unknown, minimum: number, maximum: number): value is number | null {
  return value === null || (typeof value === "number" && Number.isInteger(value) && value >= minimum && value <= maximum);
}

function hasRequiredText(value: string | null): boolean {
  return typeof value === "string" && value.trim().length > 0;
}

export function isDataEntryRole(role: string): role is DataEntryRole {
  return role === "owner" || role === "manager" || role === "sales_agent" || role === "operations";
}

export function missingRequiredClientFields(client: Pick<DataEntryClientDraft, "displayName">): readonly string[] {
  return hasRequiredText(client.displayName) ? [] : ["display_name"];
}

export function missingRequiredPropertyFields(property: Pick<DataEntryPropertyDraft, "code" | "name" | "timezone">): readonly string[] {
  return [
    ...(hasRequiredText(property.code) ? [] : ["code"]),
    ...(hasRequiredText(property.name) ? [] : ["name"]),
    ...(hasRequiredText(property.timezone) ? [] : ["timezone"]),
  ];
}

export function canConfirmDataEntryPayload(payload: DataEntryPayload): boolean {
  return payload.clients.every((client) => missingRequiredClientFields(client).length === 0)
    && payload.properties.every((property) => missingRequiredPropertyFields(property).length === 0);
}

export function validateDataEntryPayload(input: unknown, knownImageInputIds: readonly string[] = []): DataEntryPayloadValidation {
  if (!isRecord(input)) return { ok: false, errors: ["payload_not_object"] };
  const errors: string[] = [];
  if (!Array.isArray(input.clients)) errors.push("clients_not_array");
  if (!Array.isArray(input.properties)) errors.push("properties_not_array");
  if (!Array.isArray(input.unresolved)) errors.push("unresolved_not_array");
  if (!Array.isArray(input.warnings)) errors.push("warnings_not_array");
  if (errors.length > 0) return { ok: false, errors };
  const clients = input.clients as unknown[];
  const properties = input.properties as unknown[];
  const unresolved = input.unresolved as unknown[];
  const warnings = input.warnings as unknown[];
  if (clients.length > DATA_ENTRY_MAX_CLIENTS) errors.push("clients_limit");
  if (properties.length > DATA_ENTRY_MAX_PROPERTIES) errors.push("properties_limit");
  if (unresolved.length > DATA_ENTRY_MAX_CLIENTS + DATA_ENTRY_MAX_PROPERTIES) errors.push("unresolved_limit");
  if (warnings.length > DATA_ENTRY_MAX_CLIENTS + DATA_ENTRY_MAX_PROPERTIES) errors.push("warnings_limit");

  clients.forEach((client, index) => {
    if (!isRecord(client)) {
      errors.push(`client_${index}_not_object`);
      return;
    }
    if (!isNullableText(client.displayName, DATA_ENTRY_MAX_CLIENT_NAME_LENGTH)) errors.push(`client_${index}_displayName_invalid`);
    for (const key of ["phone", "whatsapp", "email", "nationality", "preferredLanguage", "notes", "sourceLeadId"]) {
      if (!isNullableText(client[key])) errors.push(`client_${index}_${key}_invalid`);
    }
    if (client.sourceLeadId !== null && typeof client.sourceLeadId === "string" && !UUID_PATTERN.test(client.sourceLeadId)) errors.push(`client_${index}_source_lead_id_invalid`);
    if (!isConfidence(client.confidence)) errors.push(`client_${index}_confidence_invalid`);
    if (!Array.isArray(client.missingRequired) || client.missingRequired.some((item) => typeof item !== "string" || item.length > 120)) errors.push(`client_${index}_missing_required_invalid`);
  });

  const knownImages = new Set(knownImageInputIds);
  const assignedImages = new Set<string>();
  properties.forEach((property, index) => {
    if (!isRecord(property)) {
      errors.push(`property_${index}_not_object`);
      return;
    }
    for (const key of ["code", "name", "timezone", "address", "city", "unitLabel", "operationalNotes"]) {
      if (!isNullableText(property[key])) errors.push(`property_${index}_${key}_invalid`);
    }
    if (!isSafeNumber(property.bedrooms, 0, 100)) errors.push(`property_${index}_bedrooms_invalid`);
    if (!isSafeNumber(property.maxGuests, 1, 1_000)) errors.push(`property_${index}_max_guests_invalid`);
    if (!Array.isArray(property.imageInputIds) || property.imageInputIds.some((item) => typeof item !== "string" || item.length > 120)) {
      errors.push(`property_${index}_image_inputs_invalid`);
    } else {
      if (property.imageInputIds.some((item) => !knownImages.has(item))) errors.push("unknown_image_input");
      for (const item of property.imageInputIds) {
        if (assignedImages.has(item)) errors.push("duplicate_image_input");
        assignedImages.add(item);
      }
    }
    if (!isConfidence(property.confidence)) errors.push(`property_${index}_confidence_invalid`);
    if (!Array.isArray(property.missingRequired) || property.missingRequired.some((item) => typeof item !== "string" || item.length > 120)) errors.push(`property_${index}_missing_required_invalid`);
  });

  unresolved.forEach((item, index) => {
    if (!isRecord(item) || typeof item.value !== "string" || item.value.length > DATA_ENTRY_MAX_FIELD_LENGTH || typeof item.reason !== "string" || item.reason.length > DATA_ENTRY_MAX_FIELD_LENGTH) errors.push(`unresolved_${index}_invalid`);
  });
  warnings.forEach((item, index) => {
    if (typeof item !== "string" || item.length > DATA_ENTRY_MAX_FIELD_LENGTH) errors.push(`warning_${index}_invalid`);
  });
  if (errors.length > 0) return { ok: false, errors: [...new Set(errors)] };
  return { ok: true, value: input as DataEntryPayload };
}
