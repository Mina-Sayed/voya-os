export function resolveMfaQrImageSource(qrCode: string): string {
  const value = qrCode.trim();
  if (value.startsWith("data:image/")) return value;
  return `data:image/svg+xml;utf-8,${encodeURIComponent(value)}`;
}
