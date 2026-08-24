import { createHmac } from "node:crypto";
import { expect, type Response } from "@playwright/test";
import { generateTotpCode } from "../scripts/totp.cjs";
import {
  authCookieFingerprint,
  expireAuthAccessToken,
  ORGANIZATION_COOKIE,
  test,
} from "./fixtures/local-auth";

function expectPrivateProtectedResponse(response: Response | null) {
  expect(response, "protected navigation must return a response").not.toBeNull();
  const headers = response!.headers();
  expect(headers["x-nextjs-prerender"]).toBeUndefined();
  expect((headers["x-nextjs-cache"] ?? "").toUpperCase()).not.toBe("HIT");
  expect(headers["cache-control"] ?? "").not.toMatch(/\bs-maxage\s*=/i);
  expect(headers["cache-control"] ?? "").not.toMatch(/\bpublic\b/i);
}

test("single membership reaches its protected workspace", async ({ authenticatedPage }) => {
  const page = await authenticatedPage("single-membership");
  const response = await page.goto("/workspace");

  expectPrivateProtectedResponse(response);
  await expect(page).toHaveURL(/\/workspace$/);
  await expect(page.getByRole("heading", { name: "لوحة التشغيل" })).toBeVisible();
  await expect(page.getByText("مزامنة المؤسسة مفعّلة")).toBeVisible();

  const bookingsResponse = await page.goto("/workspace/bookings");
  expectPrivateProtectedResponse(bookingsResponse);
  await expect(page.getByRole("heading", { name: "الإقامات والحجوزات" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "آخر الإقامات" })).toBeVisible();

  const whatsappResponse = await page.goto("/workspace/whatsapp");
  expectPrivateProtectedResponse(whatsappResponse);
  await expect(page.getByRole("heading", { name: "صندوق واتساب" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "لا توجد قناة نشطة بعد" })).toBeVisible();

  const aiResponse = await page.goto("/workspace/ai");
  expectPrivateProtectedResponse(aiResponse);
  await expect(page.getByRole("heading", { name: "مركز الذكاء" })).toBeVisible();
  await expect(page.getByText("تنفيذ تلقائي")).toBeVisible();

  const tasksResponse = await page.goto("/workspace/tasks");
  expectPrivateProtectedResponse(tasksResponse);
  await expect(page.getByRole("heading", { name: "مهام التشغيل" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "لا توجد مهام بعد" })).toBeVisible();

  const transportResponse = await page.goto("/workspace/transport");
  expectPrivateProtectedResponse(transportResponse);
  await expect(page.getByRole("heading", { name: "السيارات والتحويلات" })).toBeVisible();
  await expect(page.getByText("لا توجد مركبات")).toBeVisible();

  const guestLabel = `ضيف E2E ${Date.now()}`;
  await page.getByLabel("اسم الضيف أو المرجع").fill(guestLabel);
  await page.getByLabel("نقطة الالتقاط").fill("مطار القاهرة");
  await page.getByLabel("نقطة الوصول").fill("العقار التجريبي");
  await page.getByLabel("موعد الالتقاط").fill("2027-01-01T12:30");
  await page.getByRole("spinbutton", { name: "الركاب", exact: true }).fill("2");
  await page.getByRole("button", { name: "إضافة الطلب" }).click();
  await expect(page.getByText("تم تسجيل طلب النقل في قائمة التشغيل.")).toBeVisible();
  await expect(page.getByRole("heading", { name: guestLabel })).toBeVisible();

  await page.screenshot({ path: "/tmp/voya-transport-authenticated.png", fullPage: true });
  await page.setViewportSize({ width: 390, height: 844 });
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBeLessThanOrEqual(await page.evaluate(() => document.documentElement.clientWidth));
  await page.screenshot({ path: "/tmp/voya-transport-mobile.png", fullPage: true });
});

test("single membership can render every protected workspace route", async ({ authenticatedPage }) => {
  const page = await authenticatedPage("single-membership");
  const routes = [
    ["/workspace/activity", "سجل النشاط"],
    ["/workspace/approvals", "طلبات الموافقة"],
    ["/workspace/availability", "حظر التوفر"],
    ["/workspace/clients", "العملاء"],
    ["/workspace/health", "صحة النظام"],
    ["/workspace/leads", "العملاء المحتملون"],
    ["/workspace/notifications", "الإشعارات"],
    ["/workspace/properties", "العقارات"],
    ["/workspace/property-owners", "ملاك العقارات"],
  ] as const;

  for (const [path, heading] of routes) {
    const response = await page.goto(path);
    expectPrivateProtectedResponse(response);
    await expect(page).toHaveURL(new RegExp(`${path}$`));
    await expect(page.getByRole("heading", { name: heading, level: 1 })).toBeVisible();
  }
});

