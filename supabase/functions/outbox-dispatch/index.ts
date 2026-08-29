/* eslint-disable @typescript-eslint/no-explicit-any -- Supabase Edge RPC rows are runtime-validated at each trust boundary. */

import { createClient } from "npm:@supabase/supabase-js@2";
import { dispatchOutboxEvent, type OutboxEvent } from "../../../src/lib/outbox/dispatch-contract.ts";
import { createResendEmailAdapter } from "../../../src/lib/email/resend.ts";
import { createMetaWhatsAppOutboundAdapter } from "../../../src/lib/whatsapp/meta-outbound.ts";
import { createMetaWhatsAppMediaAdapter, MetaWhatsAppMediaError } from "../../../src/lib/whatsapp/meta-media.ts";
import { authorizeOutboxWorkerRequest, readOutboxWorkerConfig } from "../../../src/lib/outbox/worker-config.ts";
import { createGeminiProvider, GeminiProviderError } from "../../../src/lib/ai/gemini-runtime.ts";
import { buildAiGenerationRequest, buildDataEntryGenerationRequest, classifyGeminiFailure, normalizeAiResult } from "../../../src/lib/ai/execution-contract.ts";
import { parseDataEntryPayload } from "../../../src/lib/ai/data-entry-payload.ts";
import { bytesToBase64, validateDataEntryWorkerInputs } from "../../../src/lib/ai/data-entry-worker.ts";
import { buildWhatsappAiGenerationRequest, buildWhatsappMediaStoragePath, projectWhatsappAiResponse, readStoredWhatsappState, shouldMarkWhatsappMediaFailed, shouldSendWhatsappReply, summarizeWhatsappAiResult, toWhatsappHistory } from "../../../src/lib/whatsapp/whatsapp-ai-worker.ts";
import { parseWhatsappAiResponse } from "../../../src/domain/ai/whatsapp-agent-contract.ts";

const BATCH_SIZE = 20;
const LEASE_SECONDS = 300;
const MAX_ATTEMPTS = 6;

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "cache-control": "no-store", "content-type": "application/json; charset=utf-8" },
  });
}

function bytesFromEncoded(value: string): Uint8Array {
  if (/^[0-9a-f]{64}$/iu.test(value)) {
    const bytes = new Uint8Array(32);
    for (let index = 0; index < bytes.length; index += 1) bytes[index] = Number.parseInt(value.slice(index * 2, index * 2 + 2), 16);
    return bytes;
  }
  const binary = atob(value);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function bytesFromBase64Url(value: string): Uint8Array {
  const normalized = value.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return bytesFromEncoded(normalized);
}

function concatBytes(first: Uint8Array, second: Uint8Array): Uint8Array {
  const result = new Uint8Array(first.length + second.length);
  result.set(first, 0);
  result.set(second, first.length);
  return result;
}

function ownedArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return copy.buffer;
}

async function unsealToken(sealedValue: string, encryptionKey: string): Promise<string> {
  const [payloadVersion, encodedIv, encodedCiphertext, encodedAuthTag] = sealedValue.split(".");
  if (payloadVersion !== "v1" || !encodedIv || !encodedCiphertext || !encodedAuthTag) throw new Error("invalid sealed payload");
  const key = await crypto.subtle.importKey("raw", ownedArrayBuffer(bytesFromEncoded(encryptionKey)), { name: "AES-GCM" }, false, ["decrypt"]);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: ownedArrayBuffer(bytesFromBase64Url(encodedIv)), tagLength: 128 },
    key,
    ownedArrayBuffer(concatBytes(bytesFromBase64Url(encodedCiphertext), bytesFromBase64Url(encodedAuthTag))),
  );
  return new TextDecoder().decode(plaintext);
}

function safeProviderError(error: unknown, fallback: string): string {
  const candidate = typeof error === "object" && error !== null && "errorCode" in error ? error.errorCode : null;
  return typeof candidate === "string" && /^[a-z][a-z0-9_.-]{0,119}$/u.test(candidate) ? candidate : fallback;
}

async function markNeedsReview(client: any, eventId: string, workerId: string, errorCode: string): Promise<boolean> {
  const { data, error } = await client.rpc("mark_outbox_event_needs_review", { p_event_id: eventId, p_worker_id: workerId, p_error_code: errorCode });
  return !error && data === true;
}

async function finalizeDataEntryFailure(client: any, eventId: string, workerId: string, errorCode: string): Promise<boolean> {
  const { data, error } = await client.rpc("finalize_ai_data_entry_failure_v1", {
    p_event_id: eventId,
    p_worker_id: workerId,
    p_error_code: errorCode,
  });
  return !error && data === true;
}

async function renewAiEventLease(client: any, eventId: string, workerId: string): Promise<boolean> {
  const { data, error } = await client.rpc("renew_ai_event_lease_v1", {
    p_event_id: eventId,
    p_worker_id: workerId,
    p_lease_seconds: LEASE_SECONDS,
  });
  return !error && data === true;
}

