import { createHmac } from "node:crypto";
import { expect } from "@playwright/test";
import { test } from "./fixtures/local-auth";

const OPENWA_WEBHOOK_PATH = "/api/webhooks/whatsapp/openwa";
const OPENWA_TEST_SECRET = process.env.VOYA_AUTH_E2E_OPENWA_WEBHOOK_SECRET ?? "missing-openwa-test-secret";

type EnvelopeOptions = Readonly<{
  sessionId: string;
  senderPhone: string;
  id: string;
  idempotencyKey: string;
  event?: string;
  bodyText: string;
  dataOverrides?: Record<string, unknown>;
}>;

function openWaEnvelope(options: EnvelopeOptions): string {
  const chatId = `${options.senderPhone.replace(/^\+/u, "")}@c.us`;
  return JSON.stringify({
    event: options.event ?? "message.received",
    timestamp: new Date().toISOString(),
    sessionId: options.sessionId,
    idempotencyKey: options.idempotencyKey,
    deliveryId: `delivery-${options.id}`,
    data: {
      id: options.id,
      from: options.event === "message.sent" ? "201599999999@c.us" : chatId,
      to: options.event === "message.sent" ? chatId : "201599999999@c.us",
      chatId,
      body: options.bodyText,
      type: "text",
      timestamp: Math.floor(Date.now() / 1000),
      fromMe: options.event === "message.sent",
      isGroup: false,
      isStatusBroadcast: false,
      kind: "individual",
      contact: { pushName: `OpenWA E2E ${options.senderPhone.slice(-6)}` },
      ...options.dataOverrides,
    },
  });
}

async function signedWebhook(page: import("@playwright/test").Page, rawBody: string, tamper = false) {
  const envelope = JSON.parse(rawBody) as { idempotencyKey: string };
  const signature = createHmac("sha256", OPENWA_TEST_SECRET).update(rawBody, "utf8").digest("hex");
  return page.request.post(OPENWA_WEBHOOK_PATH, {
    data: tamper ? `${rawBody} ` : rawBody,
    headers: {
      "content-type": "application/json",
      "x-openwa-signature": `sha256=${signature}`,
      "x-openwa-idempotency-key": envelope.idempotencyKey,
    },
  });
}

async function registerOpenWaChannel(page: import("@playwright/test").Page, suffix: string) {
  await page.goto("/workspace/whatsapp");
  await page.locator('input[name="provider"]').fill("openwa");
  await page.locator('input[name="external_channel_id"]').fill(`openwa-e2e-${suffix}`);
  await page.locator('input[name="display_name"]').fill(`قناة OpenWA E2E ${suffix}`);
  await page.getByRole("button", { name: "حفظ تعريف القناة" }).click();
  await expect(page.getByText(/تم حفظ تعريف القناة/u)).toBeVisible();
  return `openwa-e2e-${suffix}`;
}

test("signed OpenWA booking inquiry is ingested once after a duplicate retry", async ({ authenticatedPage }) => {
  test.setTimeout(60_000);
  const page = await authenticatedPage("single-membership");
  const suffix = Date.now().toString();
  const sessionId = await registerOpenWaChannel(page, suffix);
  const senderPhone = `+2010${suffix.slice(-8)}`;
  const contactName = `OpenWA E2E ${senderPhone.slice(-6)}`;
  const bodyText = "أبحث عن شقة مفروشة في مدينة نصر من 10 إلى 15 أكتوبر لثلاثة أشخاص.";
  const payload = openWaEnvelope({
    sessionId,
    senderPhone,
    id: `OPENWA_IN_${suffix}`,
    idempotencyKey: `openwa-e2e-${suffix}-in`,
    bodyText,
  });

  const first = await signedWebhook(page, payload);
  expect(first.status()).toBe(202);
  await expect(first.json()).resolves.toMatchObject({ accepted: true, events: 1 });
  const duplicate = await signedWebhook(page, payload);
  expect(duplicate.status()).toBe(202);
  await expect(duplicate.json()).resolves.toMatchObject({ accepted: true, events: 1 });

  await page.reload();
  const conversation = page.locator("article").filter({ hasText: contactName });
  await expect(conversation).toHaveCount(1);
  const messageThread = conversation.getByLabel("محادثة واتساب");
  await expect(messageThread.getByText(bodyText, { exact: true })).toHaveCount(1);
  await expect(conversation.getByText("AI نشط", { exact: true })).toBeVisible();
  await page.screenshot({ path: "/tmp/voya-openwa-inbox-authenticated.png", fullPage: true });
});