test("transport operations provision a fleet, assign a request, notify the requester, and complete the trip", async ({ authenticatedPage }) => {
  test.setTimeout(60_000);
  const page = await authenticatedPage("single-membership");
  await page.goto("/workspace/transport");

  const suffix = Date.now();
  const vehicleName = `فان دورة E2E ${suffix}`;
  const registrationCode = `E2E-TR-${suffix}`;
  const driverName = `سائق دورة E2E ${suffix}`;
  const guestLabel = `ضيف نقل E2E ${suffix}`;

  await page.getByLabel("اسم المركبة").fill(vehicleName);
  await page.getByLabel("النوع").selectOption("van");
  await page.getByLabel("رمز التسجيل").fill(registrationCode);
  await page.getByRole("button", { name: "حفظ المركبة" }).click();
  await expect(page.getByText("تم تسجيل المركبة.", { exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: vehicleName })).toBeVisible();

  await page.getByLabel("اسم السائق").fill(driverName);
  await page.getByLabel("الهاتف (اختياري)").fill("+201001234568");
  await page.getByRole("button", { name: "حفظ السائق" }).click();
  await expect(page.getByText("تم تسجيل السائق.", { exact: true })).toBeVisible();
  await expect(page.getByRole("heading", { name: driverName })).toBeVisible();

  await page.getByLabel("اسم الضيف أو المرجع").fill(guestLabel);
  await page.getByLabel("نقطة الالتقاط").fill("مطار القاهرة");
  await page.getByLabel("نقطة الوصول").fill("العقار التجريبي");
  await page.getByLabel("موعد الالتقاط").fill("2027-01-02T12:30");
  await page.getByRole("spinbutton", { name: "الركاب", exact: true }).fill("2");
  await page.getByRole("button", { name: "إضافة الطلب" }).click();
  await expect(page.getByText("تم تسجيل طلب النقل في قائمة التشغيل.", { exact: true })).toBeVisible();

  const requestCard = page.locator("article").filter({ has: page.getByRole("heading", { name: guestLabel }) });
  await expect(requestCard.getByText("مطلوب", { exact: true })).toBeVisible();
  await requestCard.locator('select[name="vehicle_id"]').selectOption({ label: `${vehicleName} · ${registrationCode}` });
  await requestCard.locator('select[name="driver_id"]').selectOption({ label: driverName });
  await requestCard.getByRole("button", { name: "حفظ الإسناد" }).click();
  await expect(requestCard.getByText("تم تحديث إسناد الطلب.", { exact: true })).toBeVisible();
  await expect(requestCard.getByText("تم الإسناد", { exact: true })).toBeVisible();
  await expect(requestCard.getByText(`${vehicleName} · ${driverName}`, { exact: true })).toBeVisible();

  await page.goto("/workspace/notifications");
  const assignmentNotification = page.locator("article").filter({ hasText: guestLabel });
  await expect(assignmentNotification.getByRole("heading", { name: "تم إسناد طلب نقل" })).toBeVisible();
  await assignmentNotification.getByRole("button", { name: "تمت القراءة" }).click();
  await expect(assignmentNotification.getByRole("button", { name: "تمت القراءة" })).toHaveCount(0);

  await page.goto("/workspace/transport");
  const refreshedRequestCard = page.locator("article").filter({ has: page.getByRole("heading", { name: guestLabel }) });
  await refreshedRequestCard.getByRole("button", { name: "بدء التنفيذ" }).click();
  await expect(refreshedRequestCard.getByText("قيد التنفيذ", { exact: true })).toBeVisible();
  await refreshedRequestCard.getByRole("button", { name: "إكمال", exact: true }).click();
  await expect(refreshedRequestCard.getByText("مكتمل", { exact: true })).toBeVisible();
});