async function renewOutboxDeliveryLease(client: any, eventId: string, workerId: string): Promise<boolean> {
  const { data, error } = await client.rpc("renew_outbox_delivery_lease_v1", {
    p_event_id: eventId,
    p_worker_id: workerId,
    p_lease_seconds: LEASE_SECONDS,
  });
  return !error && data === true;
}

async function completeLeasedEvent(client: any, eventId: string, workerId: string): Promise<boolean> {
  const { data, error } = await client.rpc("complete_outbox_event", { p_event_id: eventId, p_worker_id: workerId });
  return !error && data === true;
}

async function renewWhatsappAiEventLease(client: any, eventId: string, workerId: string): Promise<boolean> {
  const { data, error } = await client.rpc("renew_whatsapp_ai_event_lease_v1", {
    p_event_id: eventId,
    p_worker_id: workerId,
    p_lease_seconds: LEASE_SECONDS,
  });
  return !error && data === true;
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", ownedArrayBuffer(bytes));
  return bytesToHex(new Uint8Array(digest));
}

function safeText(value: unknown, maximum = 512): string | null {
  return typeof value === "string" && value.trim() ? value.trim().slice(0, maximum) : null;
}

function mediaErrorIsRetryable(error: unknown): boolean {
  return error instanceof MetaWhatsAppMediaError
    && (error.code === "meta_media_timeout" || error.code === "meta_media_provider_failure");
}

async function loadWhatsappImageParts(
  client: any,
  row: any,
  context: any,
  workerId: string,
  mediaAdapter: ReturnType<typeof createMetaWhatsAppMediaAdapter> | null,
) {
  const source = context.source_message ?? {};
  if (source.message_type !== "image") return { imageParts: [], sourceImageMessageId: null };
  const messageId = safeText(source.id, 120);
  if (!messageId) throw new GeminiProviderError("invalid_response");

  if (source.media_status === "stored") {
    const bucket = source.media_storage_bucket;
    const path = source.media_storage_path;
    const mimeType = source.media_mime_hint;
    const byteSize = source.media_byte_size;
    const checksum = source.media_checksum_sha256;
    if (bucket !== "ai-intake" || !safeText(path, 500) || (mimeType !== "image/jpeg" && mimeType !== "image/png" && mimeType !== "image/webp")
      || typeof byteSize !== "number" || !Number.isSafeInteger(byteSize) || byteSize < 1 || typeof checksum !== "string") {
      throw new GeminiProviderError("invalid_response");
    }
    const { data, error } = await client.storage.from(bucket).download(path);
    if (error || !data) throw new GeminiProviderError("request_failed");
    const bytes = new Uint8Array(await data.arrayBuffer());
    if (bytes.byteLength !== byteSize || await sha256Hex(bytes) !== checksum) throw new GeminiProviderError("invalid_response");
    return { imageParts: [{ mimeType, data: bytesToBase64(bytes) }], sourceImageMessageId: messageId };
  }

  if (source.media_status !== "pending" || !mediaAdapter) throw new MetaWhatsAppMediaError("meta_media_provider_failure");
  const providerMediaId = safeText(source.provider_media_id, 320);
  if (!providerMediaId) throw new MetaWhatsAppMediaError("meta_media_invalid_response");
  if (!(await renewWhatsappAiEventLease(client, row.id, workerId))) throw new MetaWhatsAppMediaError("meta_media_timeout");
  const media = await mediaAdapter.download({ providerMediaId, mimeTypeHint: source.media_mime_hint ?? null });
  const storagePath = buildWhatsappMediaStoragePath(context.organization_id, context.conversation_id, messageId, media.mimeType);
  if (!(await renewWhatsappAiEventLease(client, row.id, workerId))) throw new MetaWhatsAppMediaError("meta_media_timeout");
  const storage = client.storage.from("ai-intake");
  const upload = await storage.upload(storagePath, media.bytes, { contentType: media.mimeType, upsert: false });
  if (upload.error) {
    const existing = await storage.download(storagePath);
    if (existing.error || !existing.data) throw new GeminiProviderError("request_failed");
    const existingBytes = new Uint8Array(await existing.data.arrayBuffer());
    if (existingBytes.byteLength !== media.sizeBytes || await sha256Hex(existingBytes) !== await sha256Hex(media.bytes)) throw new GeminiProviderError("invalid_response");
  }
  const checksum = await sha256Hex(media.bytes);
  const { data: stored, error: storeError } = await client.rpc("store_whatsapp_media_v1", {
    p_event_id: row.id,
    p_worker_id: workerId,
    p_message_id: messageId,
    p_storage_path: storagePath,
    p_mime_type: media.mimeType,
    p_byte_size: media.sizeBytes,
    p_checksum_sha256: checksum,
  });
  if (storeError || stored !== true) throw new GeminiProviderError("request_failed");
  return { imageParts: [{ mimeType: media.mimeType, data: bytesToBase64(media.bytes) }], sourceImageMessageId: messageId };
}

