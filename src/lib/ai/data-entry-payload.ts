// eslint-disable-next-line @typescript-eslint/ban-ts-comment
// @ts-ignore -- Node typecheck disallows explicit TypeScript extensions; Deno resolves them directly.
import { DATA_ENTRY_MAX_FIELD_LENGTH, DATA_ENTRY_MAX_TEXT_LENGTH, missingRequiredClientFields, missingRequiredPropertyFields, validateDataEntryPayload, type DataEntryClientDraft, type DataEntryPayload, type DataEntryPropertyDraft, type DataEntryUnresolvedItem } from "../../domain/ai/data-entry-contract.ts";

export type DataEntryPayloadParseResult =
  | Readonly<{ ok: true; value: DataEntryPayload }>
  | Readonly<{ ok: false; errors: readonly string[] }>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function nullableText(value: unknown, errors: string[], errorCode: string): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "string") {
    errors.push(errorCode);
    return null;
  }
  return value.trim().slice(0, DATA_ENTRY_MAX_FIELD_LENGTH) || null;
}

function stringList(value: unknown, errors: string[], errorCode: string): string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    errors.push(errorCode);
    return [];
  }
  return value.map((item) => item.trim()).filter(Boolean).slice(0, 20);
}

function unknownKeys(value: Record<string, unknown>, allowed: readonly string[], errorCode: string, errors: string[]): void {
  const allowedKeys = new Set(allowed);
  if (Object.keys(value).some((key) => !allowedKeys.has(key))) errors.push(errorCode);
}

export function parseEditableDataEntryPayload(input: unknown, knownImageInputIds: readonly string[] = []): DataEntryPayloadParseResult {
  if (!isRecord(input)) return { ok: false, errors: ["payload_not_object"] };
  let serializedLength = 0;
  try { serializedLength = JSON.stringify(input).length; } catch { return { ok: false, errors: ["payload_invalid"] }; }
  if (serializedLength > DATA_ENTRY_MAX_TEXT_LENGTH) return { ok: false, errors: ["payload_too_large"] };
  const errors: string[] = [];
  unknownKeys(input, ["clients", "properties", "unresolved", "warnings"], "unknown_payload_key", errors);
  if (!Array.isArray(input.clients)) errors.push("clients_not_array");
  if (!Array.isArray(input.properties)) errors.push("properties_not_array");
  if (!Array.isArray(input.unresolved)) errors.push("unresolved_not_array");
  if (!Array.isArray(input.warnings)) errors.push("warnings_not_array");
  if (errors.length > 0) return { ok: false, errors: [...new Set(errors)] };
  (input.clients as unknown[]).forEach((client, index) => {
    if (isRecord(client)) unknownKeys(client, ["displayName", "phone", "whatsapp", "email", "nationality", "preferredLanguage", "notes", "sourceLeadId", "confidence", "missingRequired"], "unknown_client_key", errors);
    else errors.push(`client_${index}_not_object`);
  });
  (input.properties as unknown[]).forEach((property, index) => {
    if (isRecord(property)) unknownKeys(property, ["code", "name", "timezone", "address", "city", "unitLabel", "bedrooms", "maxGuests", "operationalNotes", "imageInputIds", "confidence", "missingRequired"], "unknown_property_key", errors);
    else errors.push(`property_${index}_not_object`);
  });
  const validation = validateDataEntryPayload(input, knownImageInputIds);
  if (!validation.ok) errors.push(...validation.errors);
  return errors.length > 0 ? { ok: false, errors: [...new Set(errors)] } : { ok: true, value: input as DataEntryPayload };
}

function confidence(value: unknown, errors: string[], errorCode: string): "high" | "medium" | "low" {
  if (value === "high" || value === "medium" || value === "low") return value;
  errors.push(errorCode);
  return "medium";
}

function integerOrNull(value: unknown, errors: string[], errorCode: string): number | null {
  if (value === null || value === undefined) return null;
  if (typeof value !== "number" || !Number.isInteger(value)) {
    errors.push(errorCode);
    return null;
  }
  return value;
}