test("signed WhatsApp inbound creates a conversation and staff can queue a reviewed reply", async ({ authenticatedPage }) => {
  test.setTimeout(60_000);
  const page = await authenticatedPage("single-membership");
  await page.goto("/workspace/whatsapp");

  const webhookSecret = process.env.VOYA_AUTH_E2E_META_APP_SECRET;
  if (!webhookSecret) throw new Error("Disposable WhatsApp webhook secret is missing.");
  const suffix = Date.now();
  const externalChannelId = `E2E-WA-${suffix}`;
  const channelName = `قناة واتساب E2E ${suffix}`;
  const senderPhone = `+2010${suffix.toString().slice(-8)}`;
  const inboundBody = `رسالة واردة E2E ${suffix}`;
  const noteBody = `ملاحظة داخلية E2E ${suffix}`;
  const outboundBody = `رد يدوي E2E ${suffix}`;

  await page.locator('input[name="provider"]').fill("meta_cloud");
  await page.locator('input[name="external_channel_id"]').fill(externalChannelId);
  await page.locator('input[name="display_name"]').fill(channelName);
  await page.getByRole("button", { name: "حفظ تعريف القناة" }).click();
  await expect(page.getByText(/تم حفظ تعريف القناة/u)).toBeVisible();

  const payload = JSON.stringify({
    entry: [{
      changes: [{
        field: "messages",
        value: {
          metadata: { phone_number_id: externalChannelId },
          messages: [{ id: `wamid-e2e-${suffix}`, from: senderPhone, type: "text", text: { body: inboundBody } }],
        },
      }],
    }],
  });
  const signature = createHmac("sha256", webhookSecret).update(payload).digest("hex");
  const webhookResponse = await page.request.post("/api/webhooks/whatsapp", {
    data: payload,
    headers: { "content-type": "application/json", "x-hub-signature-256": `sha256=${signature}` },
  });
  expect(webhookResponse.status()).toBe(202);
  await expect(webhookResponse.json()).resolves.toEqual({ accepted: true, events: 1 });

  await page.reload();
  const conversation = page.locator("article").filter({ hasText: senderPhone });
  await expect(conversation.getByText(inboundBody, { exact: true })).toBeVisible();
  await conversation.getByLabel("ملاحظة داخلية").fill(noteBody);
  await conversation.getByRole("button", { name: "حفظ الملاحظة" }).click();
  await expect(page.getByText("تم حفظ الملاحظة الداخلية.", { exact: true })).toBeVisible();
  await conversation.getByLabel("رد يدوي").fill(outboundBody);
  await conversation.getByRole("button", { name: "تسجيل الرد للإرسال" }).click();
  await expect(page.getByText(/تم تسجيل الرد في قائمة الإرسال/u)).toBeVisible();

  await page.reload();
  const refreshedConversation = page.locator("article").filter({ hasText: senderPhone });
  await expect(refreshedConversation.getByText(outboundBody, { exact: true })).toBeVisible();
});

test("AI preview request is recorded as a queued proposal without automatic execution", async ({ authenticatedPage }) => {
  const page = await authenticatedPage("single-membership");
  await page.goto("/workspace/ai");

  const purpose = `ملخص متابعة E2E ${Date.now()}`;
  const salesAgentCard = page.locator("article").filter({ has: page.getByRole("heading", { name: "مساعد المبيعات" }) });
  await salesAgentCard.getByLabel("ما المطلوب؟").fill(purpose);
  await salesAgentCard.getByRole("button", { name: "تسجيل طلب مساعدة" }).click();

  const runCard = page.locator("article").filter({ has: page.getByRole("heading", { name: purpose, level: 3 }) });
  await expect(runCard).toBeVisible();
  await expect(runCard.getByText("في قائمة الانتظار", { exact: true })).toBeVisible();
  await expect(page.getByText("تنفيذ تلقائي", { exact: true })).toBeVisible();
});

test("AI data-entry collects text and a private image without writing before confirmation", async ({ authenticatedPage }) => {
  test.setTimeout(60_000);
  const page = await authenticatedPage("single-membership");
  await page.goto("/workspace/ai");

  const uniqueClientName = `عميل مسودة E2E ${Date.now()}`;
  await page.getByRole("textbox", { name: "بيانات العملاء أو العقارات" }).fill(`اسم العميل ${uniqueClientName}`);
  await page.getByRole("button", { name: "تجهيز مسودة" }).click();
  await expect(page.getByText("تم تجهيز المسودة لرفع الصور وإرسالها للاستخراج.", { exact: true })).toBeVisible();
  await expect(page.getByText("مسودة نشطة", { exact: true })).toBeVisible();

  const imageBytes = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=", "base64");
  await page.locator('input[aria-label="رفع صور مرجعية"]').setInputFiles({ name: "intake-e2e.png", mimeType: "image/png", buffer: imageBytes });
  await expect(page.getByText(/تم رفع 1 صورة خاصة للمسودة/u)).toBeVisible();
  await page.getByRole("button", { name: "إرسال للاستخراج والمراجعة" }).click();
  await expect(page.getByText("في قائمة الانتظار", { exact: true }).first()).toBeVisible();

  await page.goto("/workspace/clients");
  await expect(page.getByRole("heading", { name: uniqueClientName, exact: true })).toHaveCount(0);
});