async function failAiRunAndMarkNeedsReview(
  client: any,
  eventId: string,
  workerId: string,
  errorCode: string,
  isDataEntry = false,
): Promise<boolean> {
  if (isDataEntry) {
    const finalized = await finalizeDataEntryFailure(client, eventId, workerId, errorCode);
    await markNeedsReview(client, eventId, workerId, finalized ? errorCode : `${errorCode}_record_failed`);
    return finalized;
  }
  const { data, error } = await client.rpc("mark_ai_run_failed", {
    p_event_id: eventId,
    p_worker_id: workerId,
    p_error_code: errorCode,
  });
  const recorded = !error && data === true;
  await markNeedsReview(client, eventId, workerId, recorded ? errorCode : `${errorCode}_record_failed`);
  return recorded;
}

async function loadDataEntryImageParts(client: any, inputs: unknown) {
  const validation = validateDataEntryWorkerInputs(inputs);
  if (!validation.ok) throw new GeminiProviderError("invalid_response");
  const imageParts = [];
  for (const input of validation.value) {
    const { data, error } = await client.storage.from(input.storageBucket).download(input.storagePath);
    if (error || !data) throw new GeminiProviderError("request_failed");
    const bytes = new Uint8Array(await data.arrayBuffer());
    if (bytes.byteLength !== input.byteSize) throw new GeminiProviderError("invalid_response");
    imageParts.push({ mimeType: input.mimeType, data: bytesToBase64(bytes) });
  }
  return { imageParts, inputIds: validation.value.map((input) => input.id) };
}

async function cleanupDataEntryInputs(client: any, inputs: unknown): Promise<boolean> {
  const validation = validateDataEntryWorkerInputs(inputs);
  if (!validation.ok) return false;
  const pathsByBucket = new Map<string, string[]>();
  for (const input of validation.value) {
    const paths = pathsByBucket.get(input.storageBucket) ?? [];
    paths.push(input.storagePath);
    pathsByBucket.set(input.storageBucket, paths);
  }
  for (const [bucket, paths] of pathsByBucket) {
    if (paths.length === 0) continue;
    const { error } = await client.storage.from(bucket).remove(paths);
    if (error) return false;
  }
  return true;
}

async function finishWorkerRun(
  client: any,
  runId: string | null,
  workerId: string,
  status: "completed" | "failed",
  counts: Readonly<{ claimed: number; completed: number; retried: number; failed: number; needsReview: number }>,
  errorCode: string | null,
) {
  if (!runId) return;
  try {
    await client.rpc("finish_outbox_worker_run", {
      p_run_id: runId,
      p_worker_id: workerId,
      p_status: status,
      p_claimed_count: counts.claimed,
      p_completed_count: counts.completed,
      p_retried_count: counts.retried,
      p_failed_count: counts.failed,
      p_needs_review_count: counts.needsReview,
      p_error_code: errorCode,
    });
  } catch {
    // A heartbeat write must not replace the worker's delivery response.
  }
}

async function prepareEvent(client: any, row: any, workerId: string, encryptionKey: string): Promise<OutboxEvent | { errorCode: string }> {
  const payload = { ...(row.payload ?? {}) };
  if (row.event_type === "organization.invitation.send_requested" || row.event_type === "member.invitation.resent") {
    if (Object.prototype.hasOwnProperty.call(payload, "token")) return { errorCode: "unsafe_raw_token_payload" };
    if (typeof payload.sealed_token !== "string") return { errorCode: "invitation_payload_incomplete" };
    try {
      payload.token = await unsealToken(payload.sealed_token, encryptionKey);
    } catch {
      return { errorCode: "invitation_payload_unseal_failed" };
    }
  }
  if (row.event_type === "whatsapp.message.send_requested") {
    const { data, error } = await client.rpc("resolve_whatsapp_outbox_delivery", { p_event_id: row.id, p_worker_id: workerId });
    const context = data?.[0];
    if (error || !context) return { errorCode: "whatsapp_delivery_context_missing" };
    payload.phoneNumberId = context.phone_number_id;
    payload.to = context.recipient_phone;
    payload.body = context.body_text;
  }
  return {
    id: row.id,
    event_type: row.event_type,
    schema_version: row.schema_version,
    attempts: row.attempts,
    payload,
  };
}