test("signed OpenWA group, channel, status, broadcast, and missing-kind events never enter the inbox", async ({ authenticatedPage }) => {
  test.setTimeout(60_000);
  const page = await authenticatedPage("single-membership");
  const suffix = Date.now().toString();
  const sessionId = await registerOpenWaChannel(page, suffix);
  const senderPhone = `+2010${suffix.slice(-8)}`;
  const rejectedCases = [
    { name: "group", chatId: "120363123456789@g.us", kind: "group", isGroup: true },
    { name: "channel", chatId: "123456789@newsletter", kind: "channel", isGroup: false },
    { name: "status", chatId: "status@broadcast", kind: "individual", isGroup: false, isStatusBroadcast: true },
    { name: "broadcast", chatId: "123456789@broadcast", kind: "individual", isGroup: false },
    { name: "missing-kind", chatId: `${senderPhone.slice(1)}@c.us`, kind: undefined, isGroup: false },
  ] as const;

  for (const [index, rejected] of rejectedCases.entries()) {
    const id = `OPENWA_${rejected.name}_${suffix}`;
    const payload = openWaEnvelope({
      sessionId,
      senderPhone,
      id,
      idempotencyKey: `openwa-e2e-${suffix}-${rejected.name}`,
      bodyText: `PRIVATE_OPENWA_SENTINEL_${rejected.name}_${suffix}`,
      dataOverrides: {
        chatId: rejected.chatId,
        from: rejected.chatId,
        kind: rejected.kind,
        isGroup: rejected.isGroup,
        isStatusBroadcast: "isStatusBroadcast" in rejected ? rejected.isStatusBroadcast : false,
      },
    });
    const response = await signedWebhook(page, payload);
    expect(response.status(), `rejected event ${index}: ${rejected.name}`).toBe(202);
    await expect(response.json()).resolves.toEqual({ accepted: true, ignored: true });
  }

  const tamperedPayload = openWaEnvelope({
    sessionId,
    senderPhone,
    id: `OPENWA_TAMPERED_${suffix}`,
    idempotencyKey: `openwa-e2e-${suffix}-tampered`,
    bodyText: `PRIVATE_OPENWA_TAMPERED_${suffix}`,
  });
  const tampered = await signedWebhook(page, tamperedPayload, true);
  expect(tampered.status()).toBe(401);

  await page.reload();
  for (const rejected of rejectedCases) {
    await expect(page.getByText(`PRIVATE_OPENWA_SENTINEL_${rejected.name}_${suffix}`, { exact: true })).toHaveCount(0);
  }
  await expect(page.getByText(`PRIVATE_OPENWA_TAMPERED_${suffix}`, { exact: true })).toHaveCount(0);
});

test("signed OpenWA phone echo appears once after an inbound request", async ({ authenticatedPage }) => {
  test.setTimeout(60_000);
  const page = await authenticatedPage("single-membership");
  const suffix = Date.now().toString();
  const sessionId = await registerOpenWaChannel(page, suffix);
  const senderPhone = `+2010${suffix.slice(-8)}`;
  const contactName = `OpenWA E2E ${senderPhone.slice(-6)}`;
  const inboundText = "أحتاج شقة في القاهرة خلال أكتوبر.";
  const outboundText = "وصل طلبك، وسيقوم الفريق بمراجعته.";
  const inbound = await signedWebhook(page, openWaEnvelope({
    sessionId,
    senderPhone,
    id: `OPENWA_IN_ECHO_${suffix}`,
    idempotencyKey: `openwa-e2e-${suffix}-in-echo`,
    bodyText: inboundText,
  }));
  expect(inbound.status()).toBe(202);

  const echo = await signedWebhook(page, openWaEnvelope({
    sessionId,
    senderPhone,
    id: `OPENWA_OUT_ECHO_${suffix}`,
    idempotencyKey: `openwa-e2e-${suffix}-out-echo`,
    event: "message.sent",
    bodyText: outboundText,
  }));
  expect(echo.status()).toBe(202);

  await page.reload();
  const conversation = page.locator("article").filter({ hasText: contactName });
  await expect(conversation).toHaveCount(1);
  const messageThread = conversation.getByLabel("محادثة واتساب");
  await expect(messageThread.getByText(inboundText, { exact: true })).toHaveCount(1);
  await expect(messageThread.getByText(outboundText, { exact: true })).toHaveCount(1);
});
