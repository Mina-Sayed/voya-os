export const DATA_ENTRY_MAX_INPUTS = 20;
export const DATA_ENTRY_MAX_INPUT_BYTES = 25 * 1024 * 1024;

export type DataEntryWorkerInput = Readonly<{
  id: string;
  storageBucket: "ai-intake";
  storagePath: string;
  mimeType: "image/jpeg" | "image/png" | "image/webp";
  byteSize: number;
}>;

export type DataEntryWorkerInputValidation =
  | Readonly<{ ok: true; value: readonly DataEntryWorkerInput[] }>
  | Readonly<{ ok: false; errors: readonly string[] }>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, Math.min(offset + chunkSize, bytes.length)));
  }
  return btoa(binary);
}

export function validateDataEntryWorkerInputs(input: unknown): DataEntryWorkerInputValidation {
  if (!Array.isArray(input)) return { ok: false, errors: ["inputs_not_array"] };
  const errors: string[] = [];
  if (input.length > DATA_ENTRY_MAX_INPUTS) errors.push("input_count_limit");
  const normalized: DataEntryWorkerInput[] = [];
  let totalBytes = 0;
  input.forEach((value, index) => {
    if (!isRecord(value)) {
      errors.push(`input_${index}_not_object`);
      return;
    }
    const id = value.id;
    const bucket = value.storage_bucket;
    const path = value.storage_path;
    const mime = value.mime_type;
    const byteSize = value.byte_size;
    if (typeof id !== "string" || !id) errors.push(`input_${index}_id_invalid`);
    if (bucket !== "ai-intake") errors.push("unsupported_bucket");
    if (typeof path !== "string" || !path || path.length > 500) errors.push(`input_${index}_path_invalid`);
    if (mime !== "image/jpeg" && mime !== "image/png" && mime !== "image/webp") errors.push("unsupported_mime");
    if (typeof byteSize !== "number" || !Number.isSafeInteger(byteSize) || byteSize < 1 || byteSize > 10 * 1024 * 1024) errors.push(`input_${index}_size_invalid`);
    if (typeof byteSize === "number" && Number.isSafeInteger(byteSize) && byteSize > 0) totalBytes += byteSize;
    if (typeof id === "string" && id && bucket === "ai-intake" && typeof path === "string" && path && (mime === "image/jpeg" || mime === "image/png" || mime === "image/webp") && typeof byteSize === "number" && Number.isSafeInteger(byteSize) && byteSize > 0 && byteSize <= 10 * 1024 * 1024) {
      normalized.push({ id, storageBucket: "ai-intake", storagePath: path, mimeType: mime, byteSize });
    }
  });
  if (totalBytes > DATA_ENTRY_MAX_INPUT_BYTES) errors.push("input_bytes_limit");
  return errors.length > 0 ? { ok: false, errors: [...new Set(errors)] } : { ok: true, value: normalized };
}
