/* eslint-disable @typescript-eslint/no-explicit-any -- Supabase Edge RPC rows are runtime-validated at each trust boundary. */

import { createClient } from "npm:@supabase/supabase-js@2";
import { dispatchOutboxEvent, type OutboxEvent } from "../../../src/lib/outbox/dispatch-contract.ts";
import { createResendEmailAdapter } from "../../../src/lib/email/resend.ts";
import { createMetaWhatsAppOutboundAdapter } from "../../../src/lib/whatsapp/meta-outbound.ts";
import { authorizeOutboxWorkerRequest, readOutboxWorkerConfig } from "../../../src/lib/outbox/worker-config.ts";
import { createGeminiProvider } from "../../../src/lib/ai/gemini-runtime.ts";
import { buildAiGenerationRequest, classifyGeminiFailure, normalizeAiResult } from "../../../src/lib/ai/execution-contract.ts";

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

async function unsealToken(sealedValue: string, encryptionKey: string): Promise<string> {
  const [payloadVersion, encodedIv, encodedCiphertext, encodedAuthTag] = sealedValue.split(".");
  if (payloadVersion !== "v1" || !encodedIv || !encodedCiphertext || !encodedAuthTag) throw new Error("invalid sealed payload");
  const key = await crypto.subtle.importKey("raw", bytesFromEncoded(encryptionKey), { name: "AES-GCM" }, false, ["decrypt"]);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: bytesFromBase64Url(encodedIv), tagLength: 128 },
    key,
    concatBytes(bytesFromBase64Url(encodedCiphertext), bytesFromBase64Url(encodedAuthTag)),
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

async function failAiRunAndMarkNeedsReview(client: any, eventId: string, workerId: string, errorCode: string) {
  const { data, error } = await client.rpc("mark_ai_run_failed", {
    p_event_id: eventId,
    p_worker_id: workerId,
    p_error_code: errorCode,
  });
  await markNeedsReview(client, eventId, workerId, error || data !== true ? `${errorCode}_record_failed` : errorCode);
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
    // A worker-run heartbeat failure must not replace the delivery response.
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

async function completeLeasedEvent(client: any, eventId: string, workerId: string): Promise<boolean> {
  const { data, error } = await client.rpc("complete_outbox_event", { p_event_id: eventId, p_worker_id: workerId });
  return !error && data === true;
}

async function executeAiEvent(client: any, row: any, workerId: string): Promise<"completed" | "retry" | "failed" | "needs_review"> {
  const isCopilot = row.payload?.agent_kind === "copilot";
  const { data: contextRows, error: contextError } = await client.rpc(
    isCopilot ? "resolve_ai_copilot_execution" : "resolve_ai_run_execution",
    { p_event_id: row.id, p_worker_id: workerId },
  );
  const context = contextRows?.[0];
  if (contextError || !context) {
    await failAiRunAndMarkNeedsReview(client, row.id, workerId, "ai_execution_context_missing");
    return "needs_review";
  }

  const provider = createGeminiProvider({ environment: Deno.env.toObject() });
  const promptVersion = "proposal-v1";
  const modelName = provider.config.mainModel;
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
        await failAiRunAndMarkNeedsReview(client, row.id, workerId, "ai_copilot_context_audit_failed");
        return "needs_review";
      }
    }
    const generated = await provider.generate(buildAiGenerationRequest({
      agentKind: context.agent_kind,
      purpose: context.purpose,
      dataClass: provider.config.syntheticOnly ? "synthetic" : "customer_redacted",
      ...(isCopilot ? { context: context.context } : {}),
    }));
    const result = normalizeAiResult(generated);
    const { data: succeededRun, error: successError } = await client.rpc("mark_ai_run_succeeded", {
      p_event_id: row.id,
      p_worker_id: workerId,
      p_result_summary: result,
    });
    if (successError || succeededRun !== true) {
      await markNeedsReview(client, row.id, workerId, "ai_result_record_failed");
      return "needs_review";
    }
    if (!await completeLeasedEvent(client, row.id, workerId)) {
      await markNeedsReview(client, row.id, workerId, "ai_outbox_completion_failed");
      return "needs_review";
    }
    return "completed";
  } catch (error) {
    const disposition = classifyGeminiFailure(error);
    if (disposition.kind === "permanent") {
      const { data: failedRun, error: failedError } = await client.rpc("mark_ai_run_failed", {
        p_event_id: row.id,
        p_worker_id: workerId,
        p_error_code: disposition.errorCode,
      });
      if (failedError || failedRun !== true) {
        await markNeedsReview(client, row.id, workerId, "ai_failure_record_failed");
        return "needs_review";
      }
      if (!await completeLeasedEvent(client, row.id, workerId)) {
        await markNeedsReview(client, row.id, workerId, "ai_failed_outbox_completion_failed");
        return "needs_review";
      }
      return "failed";
    }

    const willDeadLetter = row.attempts >= MAX_ATTEMPTS;
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

    const resend = config.emailEnabled ? createResendEmailAdapter({ apiKey: config.resendApiKey, from: config.resendFrom }) : null;
    const meta = config.whatsappEnabled ? createMetaWhatsAppOutboundAdapter({ accessToken: config.metaWhatsAppAccessToken, graphApiVersion: config.metaGraphApiVersion }) : null;

    for (const row of claimed ?? []) {
      if (row.event_type === "ai.run.requested") {
        const aiOutcome = await executeAiEvent(client, row, workerId);
        if (aiOutcome === "completed") completed += 1;
        else if (aiOutcome === "retry") retried += 1;
        else if (aiOutcome === "failed") aiFailed += 1;
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
        sendEmail: (deliveryRequest) => resend.send(deliveryRequest),
        sendWhatsApp: (deliveryRequest) => meta.send(deliveryRequest),
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
      else aiFailed += row.event_type === "ai.run.requested" ? 1 : 0;
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
      failed: aiFailed,
      needsReview,
    }, runErrorCode);
  }
});
