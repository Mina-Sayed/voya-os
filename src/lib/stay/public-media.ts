import sharp from "sharp";

const MAX_PRIVATE_IMAGE_BYTES = 10 * 1024 * 1024;
const MAX_PUBLIC_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_IMAGE_PIXELS = 40_000_000;
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;

export function readPublicStayImageIds(formData: FormData): readonly string[] | null {
  const rawIds = formData.getAll("image_id");
  if (rawIds.length < 1 || rawIds.length > 12) return null;
  const imageIds: string[] = [];
  for (const value of rawIds) {
    if (typeof value !== "string") return null;
    imageIds.push(value.trim());
  }
  if (imageIds.some((value) => !uuidPattern.test(value)) || new Set(imageIds).size !== imageIds.length) return null;
  return imageIds;
}

export async function transformStayImageForPublication(source: Uint8Array): Promise<Buffer> {
  if (source.byteLength < 1 || source.byteLength > MAX_PRIVATE_IMAGE_BYTES) {
    throw new Error("Private image is outside the allowed size limit.");
  }

  const { data } = await sharp(Buffer.from(source), {
    failOn: "warning",
    limitInputPixels: MAX_IMAGE_PIXELS,
    animated: false,
  })
    .rotate()
    .resize({ width: 2000, height: 1500, fit: "inside", withoutEnlargement: true })
    .webp({ quality: 82, effort: 4 })
    .toBuffer({ resolveWithObject: true });

  if (data.byteLength < 1 || data.byteLength > MAX_PUBLIC_IMAGE_BYTES) {
    throw new Error("Transformed public image is outside the allowed size limit.");
  }
  return data;
}