async function executeAiEvent(client: any, row: any, workerId: string): Promise<"completed" | "retry" | "failed" | "needs_review"> {
  const isCopilot = row.payload?.agent_kind === "copilot";
  const isDataEntry = row.payload?.agent_kind === "data_entry";
  const { data: contextRows, error: contextError } = await client.rpc(
    isCopilot ? "resolve_ai_copilot_execution" : isDataEntry ? "resolve_ai_data_entry_execution_v1" : "resolve_ai_run_execution",
    { p_event_id: row.id, p_worker_id: workerId },
  );
  const context = contextRows?.[0];
  if (contextError || !context) {
    await failAiRunAndMarkNeedsReview(client, row.id, workerId, "ai_execution_context_missing", isDataEntry);
    return "needs_review";
  }

  const provider = createGeminiProvider({ environment: Deno.env.toObject() });
  const promptVersion = isDataEntry ? "data-entry-v1" : "proposal-v1";
  const modelName = isDataEntry ? provider.config.extractionModel : provider.config.mainModel;
  const { data: startedRun, error: startError } = await client.rpc("mark_ai_run_started", {
    p_event_id: row.id,
    p_worker_id: workerId,
    p_model_name: modelName,
    p_prompt_version: promptVersion,
  });
  if (startError || !startedRun) {
    await markNeedsReview(client, row.id, workerId, "ai_run_start_failed");
    return "needs_review";
  }
  if (isDataEntry) {
    const { data: extracting, error: extractingError } = await client.rpc("mark_ai_data_entry_extracting_v1", { p_event_id: row.id, p_worker_id: workerId });
    if (extractingError || extracting !== true) {
      const terminalized = await failAiRunAndMarkNeedsReview(
        client,
        row.id,
        workerId,
        "ai_data_entry_extracting_failed",
        true,
      );
      if (terminalized && !extractingError && !(await cleanupDataEntryInputs(client, context.inputs))) {
        await markNeedsReview(client, row.id, workerId, "ai_data_entry_input_cleanup_failed");
      }
      return "needs_review";
    }
  }

  try {
    if (isCopilot) {
      const contextFields = ["properties", "leads", "bookings"];
      if (context.context?.tasks) contextFields.push("tasks");
      const { data: recorded, error: toolError } = await client.rpc("record_ai_copilot_context_read", {
        p_event_id: row.id,
        p_worker_id: workerId,
        p_context_summary: { scope: "organization", fields: contextFields },
      });
      if (toolError || recorded === false) {
        await failAiRunAndMarkNeedsReview(client, row.id, workerId, "ai_copilot_context_audit_failed", false);
        return "needs_review";
      }
    }

    let dataEntryPayload = null;
    let generated;
    if (isDataEntry) {
      const { imageParts, inputIds } = await loadDataEntryImageParts(client, context.inputs);
      const request = buildDataEntryGenerationRequest({
        sourceText: context.source_text ?? "",
        imageInputIds: inputIds,
        dataClass: provider.config.syntheticOnly ? "synthetic" : "customer_redacted",
      });
      if (!(await renewAiEventLease(client, row.id, workerId))) return "retry";
      generated = await provider.generate({ ...request, imageParts });
      const parsed = parseDataEntryPayload(generated.text, inputIds);
      if (!parsed.ok) throw new GeminiProviderError("invalid_response");
      dataEntryPayload = parsed.value;
    } else {
      const request = buildAiGenerationRequest({
        agentKind: context.agent_kind,
        purpose: context.purpose,
        dataClass: provider.config.syntheticOnly ? "synthetic" : "customer_redacted",
        ...(isCopilot ? { context: context.context } : {}),
      });
      if (!(await renewAiEventLease(client, row.id, workerId))) return "retry";
      generated = await provider.generate(request);
    }

    const result = normalizeAiResult(generated);
    if (isDataEntry) {
      const { data: finalized, error: finalizeError } = await client.rpc("finalize_ai_data_entry_extraction_v1", {
        p_event_id: row.id,
        p_worker_id: workerId,
        p_extraction_payload: dataEntryPayload,
        p_result_summary: result,
      });
      if (finalizeError || finalized !== true) {
        await markNeedsReview(client, row.id, workerId, "ai_data_entry_result_record_failed");
        return "needs_review";
      }
    } else {
      const { data: succeededRun, error: successError } = await client.rpc("mark_ai_run_succeeded", {
        p_event_id: row.id,
        p_worker_id: workerId,
        p_result_summary: result,
      });
      if (successError || succeededRun !== true) {
        await markNeedsReview(client, row.id, workerId, "ai_result_record_failed");
        return "needs_review";
      }
    }

    if (!await completeLeasedEvent(client, row.id, workerId)) {
      await markNeedsReview(client, row.id, workerId, "ai_outbox_completion_failed");
      return "needs_review";
    }
    return "completed";
  } catch (error) {
    const disposition = classifyGeminiFailure(error);
    if (disposition.kind === "permanent") {
      if (isDataEntry) {
        const finalized = await finalizeDataEntryFailure(client, row.id, workerId, disposition.errorCode);
        if (!finalized) {
          await markNeedsReview(client, row.id, workerId, "ai_data_entry_failure_record_failed");
          return "needs_review";
        }
        const cleaned = await cleanupDataEntryInputs(client, context.inputs);
        if (!cleaned) {
          await markNeedsReview(client, row.id, workerId, "ai_data_entry_input_cleanup_failed");
          return "needs_review";
        }
      } else {
        const { data: failedRun, error: failedError } = await client.rpc("mark_ai_run_failed", {
          p_event_id: row.id,
          p_worker_id: workerId,
          p_error_code: disposition.errorCode,
        });
        if (failedError || failedRun !== true) {
          await markNeedsReview(client, row.id, workerId, "ai_failure_record_failed");
          return "needs_review";
        }
      }
      if (!await completeLeasedEvent(client, row.id, workerId)) {
        await markNeedsReview(client, row.id, workerId, "ai_failed_outbox_completion_failed");
        return "needs_review";
      }
      return "failed";
    }

    const willDeadLetter = row.attempts >= MAX_ATTEMPTS;
    if (willDeadLetter && isDataEntry) {
      const finalized = await finalizeDataEntryFailure(client, row.id, workerId, "ai_retry_exhausted");
      if (!finalized) {
        await markNeedsReview(client, row.id, workerId, "ai_dead_letter_record_failed");
        return "needs_review";
      }
      const cleaned = await cleanupDataEntryInputs(client, context.inputs);
      if (!cleaned) {
        await markNeedsReview(client, row.id, workerId, "ai_data_entry_input_cleanup_failed");
        return "needs_review";
      }
      const { data: retryState, error: retryError } = await client.rpc("fail_outbox_event", {
        p_event_id: row.id,
        p_worker_id: workerId,
        p_error_code: "ai_retry_exhausted",
        p_retry_after_seconds: getAiRetryDelay(row.attempts),
        p_max_attempts: MAX_ATTEMPTS,
      });
      if (retryError || retryState !== "dead_letter") {
        await markNeedsReview(client, row.id, workerId, "ai_dead_letter_transition_failed");
        return "needs_review";
      }
      return "failed";
    }

    if (willDeadLetter) {
      const { data: failedRun, error: failedError } = await client.rpc("mark_ai_run_failed", {
        p_event_id: row.id,
        p_worker_id: workerId,
        p_error_code: "ai_retry_exhausted",
      });
      if (failedError || failedRun !== true) {
        await markNeedsReview(client, row.id, workerId, "ai_dead_letter_record_failed");
        return "needs_review";
      }
    }

    const { data: retryState, error: retryError } = await client.rpc("fail_outbox_event", {
      p_event_id: row.id,
      p_worker_id: workerId,
      p_error_code: disposition.errorCode,
      p_retry_after_seconds: getAiRetryDelay(row.attempts),
      p_max_attempts: MAX_ATTEMPTS,
    });
    if (retryError || (retryState !== "retry_wait" && retryState !== "dead_letter")) {
      await markNeedsReview(client, row.id, workerId, "ai_retry_record_failed");
      return "needs_review";
    }
    if (retryState === "dead_letter") return "failed";
    return "retry";
  }
}