function normalizeClient(value: unknown, index: number, errors: string[]): DataEntryClientDraft {
  const client = isRecord(value) ? value : {};
  if (!isRecord(value)) errors.push(`client_${index}_not_object`);
  unknownKeys(client, ["display_name", "phone", "whatsapp", "email", "nationality", "preferred_language", "notes", "source_lead_id", "confidence", "missing_required"], "unknown_client_key", errors);
  const normalized: DataEntryClientDraft = {
    displayName: nullableText(client.display_name, errors, `client_${index}_display_name_invalid`),
    phone: nullableText(client.phone, errors, `client_${index}_phone_invalid`),
    whatsapp: nullableText(client.whatsapp, errors, `client_${index}_whatsapp_invalid`),
    email: nullableText(client.email, errors, `client_${index}_email_invalid`),
    nationality: nullableText(client.nationality, errors, `client_${index}_nationality_invalid`),
    preferredLanguage: nullableText(client.preferred_language, errors, `client_${index}_preferred_language_invalid`),
    notes: nullableText(client.notes, errors, `client_${index}_notes_invalid`),
    sourceLeadId: nullableText(client.source_lead_id, errors, `client_${index}_source_lead_id_invalid`),
    confidence: confidence(client.confidence, errors, `client_${index}_confidence_invalid`),
    missingRequired: stringList(client.missing_required, errors, `client_${index}_missing_required_invalid`),
  };
  return { ...normalized, missingRequired: [...new Set([...normalized.missingRequired, ...missingRequiredClientFields(normalized)])] };
}

function normalizeProperty(value: unknown, index: number, errors: string[]): DataEntryPropertyDraft {
  const property = isRecord(value) ? value : {};
  if (!isRecord(value)) errors.push(`property_${index}_not_object`);
  unknownKeys(property, ["code", "name", "timezone", "address", "city", "unit_label", "bedrooms", "max_guests", "operational_notes", "image_input_ids", "confidence", "missing_required"], "unknown_property_key", errors);
  const normalized: DataEntryPropertyDraft = {
    code: nullableText(property.code, errors, `property_${index}_code_invalid`),
    name: nullableText(property.name, errors, `property_${index}_name_invalid`),
    timezone: nullableText(property.timezone, errors, `property_${index}_timezone_invalid`),
    address: nullableText(property.address, errors, `property_${index}_address_invalid`),
    city: nullableText(property.city, errors, `property_${index}_city_invalid`),
    unitLabel: nullableText(property.unit_label, errors, `property_${index}_unit_label_invalid`),
    bedrooms: integerOrNull(property.bedrooms, errors, `property_${index}_bedrooms_invalid`),
    maxGuests: integerOrNull(property.max_guests, errors, `property_${index}_max_guests_invalid`),
    operationalNotes: nullableText(property.operational_notes, errors, `property_${index}_operational_notes_invalid`),
    imageInputIds: stringList(property.image_input_ids, errors, `property_${index}_image_inputs_invalid`),
    confidence: confidence(property.confidence, errors, `property_${index}_confidence_invalid`),
    missingRequired: stringList(property.missing_required, errors, `property_${index}_missing_required_invalid`),
  };
  return { ...normalized, missingRequired: [...new Set([...normalized.missingRequired, ...missingRequiredPropertyFields(normalized)])] };
}

function normalizeUnresolved(value: unknown, errors: string[]): DataEntryUnresolvedItem[] {
  if (value === undefined) return [];
  if (!Array.isArray(value)) {
    errors.push("unresolved_not_array");
    return [];
  }
  return value.flatMap((item, index) => {
    if (!isRecord(item) || typeof item.value !== "string" || typeof item.reason !== "string") {
      errors.push(`unresolved_${index}_invalid`);
      return [];
    }
    return [{ value: item.value.trim().slice(0, DATA_ENTRY_MAX_FIELD_LENGTH), reason: item.reason.trim().slice(0, DATA_ENTRY_MAX_FIELD_LENGTH) }];
  }).slice(0, 100);
}

export function parseDataEntryPayload(raw: string, knownImageInputIds: readonly string[] = []): DataEntryPayloadParseResult {
  if (raw.length > DATA_ENTRY_MAX_TEXT_LENGTH) return { ok: false, errors: ["payload_too_large"] };
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw) as unknown;
  } catch {
    return { ok: false, errors: ["invalid_json"] };
  }
  if (!isRecord(parsed)) return { ok: false, errors: ["payload_not_object"] };
  const errors: string[] = [];
  unknownKeys(parsed, ["clients", "properties", "unresolved", "warnings"], "unknown_payload_key", errors);
  const clients = Array.isArray(parsed.clients) ? parsed.clients.map((item, index) => normalizeClient(item, index, errors)) : [];
  if (!Array.isArray(parsed.clients)) errors.push("clients_not_array");
  const properties = Array.isArray(parsed.properties) ? parsed.properties.map((item, index) => normalizeProperty(item, index, errors)) : [];
  if (!Array.isArray(parsed.properties)) errors.push("properties_not_array");
  const payload: DataEntryPayload = {
    clients,
    properties,
    unresolved: normalizeUnresolved(parsed.unresolved, errors),
    warnings: stringList(parsed.warnings, errors, "warnings_not_array"),
  };
  const validation = validateDataEntryPayload(payload, knownImageInputIds);
  if (!validation.ok) errors.push(...validation.errors);
  if (errors.length > 0) return { ok: false, errors: [...new Set(errors)] };
  return { ok: true, value: payload };
}
