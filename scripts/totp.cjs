// The harness imports this CommonJS helper from both Node ESM and TypeScript.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const { createHmac } = require("node:crypto");

const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

function generateTotpCode(secret, timestampMs = Date.now()) {
  if (typeof secret !== "string" || secret.trim() === "") throw new Error("TOTP secret is required.");
  const normalized = secret.replace(/\s+/g, "").toUpperCase();
  if (!/^[A-Z2-7]+=*$/.test(normalized)) throw new Error("TOTP secret must be base32 encoded.");

  let bitBuffer = 0;
  let bitCount = 0;
  const keyBytes = [];
  for (const character of normalized.replace(/=+$/, "")) {
    const value = BASE32_ALPHABET.indexOf(character);
    if (value < 0) throw new Error("TOTP secret contains an invalid base32 character.");
    bitBuffer = (bitBuffer << 5) | value;
    bitCount += 5;
    while (bitCount >= 8) {
      bitCount -= 8;
      keyBytes.push((bitBuffer >> bitCount) & 0xff);
      bitBuffer &= bitCount === 0 ? 0 : (1 << bitCount) - 1;
    }
  }
  if (keyBytes.length === 0) throw new Error("TOTP secret is empty.");

  const counter = Math.floor(Number(timestampMs) / 1000 / 30);
  if (!Number.isSafeInteger(counter) || counter < 0) throw new Error("TOTP timestamp is invalid.");
  const counterBuffer = Buffer.alloc(8);
  counterBuffer.writeBigUInt64BE(BigInt(counter));
  const digest = createHmac("sha1", Buffer.from(keyBytes)).update(counterBuffer).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  const value = (digest.readUInt32BE(offset) & 0x7fffffff) % 1_000_000;
  return String(value).padStart(6, "0");
}

module.exports = { generateTotpCode };
