import { expect, type Response } from "@playwright/test";
import { generateTotpCode } from "../scripts/totp.cjs";
import {
  authCookieFingerprint,
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

test("maker-checker booking flow reaches confirmation and stay completion", async ({ authenticatedPage }) => {
  const ownerPage = await authenticatedPage("single-membership");
  await ownerPage.goto("/workspace/bookings");

  await ownerPage.getByLabel("العقار").selectOption({ label: "E2E-BOOKING — إقامة E2E" });
  await ownerPage.getByLabel("العميل").selectOption({ label: "عميل حجز E2E" });
  await ownerPage.getByLabel("تاريخ الوصول").fill("2027-02-01");
  await ownerPage.getByLabel("تاريخ المغادرة").fill("2027-02-04");
  await ownerPage.getByRole("button", { name: "إنشاء مسودة الحجز" }).click();
  await expect(ownerPage.getByText("تم إنشاء مسودة الحجز.")).toBeVisible();

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

  await ownerPage.goto("/workspace/bookings");
  await ownerPage.getByRole("button", { name: "تأكيد بعد الاعتماد" }).click();
  await expect(ownerPage.getByText("مؤكدة")).toBeVisible();
  await ownerPage.getByRole("button", { name: "تسجيل الوصول" }).click();
  await expect(ownerPage.getByText("تم تسجيل الوصول")).toBeVisible();
  await ownerPage.getByRole("button", { name: "تسجيل المغادرة" }).click();
  await expect(ownerPage.getByText("مكتملة")).toBeVisible();
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
    await page.getByLabel("كلمة المرور").fill(fixtures["single-membership"].password);
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

  await page.waitForTimeout(46_000);
  const response = await page.goto("/workspace/activity");

  expectPrivateProtectedResponse(response);
  await expect(page).toHaveURL(/\/workspace\/activity$/);
  expect(await authCookieFingerprint(page)).not.toBe(before);
});

test("sign-out revokes the session and returns to the public sign-in screen", async ({ authenticatedPage }) => {
  const page = await authenticatedPage("single-membership");
  await page.goto("/workspace");
  await page.getByRole("button", { name: "خروج" }).click();

  await expect(page).toHaveURL(/\/sign-in$/);
  await page.goto("/workspace");
  await expect(page).toHaveURL(/\/sign-in$/);
});