test("property lifecycle creates, edits, and archives inventory through the browser", async ({ authenticatedPage }) => {
  test.setTimeout(60_000);
  const page = await authenticatedPage("single-membership");
  await page.goto("/workspace/properties");

  const suffix = Date.now();
  const propertyCode = `E2E-${suffix}`;
  const propertyName = `عقار دورة E2E ${suffix}`;
  const updatedPropertyName = `${propertyName} محدث`;

  await page.getByLabel("رمز العقار").fill(propertyCode);
  await page.getByLabel("اسم العقار").fill(propertyName);
  await page.getByRole("button", { name: "إضافة العقار" }).click();
  await expect(page.getByText("تمت إضافة العقار.")).toBeVisible();

  const propertyCard = page.locator("article").filter({ hasText: propertyCode });
  await expect(propertyCard.getByRole("heading", { name: propertyName })).toBeVisible();

  const editDetails = propertyCard.locator("details").filter({ hasText: "تعديل بيانات العقار" });
  await editDetails.locator("summary").click();
  await editDetails.locator('input[name="name"]').fill(updatedPropertyName);
  await editDetails.getByRole("button", { name: "حفظ التعديل" }).click();
  await expect(page.getByText("تم تحديث بيانات العقار.")).toBeVisible();
  await expect(propertyCard.getByRole("heading", { name: updatedPropertyName })).toBeVisible();

  const archiveDetails = propertyCard.locator("details").filter({ hasText: "أرشفة العقار" });
  await archiveDetails.locator("summary").click();
  await archiveDetails.getByLabel("سبب الأرشفة").fill("انتهاء الاختبار التشغيلي");
  await archiveDetails.getByRole("button", { name: "تأكيد الأرشفة" }).click();
  await expect(propertyCard.getByText("مؤرشف", { exact: true })).toBeVisible();
  await expect(propertyCard.getByText("تعديل بيانات العقار", { exact: true })).toHaveCount(0);
});

test("property owner lifecycle restores and links an owner to inventory through the browser", async ({ authenticatedPage }) => {
  test.setTimeout(60_000);
  const page = await authenticatedPage("single-membership");
  await page.goto("/workspace/property-owners");

  const suffix = Date.now();
  const ownerName = `مالك دورة E2E ${suffix}`;
  const updatedOwnerName = `${ownerName} محدث`;
  await page.getByLabel("اسم المالك").fill(ownerName);
  await page.getByRole("textbox", { name: "الهاتف", exact: true }).fill("+201000000000");
  await page.getByLabel("وسيلة الاتصال المفضلة").selectOption("phone");
  await page.getByRole("button", { name: "إضافة المالك" }).click();
  await expect(page.getByText("تمت إضافة المالك.")).toBeVisible();

  const ownerCard = page.locator("article").filter({ hasText: ownerName });
  await expect(ownerCard.getByRole("heading", { name: ownerName })).toBeVisible();

  const editDetails = ownerCard.locator("details").filter({ hasText: "تعديل بيانات المالك" });
  await editDetails.locator("summary").click();
  await editDetails.locator('input[name="display_name"]').fill(updatedOwnerName);
  await editDetails.getByRole("button", { name: "حفظ التعديل" }).click();
  await expect(ownerCard.getByRole("heading", { name: updatedOwnerName })).toBeVisible();

  const archiveDetails = ownerCard.locator("details").filter({ hasText: "أرشفة المالك" });
  await archiveDetails.locator("summary").click();
  await archiveDetails.getByLabel("سبب الأرشفة").fill("انتهاء الاختبار التشغيلي");
  await archiveDetails.getByRole("button", { name: "تأكيد الأرشفة" }).click();
  await expect(ownerCard.getByText("مؤرشف", { exact: true })).toBeVisible();

  const restoreDetails = ownerCard.locator("details").filter({ hasText: "استعادة المالك" });
  await restoreDetails.locator("summary").click();
  await restoreDetails.getByRole("button", { name: "استعادة المالك" }).click();
  await expect(ownerCard.getByText("نشط", { exact: true }).first()).toBeVisible();

  await page.goto("/workspace/properties");
  const propertyCard = page.locator("article").filter({ has: page.getByRole("heading", { name: "إقامة E2E" }) });
  const assignmentDetails = propertyCard.locator("details").filter({ hasText: "ربط مالك بالعقار" });
  await assignmentDetails.locator("summary").click();
  await assignmentDetails.locator('select[name="property_owner_id"]').selectOption({ label: updatedOwnerName });
  await assignmentDetails.locator('input[name="start_date"]').fill("2026-01-01");
  await assignmentDetails.locator('input[name="end_date"]').fill("2027-12-31");
  await assignmentDetails.getByLabel("جهة الاتصال الأساسية لهذا النطاق").check();
  await assignmentDetails.getByRole("button", { name: "حفظ ربط المالك" }).click();
  await expect(propertyCard.getByText(`المالك: ${updatedOwnerName}`)).toBeVisible();
});