async function markWhatsappMediaFailed(client: any, row: any, workerId: string, messageId: string, errorCode: string): Promise<void> {
  await client.rpc("fail_whatsapp_media_v1", {
    p_event_id: row.id,
    p_worker_id: workerId,
    p_message_id: messageId,
    p_error_code: errorCode,
  });
}

function whatsappErrorCode(error: unknown): string {
  if (error instanceof MetaWhatsAppMediaError) {
    if (error.code === "meta_media_timeout") return "whatsapp_media_timeout";
    if (error.code === "meta_media_provider_failure") return "whatsapp_media_provider_failure";
    if (error.code === "meta_media_too_large") return "whatsapp_media_too_large";
    if (error.code === "meta_media_unsupported_type") return "whatsapp_media_unsupported_type";
    if (error.code === "meta_media_mime_mismatch") return "whatsapp_media_mime_mismatch";
    if (error.code === "meta_media_signature_mismatch") return "whatsapp_media_signature_mismatch";
    return "whatsapp_media_invalid_response";
  }
  if (error instanceof Error && /^[a-z][a-z0-9_.-]{0,119}$/u.test(error.message)) return error.message;
  const disposition = classifyGeminiFailure(error);
  return disposition.errorCode;
}

function whatsappErrorIsRetryable(error: unknown): boolean {
  if (mediaErrorIsRetryable(error)) return true;
  return classifyGeminiFailure(error).kind === "retryable";
}

async function retryWhatsappAiEvent(client: any, row: any, workerId: string, errorCode: string): Promise<"retry" | "failed" | "needs_review"> {
  const maxAttempts = MAX_ATTEMPTS;
  const { data, error } = await client.rpc("fail_outbox_event", {
    p_event_id: row.id,
    p_worker_id: workerId,
    p_error_code: errorCode,
    p_retry_after_seconds: getAiRetryDelay(row.attempts),
    p_max_attempts: maxAttempts,
  });
  if (error || (data !== "retry_wait" && data !== "dead_letter")) {
    await markNeedsReview(client, row.id, workerId, "whatsapp_ai_retry_record_failed");
    return "needs_review";
  }
  if (data === "dead_letter") {
    await client.rpc("fail_whatsapp_ai_run_v1", { p_event_id: row.id, p_worker_id: workerId, p_error_code: "whatsapp_ai_retry_exhausted" });
    return "failed";
  }
  return "retry";
}

