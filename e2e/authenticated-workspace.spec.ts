import { expect, type Response } from "@playwright/test";
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
  await expect(page.getByRole("heading", { name: "Voya Local Alpha" })).toBeVisible();
});

test("multi-membership selection persists across navigation", async ({ authenticatedPage }) => {
  const page = await authenticatedPage("multi-membership");
  const response = await page.goto("/workspace");

  expectPrivateProtectedResponse(response);
  await expect(page.getByRole("heading", { name: "اختر مساحة العمل" })).toBeVisible();
  await page.getByRole("button", { name: /Voya Local Beta/ }).click();
  await expect(page.getByRole("heading", { name: "Voya Local Beta" })).toBeVisible();

  const navigation = await page.reload();
  expectPrivateProtectedResponse(navigation);
  await expect(page.getByRole("heading", { name: "Voya Local Beta" })).toBeVisible();
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
  await expect(page.getByRole("heading", { name: "اختر مساحة العمل" })).toBeVisible();
  await expect(page.getByRole("heading", { name: "Voya Local Alpha" })).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "Voya Local Beta" })).toHaveCount(0);
});

test("suspended membership cannot enter a workspace", async ({ suspendedPage }) => {
  const response = await suspendedPage.goto("/workspace");

  expectPrivateProtectedResponse(response);
  await expect(suspendedPage).toHaveURL(/\/access-pending$/);
  await expect(
    suspendedPage.getByRole("heading", { name: "لا توجد مساحة عمل متاحة الآن" }),
  ).toBeVisible();
});

test("expired access token refreshes on protected navigation", async ({ authenticatedPage }) => {
  const page = await authenticatedPage("single-membership");
  await page.goto("/workspace");
  const before = await authCookieFingerprint(page);

  await page.waitForTimeout(6_000);
  const response = await page.goto("/workspace/activity");

  expectPrivateProtectedResponse(response);
  await expect(page).toHaveURL(/\/workspace\/activity$/);
  expect(await authCookieFingerprint(page)).not.toBe(before);
});
