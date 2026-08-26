export type WebMCPToolAnnotations = Readonly<{
  readOnlyHint?: boolean;
  untrustedContentHint?: boolean;
}>;

export type WebMCPExecutionContext = Readonly<{
  signal?: AbortSignal;
}>;

export type WebMCPTool = Readonly<{
  name: string;
  title?: string;
  description: string;
  inputSchema?: Readonly<Record<string, unknown>>;
  execute: (input: Record<string, unknown>, context?: WebMCPExecutionContext) => Promise<unknown>;
  annotations?: WebMCPToolAnnotations;
}>;

export type WebMCPModelContext = Readonly<{
  registerTool: (
    tool: WebMCPTool,
    options?: Readonly<{ signal?: AbortSignal; exposedTo?: readonly string[] }>,
  ) => Promise<void>;
}>;

export type VoyaWebMCPToolName =
  | "search_properties"
  | "search_clients"
  | "check_property_availability"
  | "calculate_booking_quote"
  | "create_booking_draft";

export type VoyaWebMCPInvoker = (
  tool: VoyaWebMCPToolName,
  input: Record<string, unknown>,
  signal?: AbortSignal,
) => Promise<unknown>;

type SiteToolDefinition = Omit<WebMCPTool, "execute"> & Readonly<{
  serverTool: VoyaWebMCPToolName;
}>;

const siteToolDefinitions: readonly SiteToolDefinition[] = [
  {
    name: "voya_search_properties",
    title: "Search VOYA properties",
    description: "Search active VOYA properties visible to the signed-in workspace user by text, city, bedrooms, and guest capacity. This tool does not invent or infer property pricing.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", maxLength: 160, description: "Optional text matching property code, name, address, city, unit label, or current owner name." },
        city: { type: "string", maxLength: 120, description: "Optional city or area text." },
        bedrooms: { type: "integer", minimum: 0, maximum: 100 },
        minGuests: { type: "integer", minimum: 1, maximum: 1000 },
        limit: { type: "integer", minimum: 1, maximum: 50, default: 20 },
      },
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, untrustedContentHint: true },
    serverTool: "search_properties",
  },
  {
    name: "voya_search_clients",
    title: "Search VOYA clients",
    description: "Search clients visible to the signed-in VOYA workspace. Use this to resolve a client before creating a booking draft.",
    inputSchema: {
      type: "object",
      properties: {
        query: { type: "string", minLength: 1, maxLength: 160, description: "Client name, phone, WhatsApp number, or email text." },
        limit: { type: "integer", minimum: 1, maximum: 50, default: 20 },
      },
      required: ["query"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, untrustedContentHint: true },
    serverTool: "search_clients",
  },
  {
    name: "voya_check_property_availability",
    title: "Check property availability",
    description: "Check whether an active VOYA property has a confirmed occupancy or availability block overlapping a date range. Draft and pending-approval bookings do not lock inventory.",
    inputSchema: {
      type: "object",
      properties: {
        propertyId: { type: "string", format: "uuid" },
        checkIn: { type: "string", format: "date" },
        checkOut: { type: "string", format: "date" },
      },
      required: ["propertyId", "checkIn", "checkOut"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true, untrustedContentHint: true },
    serverTool: "check_property_availability",
  },
  {
    name: "voya_calculate_booking_quote",
    title: "Calculate booking quote",
    description: "Calculate a proposed booking total from a caller-provided nightly rate and date range. The nightly rate is not read from VOYA inventory and must be supplied explicitly.",
    inputSchema: {
      type: "object",
      properties: {
        checkIn: { type: "string", format: "date" },
        checkOut: { type: "string", format: "date" },
        nightlyRateMinor: { type: "string", pattern: "^[0-9]{1,19}$", description: "Nightly rate in minor currency units, for example 250000 for EGP 2,500.00." },
        currency: { type: "string", pattern: "^[A-Z]{3}$" },
      },
      required: ["checkIn", "checkOut", "nightlyRateMinor", "currency"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: true },
    serverTool: "calculate_booking_quote",
  },
  {
    name: "voya_create_booking_draft",
    title: "Create booking draft",
    description: "Create a draft commercial booking in VOYA for a resolved property and client. This does not request approval, confirm inventory, take payment, or send a message.",
    inputSchema: {
      type: "object",
      properties: {
        propertyId: { type: "string", format: "uuid" },
        clientId: { type: "string", format: "uuid" },
        checkIn: { type: "string", format: "date" },
        checkOut: { type: "string", format: "date" },
        amountMinor: { type: "string", pattern: "^[0-9]{1,19}$" },
        currency: { type: "string", pattern: "^[A-Z]{3}$" },
        idempotencyKey: { type: "string", minLength: 1, maxLength: 160, description: "Stable unique key for this exact draft creation attempt." },
      },
      required: ["propertyId", "clientId", "checkIn", "checkOut", "amountMinor", "currency", "idempotencyKey"],
      additionalProperties: false,
    },
    annotations: { readOnlyHint: false },
    serverTool: "create_booking_draft",
  },
] as const;

/**
 * Registers the VOYA tools with a WebMCP model context.
 *
 * @param modelContext - The model context used to register the tools
 * @param invoke - Invoker for the corresponding VOYA server tools
 * @param signal - Signal that cancels registration
 */
export async function registerVoyaSiteTools(
  modelContext: WebMCPModelContext,
  invoke: VoyaWebMCPInvoker,
  signal: AbortSignal,
): Promise<void> {
  await Promise.all(
    siteToolDefinitions.map(({ serverTool, ...tool }) =>
      modelContext.registerTool(
        {
          ...tool,
          execute: (input, context) => invoke(serverTool, input, context?.signal),
        },
        { signal },
      ),
    ),
  );
}