async function executeWhatsappAiEvent(client: any, row: any, workerId: string, config: ReturnType<typeof readOutboxWorkerConfig>): Promise<"completed" | "retry" | "failed" | "needs_review"> {
  const { data: contextRows, error: contextError } = await client.rpc("resolve_whatsapp_ai_execution_v1", {
    p_event_id: row.id,
    p_worker_id: workerId,
  });
  const context = contextRows?.[0];
  if (contextError || !context) {
    await client.rpc("fail_whatsapp_ai_run_v1", { p_event_id: row.id, p_worker_id: workerId, p_error_code: "whatsapp_ai_context_missing" });
    await markNeedsReview(client, row.id, workerId, "whatsapp_ai_context_missing");
    return "needs_review";
  }

  if (!context.should_process) {
    if (context.skip_reason === "media_unavailable") {
      await client.rpc("fail_whatsapp_ai_run_v1", { p_event_id: row.id, p_worker_id: workerId, p_error_code: "whatsapp_media_unavailable" });
      await markNeedsReview(client, row.id, workerId, "whatsapp_media_unavailable");
      return "needs_review";
    }
    if (context.skip_reason === "media_not_ready") {
      if (row.attempts >= MAX_ATTEMPTS && typeof context.message_id === "string") {
        await markWhatsappMediaFailed(client, row, workerId, context.message_id, "whatsapp_media_not_ready");
      }
      return retryWhatsappAiEvent(client, row, workerId, "whatsapp_media_not_ready");
    }
    const skipped = await client.rpc("succeed_whatsapp_ai_run_v1", {
      p_event_id: row.id,
      p_worker_id: workerId,
      p_result_summary: { status: "skipped", reason: context.skip_reason ?? "not_actionable" },
    });
    if (skipped.error || skipped.data !== true || !(await completeLeasedEvent(client, row.id, workerId))) {
      await markNeedsReview(client, row.id, workerId, "whatsapp_ai_skip_record_failed");
      return "needs_review";
    }
    return "completed";
  }

  const provider = createGeminiProvider({ environment: Deno.env.toObject() });
  const started = await client.rpc("start_whatsapp_ai_run_v1", {
    p_event_id: row.id,
    p_worker_id: workerId,
    p_model_name: provider.config.mainModel,
    p_prompt_version: "whatsapp-agent-v1",
  });
  if (started.error || started.data !== true) {
    await markNeedsReview(client, row.id, workerId, "whatsapp_ai_run_start_failed");
    return "needs_review";
  }

  const source = context.source_message ?? {};
  const sourceText = typeof source.body_text === "string" ? source.body_text : "";
  const state = readStoredWhatsappState(context.structured_state, sourceText);
  const messageId: string | null = typeof context.message_id === "string" ? context.message_id : null;
  try {
    const mediaAdapter = config.metaWhatsAppAccessToken
      ? createMetaWhatsAppMediaAdapter({ accessToken: config.metaWhatsAppAccessToken, graphApiVersion: config.metaGraphApiVersion })
      : null;
    const { imageParts, sourceImageMessageId } = await loadWhatsappImageParts(client, row, context, workerId, mediaAdapter);
    const request = buildWhatsappAiGenerationRequest({
      conversationType: context.conversation_type,
      state,
      history: toWhatsappHistory(context.recent_messages),
      mediaMessageIds: sourceImageMessageId ? [sourceImageMessageId] : [],
      dataClass: provider.config.syntheticOnly ? "synthetic" : "customer_redacted",
      imageParts,
    });
    if (!(await renewWhatsappAiEventLease(client, row.id, workerId))) return retryWhatsappAiEvent(client, row, workerId, "whatsapp_ai_lease_lost");
    const generated = await provider.generate(request);
    const parsed = parseWhatsappAiResponse(generated.text);
    if (!parsed.ok) throw new GeminiProviderError("invalid_response");
    const projected = projectWhatsappAiResponse(state, parsed.value, sourceImageMessageId ?? undefined);
    const sendReply = shouldSendWhatsappReply(parsed.value, {
      outboundEnabled: config.whatsappEnabled && provider.config.outboundEnabled,
      autoRepliesEnabled: provider.config.autoRepliesEnabled,
    });
    if (!(await renewWhatsappAiEventLease(client, row.id, workerId))) return retryWhatsappAiEvent(client, row, workerId, "whatsapp_ai_lease_lost");
    const applied = await client.rpc("apply_whatsapp_ai_result_v1", {
      p_event_id: row.id,
      p_worker_id: workerId,
      p_conversation_type: parsed.value.conversationType,
      p_structured_state: projected.state,
      p_reply: parsed.value.reply,
      p_recommended_action: projected.recommendedAction,
      p_confidence: parsed.value.confidence,
      p_send_reply: sendReply,
    });
    const appliedRow = applied.data?.[0];
    if (applied.error || !appliedRow) throw new Error("whatsapp_ai_result_record_failed");
    const succeeded = await client.rpc("succeed_whatsapp_ai_run_v1", {
      p_event_id: row.id,
      p_worker_id: workerId,
      p_result_summary: summarizeWhatsappAiResult(generated, parsed.value),
    });
    if (succeeded.error || succeeded.data !== true) throw new Error("whatsapp_ai_run_finish_failed");
    if (!await completeLeasedEvent(client, row.id, workerId)) {
      await markNeedsReview(client, row.id, workerId, "whatsapp_ai_outbox_completion_failed");
      return "needs_review";
    }
    return "completed";
  } catch (error) {
    const errorCode = whatsappErrorCode(error);
    const retryable = whatsappErrorIsRetryable(error);
    // Keep a provider timeout/storage outage retryable. Marking pending media
    // failed before the outbox retry would make the next attempt skip it as
    // permanently unavailable. At the final attempt, quarantine the media so
    // the inbox exposes a durable review state.
    if (source.message_type === "image" && source.media_status === "pending" && messageId && shouldMarkWhatsappMediaFailed(retryable, row.attempts, MAX_ATTEMPTS)) {
      await markWhatsappMediaFailed(client, row, workerId, messageId, errorCode);
    }
    if (retryable) return retryWhatsappAiEvent(client, row, workerId, errorCode);
    const failedRun = await client.rpc("fail_whatsapp_ai_run_v1", {
      p_event_id: row.id,
      p_worker_id: workerId,
      p_error_code: errorCode,
    });
    if (failedRun.error || failedRun.data !== true) {
      await markNeedsReview(client, row.id, workerId, "whatsapp_ai_failure_record_failed");
      return "needs_review";
    }
    await markNeedsReview(client, row.id, workerId, errorCode);
    return "needs_review";
  }
}

