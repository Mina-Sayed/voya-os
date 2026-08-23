export type GeminiEnvironment = "development" | "preview" | "production" | "test";

export type GeminiRuntimeConfig = Readonly<{
  environment: GeminiEnvironment;
  provider: "gemini";
  mainModel: string;
  extractionModel: string;
  enabled: boolean;
  syntheticOnly: boolean;
  outboundEnabled: boolean;
  autoRepliesEnabled: boolean;
  customerDataApproved: boolean;
  hasApiKey: boolean;
}>;

function enabledFlag(value: string | undefined): boolean {
  return value?.trim().toLowerCase() === "true";
}

function resolveEnvironment(environment: NodeJS.ProcessEnv): GeminiEnvironment {
  const value = environment.VERCEL_ENV ?? environment.NODE_ENV;
  if (value === "preview" || value === "production" || value === "test") return value;
  return "development";
}

export function readGeminiRuntimeConfig(environment: NodeJS.ProcessEnv = process.env): GeminiRuntimeConfig {
  const runtimeEnvironment = resolveEnvironment(environment);
  const syntheticOnly = runtimeEnvironment === "preview" || runtimeEnvironment === "test";
  const customerDataApproved = !syntheticOnly && enabledFlag(environment.GEMINI_CUSTOMER_DATA_APPROVED);
  return {
    environment: runtimeEnvironment,
    provider: "gemini",
    mainModel: environment.GEMINI_MAIN_MODEL?.trim() || "gemini-3.5-flash",
    extractionModel: environment.GEMINI_EXTRACTION_MODEL?.trim() || "gemini-3.5-flash-lite",
    enabled: enabledFlag(environment.GEMINI_ENABLED),
    syntheticOnly,
    outboundEnabled: enabledFlag(environment.WHATSAPP_OUTBOUND_ENABLED) && enabledFlag(environment.HUMAN_HANDOFF_APPROVED),
    autoRepliesEnabled: enabledFlag(environment.WHATSAPP_AI_AUTO_REPLIES) && enabledFlag(environment.HUMAN_HANDOFF_APPROVED),
    customerDataApproved,
    hasApiKey: Boolean(environment.GEMINI_API_KEY?.trim()),
  };
}

export type GeminiGenerationRequest = Readonly<{
  task: "main" | "extraction";
  systemInstruction: string;
  userPrompt: string;
  dataClass: "synthetic" | "customer_redacted";
}>;

export type GeminiGenerationResult = Readonly<{
  provider: "fake" | "gemini";
  model: string;
  text: string;
}>;

export class GeminiProviderError extends Error {
  readonly code: "disabled" | "customer_data_not_approved" | "missing_api_key" | "request_failed" | "invalid_response";

  constructor(code: GeminiProviderError["code"]) {
    super("Gemini provider is unavailable.");
    this.name = "GeminiProviderError";
    this.code = code;
  }
}

type GeminiProviderOptions = Readonly<{
  environment?: NodeJS.ProcessEnv;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}>;

type GeminiResponse = Readonly<{
  candidates?: readonly Readonly<{
    content?: Readonly<{ parts?: readonly Readonly<{ text?: string }>[] }>;
  }>[];
}>;

export function createGeminiProvider(options: GeminiProviderOptions = {}) {
  const environment = options.environment ?? process.env;
  const config = readGeminiRuntimeConfig(environment);
  const fetchImpl = options.fetchImpl ?? fetch;
  const timeoutMs = Math.min(Math.max(options.timeoutMs ?? 12_000, 1_000), 30_000);

  return {
    config,
    async generate(request: GeminiGenerationRequest): Promise<GeminiGenerationResult> {
      if (!config.enabled) throw new GeminiProviderError("disabled");
      if (request.dataClass === "customer_redacted" && !config.customerDataApproved) {
        throw new GeminiProviderError("customer_data_not_approved");
      }
      const model = request.task === "extraction" ? config.extractionModel : config.mainModel;
      if (config.syntheticOnly) {
        return {
          provider: "fake",
          model,
          text: JSON.stringify({ status: "preview_stub", task: request.task, message: "Synthetic preview response." }),
        };
      }
      const apiKey = environment.GEMINI_API_KEY?.trim() ?? "";
      if (!apiKey) throw new GeminiProviderError("missing_api_key");

      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const response = await fetchImpl(
          `https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`,
          {
            method: "POST",
            headers: { "content-type": "application/json", "x-goog-api-key": apiKey },
            body: JSON.stringify({
              systemInstruction: { parts: [{ text: request.systemInstruction }] },
              contents: [{ role: "user", parts: [{ text: request.userPrompt }] }],
              generationConfig: { responseMimeType: "application/json", temperature: 0, maxOutputTokens: 800 },
            }),
            signal: controller.signal,
          },
        );
        if (!response.ok) throw new GeminiProviderError("request_failed");
        const payload = await response.json() as GeminiResponse;
        const text = payload.candidates?.[0]?.content?.parts?.map((part) => part.text ?? "").join("").trim();
        if (!text) throw new GeminiProviderError("invalid_response");
        return { provider: "gemini", model, text };
      } catch (error) {
        if (error instanceof GeminiProviderError) throw error;
        throw new GeminiProviderError("request_failed");
      } finally {
        clearTimeout(timer);
      }
    },
  };
}