test("property image upload stores a private image and serves a signed retrieval", async ({ authenticatedPage }) => {
  test.setTimeout(60_000);
  const page = await authenticatedPage("single-membership");
  await page.goto("/workspace/properties");

  const propertyCard = page.locator("article").filter({ has: page.getByRole("heading", { name: "إقامة E2E" }) });
  const imageBytes = Buffer.concat([
    Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
      "base64",
    ),
    // Keep this regression fixture above the former 1MB Server Action limit
    // while staying well below the application's 10MB image limit.
    Buffer.alloc(1_100_000),
  ]);
  await propertyCard.locator('input[type="file"]').setInputFiles({
    name: "property-e2e.png",
    mimeType: "image/png",
    buffer: imageBytes,
  });
  await propertyCard.getByRole("button", { name: "حفظ الصورة" }).click();

  await expect(propertyCard.getByText("تم حفظ الصورة في التخزين الخاص.")).toBeVisible();
  await expect(propertyCard.getByText("1 صور خاصة")).toBeVisible();
  const imageLink = propertyCard.getByRole("link", { name: "فتح الصورة 1" });
  await expect(imageLink).toBeVisible();

  const href = await imageLink.getAttribute("href");
  expect(href).toBeTruthy();
  const imageResponse = await page.request.get(new URL(href!, page.url()).toString());
  expect(imageResponse.status()).toBe(200);
  expect(imageResponse.headers()["content-type"]).toMatch(/^image\/png(?:;|$)/i);
  expect(Buffer.compare(await imageResponse.body(), imageBytes)).toBe(0);

  const otherTenantPage = await authenticatedPage("multi-membership");
  await otherTenantPage.goto("/workspace");
  await otherTenantPage.getByRole("button", { name: /Voya Local Beta/ }).click();
  await expect(otherTenantPage.getByRole("heading", { name: "لوحة التشغيل" })).toBeVisible();
  const crossTenantResponse = await otherTenantPage.goto(new URL(href!, otherTenantPage.url()).toString());
  expect(crossTenantResponse, "cross-tenant image navigation must return a response").not.toBeNull();
  expect(crossTenantResponse!.status()).toBe(404);
});

