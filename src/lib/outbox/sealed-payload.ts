import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

const algorithm = "aes-256-gcm";
const version = "v1";

function decodeKey(value: string): Buffer {
  const trimmed = value.trim();
  const key = /^[0-9a-f]{64}$/u.test(trimmed)
    ? Buffer.from(trimmed, "hex")
    : /^[A-Za-z0-9+/]+={0,2}$/u.test(trimmed)
      ? Buffer.from(trimmed, "base64")
      : Buffer.alloc(0);
  if (key.byteLength !== 32) throw new Error("OUTBOX_PAYLOAD_ENCRYPTION_KEY must decode to 32 bytes.");
  return key;
}

function encode(value: Buffer): string {
  return value.toString("base64url");
}

function decode(value: string): Buffer {
  return Buffer.from(value, "base64url");
}

export function sealOutboxPayload(value: string, encryptionKey: string): string {
  if (!value || typeof value !== "string") throw new Error("sealed outbox payload value is required.");
  const key = decodeKey(encryptionKey);
  const iv = randomBytes(12);
  const cipher = createCipheriv(algorithm, key, iv);
  const ciphertext = Buffer.concat([cipher.update(value, "utf8"), cipher.final()]);
  const authTag = cipher.getAuthTag();
  return [version, encode(iv), encode(ciphertext), encode(authTag)].join(".");
}

export function unsealOutboxPayload(sealedValue: string, encryptionKey: string): string {
  try {
    const [payloadVersion, encodedIv, encodedCiphertext, encodedAuthTag] = sealedValue.split(".");
    if (payloadVersion !== version || !encodedIv || !encodedCiphertext || !encodedAuthTag) throw new Error("invalid format");
    const key = decodeKey(encryptionKey);
    const decipher = createDecipheriv(algorithm, key, decode(encodedIv));
    decipher.setAuthTag(decode(encodedAuthTag));
    return Buffer.concat([decipher.update(decode(encodedCiphertext)), decipher.final()]).toString("utf8");
  } catch {
    throw new Error("sealed outbox payload could not be decrypted.");
  }
}
