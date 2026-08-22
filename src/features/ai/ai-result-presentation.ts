export type AiResultPresentation = Readonly<{
  kind: "structured" | "text";
  partial: boolean;
  summary: string | null;
  suggestions: readonly string[];
  risks: readonly string[];
  raw: string;
}>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function textValue(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function textList(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.map(textValue).filter((value): value is string => Boolean(value));
}

function hasMalformedStructuredField(parsed: Record<string, unknown>): boolean {
  if (Object.hasOwn(parsed, "summary") && parsed.summary !== null && typeof parsed.summary !== "string") return true;
  for (const field of ["suggestions", "risks"] as const) {
    if (!Object.hasOwn(parsed, field)) continue;
    const value = parsed[field];
    if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) return true;
  }
  return false;
}

function decodeJsonString(value: string): string {
  try {
    return JSON.parse(`"${value}"`) as string;
  } catch {
    return value.replaceAll("\\n", "\n").replaceAll("\\\"", '"').trim();
  }
}

function extractPartialField(raw: string, field: string): string | null {
  const match = raw.match(new RegExp(`"${field}"\\s*:\\s*"((?:\\\\.|[^"\\\\])*)`, "u"));
  return match?.[1] ? decodeJsonString(match[1]) : null;
}

function partialArrayBody(raw: string, field: string): string | null {
  const fieldMatch = new RegExp(`"${field}"\\s*:\\s*\\[`, "u").exec(raw);
  if (!fieldMatch) return null;
  const start = fieldMatch.index + fieldMatch[0].length;
  let quoted = false;
  let escaped = false;
  for (let index = start; index < raw.length; index += 1) {
    const character = raw[index];
    if (quoted) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') quoted = false;
      continue;
    }
    if (character === '"') quoted = true;
    else if (character === "]") return raw.slice(start, index);
  }
  return raw.slice(start);
}

function extractPartialList(raw: string, field: string): string[] {
  const body = partialArrayBody(raw, field);
  if (!body) return [];
  return [...body.matchAll(/"((?:\\.|[^"\\])*)"/gu)]
    .map((entry) => decodeJsonString(entry[1] ?? ""))
    .filter(Boolean);
}

export function parseAiResult(output: string): AiResultPresentation {
  const raw = output.trim();
  try {
    const parsed: unknown = JSON.parse(raw);
    if (isRecord(parsed)) {
      const summary = textValue(parsed.summary);
      const suggestions = textList(parsed.suggestions);
      const risks = textList(parsed.risks);
      if (summary || suggestions.length > 0 || risks.length > 0) {
        return {
          kind: "structured",
          partial: hasMalformedStructuredField(parsed),
          summary,
          suggestions,
          risks,
          raw,
        };
      }
    }
  } catch {
    // Some provider responses are cut mid-JSON. Extract only complete strings
    // so the UI can still present useful content without pretending it is whole.
  }

  const summary = extractPartialField(raw, "summary");
  const suggestions = extractPartialList(raw, "suggestions");
  const risks = extractPartialList(raw, "risks");
  if (summary || suggestions.length > 0 || risks.length > 0) {
    return { kind: "structured", partial: true, summary, suggestions, risks, raw };
  }

  return { kind: "text", partial: true, summary: null, suggestions: [], risks: [], raw };
}