test("CRM lead activity and follow-up convert atomically into a client", async ({ authenticatedPage }) => {
  test.setTimeout(60_000);
  const page = await authenticatedPage("single-membership");
  await page.goto("/workspace/leads");

  const leadName = `طلب CRM E2E ${Date.now()}`;
  await page.getByLabel("اسم / عنوان الطلب").fill(leadName);
  await page.getByLabel("الهاتف").fill(`+2010${Date.now().toString().slice(-8)}`);
  await page.getByLabel("المنطقة المطلوبة").fill("المعادي");
  await page.getByLabel("عدد الضيوف").fill("3");
  await page.getByRole("button", { name: "إضافة الطلب" }).click();
  await expect(page.getByText("تمت إضافة طلب CRM.")).toBeVisible();

  const leadCard = page.locator("article").filter({ has: page.getByRole("heading", { name: leadName }) });
  await expect(leadCard).toBeVisible();
  const activityDetails = leadCard.locator("details").filter({ hasText: "النشاط والمتابعات" });
  const openActivityDetails = async () => {
    if (!(await activityDetails.getByLabel("ما الذي حدث؟").isVisible())) {
      await activityDetails.locator("summary").click();
    }
  };

  await openActivityDetails();
  await activityDetails.getByLabel("ما الذي حدث؟").fill("تم التواصل وتأكيد احتياج إقامة عائلية.");
  await activityDetails.getByRole("button", { name: "إضافة للسجل" }).click();
  await expect(activityDetails.getByText("تمت إضافة النشاط إلى السجل.")).toBeVisible();

  await openActivityDetails();
  await activityDetails.getByLabel("موعد المتابعة").fill("2027-01-05T10:30");
  await activityDetails.getByLabel("المطلوب تنفيذه").fill("إرسال الخيارات المتاحة للمراجعة.");
  await activityDetails.getByRole("button", { name: "جدولة متابعة" }).click();
  await expect(activityDetails.getByText("تمت جدولة المتابعة.")).toBeVisible();

  await openActivityDetails();
  await activityDetails.getByLabel("ملاحظة الإكمال").fill("تم إرسال الخيارات.");
  await activityDetails.getByRole("button", { name: "إكمال", exact: true }).click();
  await expect(activityDetails.getByText("مكتملة", { exact: true })).toBeVisible();

  await leadCard.getByRole("button", { name: "تحويل إلى عميل" }).click();
  await expect(leadCard.getByText("تحويل ناجح", { exact: true })).toBeVisible();

  await page.goto("/workspace/clients");
  await expect(page.getByRole("heading", { name: leadName })).toBeVisible();
});

test("assigned operations task creates a notification and completes through the browser", async ({ authenticatedPage }) => {
  test.setTimeout(60_000);
  const ownerPage = await authenticatedPage("single-membership");
  await ownerPage.goto("/workspace/tasks");

  const taskTitle = `مهمة تشغيل E2E ${Date.now()}`;
  const assigneeSelect = ownerPage.getByLabel("الإسناد");
  const assigneeOption = assigneeSelect.locator("option").filter({ hasText: "Local Auth Fixture 2" });
  const assigneeValue = await assigneeOption.getAttribute("value");
  expect(assigneeValue).toBeTruthy();
  await assigneeSelect.selectOption(assigneeValue!);
  await ownerPage.getByLabel("عنوان المهمة").fill(taskTitle);
  await ownerPage.getByLabel("التفاصيل").fill("مراجعة تجهيزات الوصول قبل موعد الضيف.");
  await ownerPage.getByRole("button", { name: "إضافة المهمة" }).click();
  await expect(ownerPage.getByText("تمت إضافة المهمة.")).toBeVisible();

  const taskCard = ownerPage.locator("article").filter({ has: ownerPage.getByRole("heading", { name: taskTitle, level: 3 }) });
  await expect(taskCard.getByText("مسندة إلى Local Auth Fixture 2")).toBeVisible();

  const managerPage = await authenticatedPage("multi-membership");
  await managerPage.goto("/workspace");
  await managerPage.getByRole("button", { name: /Voya Local Alpha/ }).click();
  await expect(managerPage.getByRole("heading", { name: "لوحة التشغيل" })).toBeVisible();
  await managerPage.goto("/workspace/notifications");
  const taskNotification = managerPage.locator("article").filter({ has: managerPage.getByRole("heading", { name: "مهمة تشغيل جديدة" }) });
  await expect(taskNotification.getByText("تم إسناد مهمة تشغيلية جديدة إليك للمراجعة والتنفيذ.")).toBeVisible();
  await taskNotification.getByRole("button", { name: "تمت القراءة" }).click();
  await expect(taskNotification.getByRole("button", { name: "تمت القراءة" })).toHaveCount(0);

  await ownerPage.getByRole("button", { name: "قيد التنفيذ" }).click();
  await expect(taskCard.getByText("قيد التنفيذ")).toBeVisible();
  await taskCard.getByRole("button", { name: "إكمال" }).click();
  await expect(taskCard.getByText("مكتملة")).toBeVisible();
});

test("owner can create and revoke a team invitation through the browser", async ({ authenticatedPage }) => {
  test.setTimeout(60_000);
  const page = await authenticatedPage("single-membership");
  await page.goto("/workspace/team");

  const email = `team-e2e-${Date.now()}@voya.invalid`;
  await page.getByLabel("البريد الإلكتروني").fill(email);
  await page.getByLabel("الدور").selectOption("operator");
  await page.getByRole("button", { name: "إرسال الدعوة" }).click();
  await expect(page.getByText("تم إنشاء الدعوة وستُرسل عبر قناة البريد المعتمدة.")).toBeVisible();

  const invitation = page.locator("article").filter({ hasText: email });
  await expect(invitation.getByText("معلقة")).toBeVisible();
  await invitation.getByRole("button", { name: "إلغاء الدعوة" }).click();
  await expect(invitation.getByText("ملغاة")).toBeVisible();
});

