export type WorkerEnvironment = Readonly<Record<string, string | undefined>>;

export type OutboxWorkerConfig = Readonly<{
  supabaseUrl: string;
  supabaseServiceRoleKey: string;
  workerSecret: string;
  applicationUrl: string;
  encryptionKey: string;
  emailEnabled: boolean;
  resendApiKey: string | null;
  resendFrom: string | null;
  whatsappEnabled: boolean;
  metaWhatsAppAccessToken: string | null;
  metaGraphApiVersion: string;
}>;

function flag(environment: WorkerEnvironment, key: string): boolean {
  return environment[key]?.trim().toLowerCase() === "true";
}

function required(environment: WorkerEnvironment, key: string): string {
  const value = environment[key]?.trim();
  if (!value) throw new Error(`${key} is required for the outbox worker.`);
  return value;
}

function rootUrl(environment: WorkerEnvironment, key: string): string {
  const value = required(environment, key);
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error(`${key} must be a valid root URL.`);
  }
  if (parsed.pathname !== "/" || parsed.search || parsed.hash || parsed.username || parsed.password) {
    throw new Error(`${key} must be a root URL.`);
  }
  return parsed.toString().replace(/\/$/u, "");
}

function validEncryptionKey(value: string): boolean {
  if (/^[0-9a-f]{64}$/iu.test(value)) return true;
  if (!/^[A-Za-z0-9+/]+={0,2}$/u.test(value)) return false;
  try {
    return atob(value).length === 32;
  } catch {
    return false;
  }
}

export function readOutboxWorkerConfig(environment: WorkerEnvironment): OutboxWorkerConfig {
  const supabaseUrl = rootUrl(environment, "SUPABASE_URL");
  const supabaseServiceRoleKey = required(environment, "SUPABASE_SERVICE_ROLE_KEY");
  const workerSecret = required(environment, "OUTBOX_WORKER_SECRET");
  const applicationUrl = rootUrl(environment, "VOYA_APP_URL");
  const encryptionKey = required(environment, "OUTBOX_PAYLOAD_ENCRYPTION_KEY");
  if (!validEncryptionKey(encryptionKey)) throw new Error("OUTBOX_PAYLOAD_ENCRYPTION_KEY must decode to 32 bytes.");

  const emailEnabled = flag(environment, "RESEND_ENABLED");
  const resendApiKey = environment.RESEND_API_KEY?.trim() || null;
  const resendFrom = environment.RESEND_FROM?.trim() || null;
  if (emailEnabled && (!resendApiKey || !resendFrom)) throw new Error("RESEND_API_KEY and RESEND_FROM are required when email delivery is enabled.");

  const whatsappEnabled = flag(environment, "WHATSAPP_OUTBOUND_ENABLED") && flag(environment, "HUMAN_HANDOFF_APPROVED");
  const metaWhatsAppAccessToken = environment.META_WHATSAPP_ACCESS_TOKEN?.trim() || null;
  const metaGraphApiVersion = environment.META_GRAPH_API_VERSION?.trim() || "v21.0";
  if (whatsappEnabled && !metaWhatsAppAccessToken) throw new Error("META_WHATSAPP_ACCESS_TOKEN is required when WhatsApp delivery is enabled.");
  if (!/^v[0-9]+(?:\.[0-9]+)?$/u.test(metaGraphApiVersion)) throw new Error("META_GRAPH_API_VERSION is invalid.");

  return {
    supabaseUrl,
    supabaseServiceRoleKey,
    workerSecret,
    applicationUrl,
    encryptionKey,
    emailEnabled,
    resendApiKey,
    resendFrom,
    whatsappEnabled,
    metaWhatsAppAccessToken,
    metaGraphApiVersion,
  };
}

export function authorizeOutboxWorkerRequest(authorizationHeader: string | null, workerSecret: string): boolean {
  const expected = workerSecret.trim();
  const supplied = authorizationHeader?.startsWith("Bearer ") ? authorizationHeader.slice("Bearer ".length).trim() : "";
  if (!expected || supplied.length !== expected.length) return false;
  let difference = 0;
  for (let index = 0; index < expected.length; index += 1) difference |= supplied.charCodeAt(index) ^ expected.charCodeAt(index);
  return difference === 0;
}
