export type DataEntryApplicationItem = Readonly<{
  index: number;
  recordId?: string;
  errorCode?: string;
}>;

export type DataEntryApplicationImageItem = Readonly<{
  propertyIndex: number;
  inputId: string;
  recordId?: string;
  errorCode?: string;
}>;

export type DataEntryApplicationResult = Readonly<{
  clients: readonly DataEntryApplicationItem[];
  properties: readonly DataEntryApplicationItem[];
  images: readonly DataEntryApplicationImageItem[];
}>;

export const DATA_ENTRY_EXCLUDED_BY_OPERATOR = "excluded_by_operator";

export function emptyDataEntryApplicationResult(): DataEntryApplicationResult {
  return { clients: [], properties: [], images: [] };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function optionalText(value: unknown): string | undefined {
  return typeof value === "string" && value.length > 0 && value.length <= 160 ? value : undefined;
}

function applicationItem(value: unknown): DataEntryApplicationItem | null {
  if (!isRecord(value) || !Number.isSafeInteger(value.index) || (value.index as number) < 0) return null;
  const recordId = optionalText(value.recordId);
  const errorCode = optionalText(value.errorCode);
  if (!recordId && !errorCode) return null;
  return { index: value.index as number, ...(recordId ? { recordId } : {}), ...(errorCode ? { errorCode } : {}) };
}

function imageItem(value: unknown): DataEntryApplicationImageItem | null {
  if (!isRecord(value) || !Number.isSafeInteger(value.propertyIndex) || (value.propertyIndex as number) < 0 || typeof value.inputId !== "string" || value.inputId.length === 0 || value.inputId.length > 160) return null;
  const recordId = optionalText(value.recordId);
  const errorCode = optionalText(value.errorCode);
  if (!recordId && !errorCode) return null;
  return {
    propertyIndex: value.propertyIndex as number,
    inputId: value.inputId,
    ...(recordId ? { recordId } : {}),
    ...(errorCode ? { errorCode } : {}),
  };
}

export function parseDataEntryApplicationResult(value: unknown): DataEntryApplicationResult {
  if (!isRecord(value)) return emptyDataEntryApplicationResult();
  const clients = Array.isArray(value.clients) ? value.clients.map(applicationItem).filter((item): item is DataEntryApplicationItem => item !== null) : [];
  const properties = Array.isArray(value.properties) ? value.properties.map(applicationItem).filter((item): item is DataEntryApplicationItem => item !== null) : [];
  const images = Array.isArray(value.images) ? value.images.map(imageItem).filter((item): item is DataEntryApplicationImageItem => item !== null) : [];
  return { clients, properties, images };
}

function mergeItems(previous: readonly DataEntryApplicationItem[], current: readonly DataEntryApplicationItem[]): DataEntryApplicationItem[] {
  const merged = new Map<number, DataEntryApplicationItem>();
  for (const item of previous) merged.set(item.index, item);
  for (const item of current) merged.set(item.index, item);
  return [...merged.values()].sort((left, right) => left.index - right.index);
}

function mergeImages(previous: readonly DataEntryApplicationImageItem[], current: readonly DataEntryApplicationImageItem[]): DataEntryApplicationImageItem[] {
  const merged = new Map<string, DataEntryApplicationImageItem>();
  for (const item of previous) merged.set(`${item.propertyIndex}:${item.inputId}`, item);
  for (const item of current) merged.set(`${item.propertyIndex}:${item.inputId}`, item);
  return [...merged.values()].sort((left, right) => left.propertyIndex - right.propertyIndex || left.inputId.localeCompare(right.inputId));
}

export function mergeDataEntryApplicationResults(previous: DataEntryApplicationResult, current: DataEntryApplicationResult): DataEntryApplicationResult {
  return {
    clients: mergeItems(previous.clients, current.clients),
    properties: mergeItems(previous.properties, current.properties),
    images: mergeImages(previous.images, current.images),
  };
}

export function successfulClientIndexes(result: DataEntryApplicationResult): ReadonlySet<number> {
  return new Set(result.clients.filter((item) => item.recordId).map((item) => item.index));
}

export function successfulPropertyIndexes(result: DataEntryApplicationResult): ReadonlySet<number> {
  return new Set(result.properties.filter((item) => item.recordId).map((item) => item.index));
}

export function successfulImageKeys(result: DataEntryApplicationResult): ReadonlySet<string> {
  return new Set(result.images.filter((item) => item.recordId).map((item) => `${item.propertyIndex}:${item.inputId}`));
}

export function excludedClientIndexes(result: DataEntryApplicationResult): ReadonlySet<number> {
  return new Set(result.clients.filter((item) => item.errorCode === DATA_ENTRY_EXCLUDED_BY_OPERATOR).map((item) => item.index));
}

export function excludedPropertyIndexes(result: DataEntryApplicationResult): ReadonlySet<number> {
  return new Set(result.properties.filter((item) => item.errorCode === DATA_ENTRY_EXCLUDED_BY_OPERATOR).map((item) => item.index));
}

export function terminalDataEntryApplicationResult(result: DataEntryApplicationResult): DataEntryApplicationResult {
  return {
    clients: result.clients.filter((item) => item.recordId || item.errorCode === DATA_ENTRY_EXCLUDED_BY_OPERATOR),
    properties: result.properties.filter((item) => item.recordId || item.errorCode === DATA_ENTRY_EXCLUDED_BY_OPERATOR),
    images: result.images.filter((item) => item.recordId),
  };
}