test("maker-checker booking flow reaches confirmation and stay completion", async ({ authenticatedPage }) => {
  test.setTimeout(60_000);
  const ownerPage = await authenticatedPage("single-membership");
  await ownerPage.goto("/workspace/bookings");

  await ownerPage.getByLabel("العقار").selectOption({ label: "E2E-BOOKING — إقامة E2E" });
  await ownerPage.getByLabel("العميل").selectOption({ label: "عميل حجز E2E" });
  await ownerPage.getByLabel("تاريخ الوصول").fill("2027-02-01");
  await ownerPage.getByLabel("تاريخ المغادرة").fill("2027-02-04");
  await ownerPage.getByLabel("المبلغ المتفق عليه").fill("2500000");
  await ownerPage.getByRole("button", { name: "إنشاء مسودة الحجز التجاري" }).click();
  await expect(ownerPage.getByText("تم إنشاء مسودة الحجز التجاري.")).toBeVisible();

  await ownerPage.getByRole("button", { name: "طلب اعتماد" }).click();
  await expect(ownerPage.getByText("بانتظار قرار مالك أو مدير")).toBeVisible();
  await expect(ownerPage.getByRole("button", { name: "تأكيد بعد الاعتماد" })).toBeVisible();

  const managerPage = await authenticatedPage("multi-membership");
  await managerPage.goto("/workspace");
  await managerPage.getByRole("button", { name: /Voya Local Alpha/ }).click();
  await expect(managerPage.getByRole("heading", { name: "لوحة التشغيل" })).toBeVisible();
  await managerPage.goto("/workspace/approvals");
  await expect(managerPage.getByRole("heading", { name: "تأكيد حجز" })).toBeVisible();
  await managerPage.getByPlaceholder("تمت مراجعة التواريخ والطلب").fill("تمت مراجعة التواريخ والتوفر.");
  await managerPage.getByRole("button", { name: "اعتماد" }).click();
  await expect(managerPage.getByText("مقبول")).toBeVisible();
  await expect(managerPage.getByRole("button", { name: "اعتماد" })).toHaveCount(0);

  // Maker-checker: the requester cannot confirm their own approved booking.
  await ownerPage.goto("/workspace/bookings");
  await ownerPage.getByRole("button", { name: "تأكيد بعد الاعتماد" }).click();
  await expect(ownerPage.getByText("لا تملك صلاحية تأكيد الحجز.")).toBeVisible();

  await managerPage.goto("/workspace/bookings");
  await managerPage.getByRole("button", { name: "تأكيد بعد الاعتماد" }).click();
  await expect(managerPage.getByText("مؤكدة")).toBeVisible();
  await managerPage.goto("/workspace/tasks");
  await expect(managerPage.getByText("إعادة تأكيد الإقامة قبل الوصول")).toBeVisible();
  await managerPage.goto("/workspace/bookings");
  await managerPage.getByRole("button", { name: "تسجيل الوصول" }).click();
  await expect(managerPage.getByText("تم تسجيل الوصول")).toBeVisible();
  const [checkoutResponse] = await Promise.all([
    managerPage.waitForResponse((response) => (
      response.request().method() === "POST"
      && new URL(response.url()).pathname === "/workspace/bookings"
    )),
    managerPage.getByRole("button", { name: "تسجيل المغادرة" }).click(),
  ]);
  expect(checkoutResponse.status()).toBe(200);
  await managerPage.reload();
  await expect(managerPage.getByText("تمت المغادرة")).toBeVisible();
  await expect(managerPage.getByRole("button", { name: "تسجيل المغادرة" })).toHaveCount(0);
});