function getAiRetryDelay(attempts: number): number {
  if (attempts <= 1) return 60;
  if (attempts === 2) return 300;
  if (attempts === 3) return 900;
  if (attempts === 4) return 3600;
  return 21600;
}

Deno.serve(async (request) => {
  let config;
  try {
    config = readOutboxWorkerConfig(Deno.env.toObject());
  } catch {
    return json({ error: "not_configured" }, 503);
  }
  if (!authorizeOutboxWorkerRequest(request.headers.get("authorization"), config.workerSecret)) return json({ error: "forbidden" }, 403);
  if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const client = createClient(config.supabaseUrl, config.supabaseServiceRoleKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const workerId = `edge:${crypto.randomUUID()}`;
  let workerRunId: string | null = null;
  const workerRun = await client.rpc("start_outbox_worker_run", { p_worker_id: workerId });
  if (workerRun.error || typeof workerRun.data !== "string") return json({ error: "worker_run_start_failed" }, 503);
  workerRunId = workerRun.data;

  let completed = 0;
  let retried = 0;
  let failed = 0;
  let aiFailed = 0;
  let needsReview = 0;
  let overdue = 0;
  let claimedCount = 0;
  let runStatus: "completed" | "failed" = "completed";
  let runErrorCode: string | null = null;

  try {
    const overdueResult = await client.rpc("emit_overdue_task_notifications", {
      p_worker_id: workerId,
      p_limit: 100,
    });
    if (overdueResult.error) {
      runStatus = "failed";
      runErrorCode = "overdue_notification_failed";
      return json({ error: "overdue_notification_failed" }, 503);
    }
    overdue = typeof overdueResult.data === "number" ? overdueResult.data : 0;

    const { data: claimed, error: claimError } = await client.rpc("claim_outbox_delivery_events", {
      p_worker_id: workerId,
      p_limit: BATCH_SIZE,
      p_lease_seconds: LEASE_SECONDS,
    });
    if (claimError) {
      runStatus = "failed";
      runErrorCode = "claim_failed";
      return json({ error: "claim_failed" }, 503);
    }
    claimedCount = claimed?.length ?? 0;

    const resend = config.emailEnabled && config.resendApiKey && config.resendFrom
      ? createResendEmailAdapter({ apiKey: config.resendApiKey, from: config.resendFrom })
      : null;
    const meta = config.whatsappEnabled && config.metaWhatsAppAccessToken
      ? createMetaWhatsAppOutboundAdapter({ accessToken: config.metaWhatsAppAccessToken, graphApiVersion: config.metaGraphApiVersion })
      : null;

    for (const row of claimed ?? []) {
      if (row.event_type === "whatsapp.ai.respond_requested") {
        const whatsappOutcome = await executeWhatsappAiEvent(client, row, workerId, config);
        if (whatsappOutcome === "completed") completed += 1;
        else if (whatsappOutcome === "retry") retried += 1;
        else if (whatsappOutcome === "failed") {
          failed += 1;
          aiFailed += 1;
        } else needsReview += 1;
        continue;
      }
      if (row.event_type === "ai.run.requested" || row.event_type === "ai.data_entry.requested") {
        const aiOutcome = await executeAiEvent(client, row, workerId);
        if (aiOutcome === "completed") completed += 1;
        else if (aiOutcome === "retry") retried += 1;
        else if (aiOutcome === "failed") {
          failed += 1;
          aiFailed += 1;
        }
        else needsReview += 1;
        continue;
      }
      const prepared = await prepareEvent(client, row, workerId, config.encryptionKey);
      if ("errorCode" in prepared) {
        await markNeedsReview(client, row.id, workerId, prepared.errorCode);
        needsReview += 1;
        continue;
      }
      const result = await dispatchOutboxEvent(prepared, {
        emailEnabled: config.emailEnabled,
        whatsappEnabled: config.whatsappEnabled,
        applicationUrl: config.applicationUrl,
        sendEmail: async (request) => {
          if (!(await renewOutboxDeliveryLease(client, row.id, workerId))) return { kind: "ambiguous", errorCode: "outbox_lease_lost" };
          return resend
            ? resend.send(request)
            : Promise.resolve({ kind: "ambiguous" as const, errorCode: "email_adapter_unavailable" });
        },
        sendWhatsApp: async (request) => {
          if (!(await renewOutboxDeliveryLease(client, row.id, workerId))) return { kind: "ambiguous", errorCode: "outbox_lease_lost" };
          return meta
            ? meta.send(request)
            : Promise.resolve({ kind: "ambiguous" as const, errorCode: "whatsapp_adapter_unavailable" });
        },
      });
      if (result.outcome === "needs_review") {
        await markNeedsReview(client, row.id, workerId, result.errorCode ?? "delivery_needs_review");
        needsReview += 1;
        continue;
      }
      if (result.outcome === "completed") {
        if (row.event_type === "whatsapp.message.send_requested") {
          if (!result.providerMessageId) {
            await markNeedsReview(client, row.id, workerId, "whatsapp_provider_id_missing");
            needsReview += 1;
            continue;
          }
          const { data: markedSent, error } = await client.rpc("mark_whatsapp_message_sent", { p_event_id: row.id, p_worker_id: workerId, p_provider_message_id: result.providerMessageId });
          if (error || markedSent !== true) {
            await markNeedsReview(client, row.id, workerId, "whatsapp_delivery_record_failed");
            needsReview += 1;
            continue;
          }
        } else {
          const { data: markedSent, error } = await client.rpc("mark_invitation_delivery_sent", { p_event_id: row.id, p_worker_id: workerId });
          if (error || markedSent !== true) {
            await markNeedsReview(client, row.id, workerId, "invitation_delivery_record_failed");
            needsReview += 1;
            continue;
          }
        }
        if (await completeLeasedEvent(client, row.id, workerId)) completed += 1;
        else {
          await markNeedsReview(client, row.id, workerId, "outbox_completion_failed");
          needsReview += 1;
        }
        continue;
      }

      const errorCode = safeProviderError(result, "provider_failure");
      if (result.outcome === "dead_letter") {
        if (row.event_type === "whatsapp.message.send_requested") await client.rpc("mark_whatsapp_message_failed", { p_event_id: row.id, p_worker_id: workerId, p_error_code: errorCode });
        else await client.rpc("mark_invitation_delivery_failed", { p_event_id: row.id, p_worker_id: workerId });
      }
      const { data: failureState, error } = await client.rpc("fail_outbox_event", {
        p_event_id: row.id,
        p_worker_id: workerId,
        p_error_code: errorCode,
        p_retry_after_seconds: result.retryAfterSeconds ?? 1,
        p_max_attempts: result.outcome === "dead_letter" ? Math.max(1, row.attempts) : MAX_ATTEMPTS,
      });
      if (error || (failureState !== "retry_wait" && failureState !== "dead_letter")) {
        await markNeedsReview(client, row.id, workerId, "outbox_failure_record_failed");
        needsReview += 1;
        continue;
      }
      if (failureState === "retry_wait") retried += 1;
      else failed += 1;
    }

    return json({ ok: true, worker_id: workerId, claimed: claimed?.length ?? 0, completed, retried, ai_failed: aiFailed, needs_review: needsReview, overdue });
  } catch {
    runStatus = "failed";
    runErrorCode = "worker_execution_failed";
    return json({ error: "worker_execution_failed" }, 503);
  } finally {
    await finishWorkerRun(client, workerRunId, workerId, runStatus, {
      claimed: claimedCount,
      completed,
      retried,
      failed,
      needsReview,
    }, runErrorCode);
  }
});