test("password sign-in creates a session through the real server action", async ({ browser }) => {
  const fixtureJson = process.env.VOYA_AUTH_E2E_FIXTURES;
  if (!fixtureJson) throw new Error("Local Auth fixtures are missing.");
  const fixtures = JSON.parse(fixtureJson) as { "single-membership": { email: string; password: string; totpSecret: string } };
  const context = await browser.newContext();
  const page = await context.newPage();

  try {
    await page.goto("/sign-in");
    await page.getByLabel("البريد الإلكتروني").first().fill(fixtures["single-membership"].email);
    await page.getByRole("textbox", { name: "كلمة المرور", exact: true }).fill(fixtures["single-membership"].password);
    await page.getByRole("button", { name: "دخول بالبريد وكلمة المرور" }).click();

    await expect(page).toHaveURL(/\/security\/mfa\?reason=challenge$/);
    await page.getByLabel("رمز تطبيق المصادقة").fill(generateTotpCode(fixtures["single-membership"].totpSecret));
    await page.getByRole("button", { name: "تحقق وادخل مساحة العمل" }).click();
    await expect(page).toHaveURL(/\/workspace$/);
    await expect(page.getByRole("heading", { name: "لوحة التشغيل" })).toBeVisible();
  } finally {
    await context.close();
  }
});

test("multi-membership selection persists across navigation", async ({ authenticatedPage }) => {
  const page = await authenticatedPage("multi-membership");
  const response = await page.goto("/workspace");

  expectPrivateProtectedResponse(response);
  await expect(page.getByRole("heading", { name: "أين تريد أن تعمل اليوم؟" })).toBeVisible();
  await page.getByRole("button", { name: /Voya Local Beta/ }).click();
  await expect(page.getByRole("heading", { name: "لوحة التشغيل" })).toBeVisible();

  const navigation = await page.reload();
  expectPrivateProtectedResponse(navigation);
  await expect(page.getByRole("heading", { name: "لوحة التشغيل" })).toBeVisible();
});

test("forged organization selection fails closed", async ({ authenticatedPage }) => {
  const page = await authenticatedPage("multi-membership");
  const baseURL = test.info().project.use.baseURL;
  if (typeof baseURL !== "string") throw new Error("Authenticated browser base URL is missing.");
  await page.context().addCookies([{
    name: ORGANIZATION_COOKIE,
    value: "00000000-0000-4000-8000-000000000999",
    url: baseURL,
    httpOnly: true,
    sameSite: "Lax",
  }]);

  const response = await page.goto("/workspace");
  expectPrivateProtectedResponse(response);
  await expect(page.getByRole("heading", { name: "أين تريد أن تعمل اليوم؟" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Voya Local Alpha" })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Voya Local Beta" })).toHaveCount(0);
});

test("suspended membership cannot enter a workspace", async ({ suspendedPage }) => {
  const response = await suspendedPage.goto("/workspace");
  const protectedRequest = response?.request().redirectedFrom();
  const protectedResponse = protectedRequest ? await protectedRequest.response() : null;

  expectPrivateProtectedResponse(protectedResponse);
  await expect(suspendedPage).toHaveURL(/\/access-pending$/);
  await expect(
    suspendedPage.getByRole("heading", { name: "لا توجد مساحة عمل متاحة الآن" }),
  ).toBeVisible();
});

test("expired access token refreshes on protected navigation", async ({ authenticatedPage }) => {
  test.setTimeout(90_000);
  const page = await authenticatedPage("single-membership");
  await page.goto("/workspace");
  const before = await authCookieFingerprint(page);
  const secondPage = await page.context().newPage();
  await secondPage.goto("/workspace");

  await expireAuthAccessToken(page);
  const [propertiesResponse, secondResponse] = await Promise.all([
    page.goto("/workspace/properties"),
    secondPage.goto("/workspace/notifications"),
  ]);

  expectPrivateProtectedResponse(propertiesResponse);
  expectPrivateProtectedResponse(secondResponse);
  await expect(page).toHaveURL(/\/workspace\/properties$/);
  await expect(page.getByRole("heading", { name: "العقارات" })).toBeVisible();
  await expect(secondPage).toHaveURL(/\/workspace\/notifications$/);
  expect(await authCookieFingerprint(page)).not.toBe(before);
  expect(await authCookieFingerprint(secondPage)).not.toBe(before);

  const activityResponse = await page.goto("/workspace/activity");
  expectPrivateProtectedResponse(activityResponse);
  await expect(page).toHaveURL(/\/workspace\/activity$/);
});

test("sign-out revokes the session and returns to the public sign-in screen", async ({ authenticatedPage }) => {
  const page = await authenticatedPage("single-membership");
  await page.goto("/workspace");
  await page.getByRole("button", { name: "خروج" }).click();

  await expect(page).toHaveURL(/\/sign-in$/);
  await page.goto("/workspace");
  await expect(page).toHaveURL(/\/sign-in$/);
});
