import { createHash } from "node:crypto";
import { createServerClient } from "@supabase/ssr";
import { generateTotpCode } from "../../scripts/totp.cjs";
import {
  test as base,
  type Browser,
  type BrowserContext,
  type Cookie,
  type Page,
} from "@playwright/test";

export const ORGANIZATION_COOKIE = "voya-organization-id";
const LOOPBACK_HOSTNAMES = new Set(["127.0.0.1", "localhost", "[::1]"]);

export type LocalAuthFixtureName = "single-membership" | "multi-membership";

type LocalCredential = Readonly<{
  email: string;
  password: string;
  totpSecret: string;
}>;

type LocalFixtureManifest = Readonly<{
  "single-membership": LocalCredential;
  "multi-membership": LocalCredential;
  suspended: LocalCredential;
}>;

type AuthenticatedPageFactory = (fixture: LocalAuthFixtureName) => Promise<Page>;

type LocalAuthFixtures = {
  authenticatedPage: AuthenticatedPageFactory;
  suspendedPage: Page;
};

type CookieToSet = Readonly<{
  name: string;
  value: string;
  options?: Readonly<{
    httpOnly?: boolean;
    secure?: boolean;
    sameSite?: boolean | "lax" | "strict" | "none";
  }>;
}>;

function readLocalConfiguration(): Readonly<{
  apiUrl: string;
  applicationOrigin: string;
  publishableKey: string;
  fixtures: LocalFixtureManifest;
}> {
  const apiUrl = process.env.NEXT_PUBLIC_SUPABASE_URL?.trim();
  const applicationOrigin = process.env.VOYA_AUTH_E2E_APP_ORIGIN?.trim();
  const publishableKey = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY?.trim();
  const fixtureJson = process.env.VOYA_AUTH_E2E_FIXTURES;
  if (
    !apiUrl
    || !applicationOrigin
    || !publishableKey
    || !fixtureJson
    || process.env.VOYA_AUTH_E2E_LOCAL !== "1"
  ) {
    throw new Error("Local authenticated browser fixture is not configured.");
  }

  const parsedUrl = new URL(apiUrl);
  const parsedApplicationOrigin = new URL(applicationOrigin);
  if (
    !LOOPBACK_HOSTNAMES.has(parsedUrl.hostname)
    || !LOOPBACK_HOSTNAMES.has(parsedApplicationOrigin.hostname)
    || !["http:", "https:"].includes(parsedApplicationOrigin.protocol)
  ) {
    throw new Error("Authenticated browser fixtures require loopback Supabase and application URLs.");
  }

  return {
    apiUrl: parsedUrl.toString().replace(/\/$/, ""),
    applicationOrigin: parsedApplicationOrigin.origin,
    publishableKey,
    fixtures: JSON.parse(fixtureJson) as LocalFixtureManifest,
  };
}

function playwrightSameSite(
  value: boolean | "lax" | "strict" | "none" | undefined,
): "Strict" | "Lax" | "None" | undefined {
  if (value === "strict") return "Strict";
  if (value === "none") return "None";
  if (value === "lax" || value === true) return "Lax";
  return undefined;
}

async function signInContext(
  browser: Browser,
  credential: LocalCredential,
): Promise<Readonly<{ context: BrowserContext; page: Page }>> {
  const configuration = readLocalConfiguration();
  let cookieJar: CookieToSet[] = [];
  const client = createServerClient(
    configuration.apiUrl,
    configuration.publishableKey,
    {
      cookies: {
        encode: "tokens-only",
        getAll: async () => cookieJar.map(({ name, value }) => ({ name, value })),
        setAll: async (cookies) => {
          const updates = new Map(cookies.map((cookie) => [cookie.name, cookie]));
          const writesAuthSession = cookies.some((cookie) => cookie.name.startsWith("sb-") && cookie.name.includes("auth-token"));
          cookieJar = [
            ...cookieJar.filter((cookie) => {
              const isAuthCookie = cookie.name.startsWith("sb-") && cookie.name.includes("auth-token");
              return !updates.has(cookie.name) && !(writesAuthSession && isAuthCookie);
            }),
            ...cookies,
          ];
        },
      },
    },
  );

  const { error } = await client.auth.signInWithPassword(credential);
  if (error) throw new Error("Local Supabase password sign-in failed.");

  const factors = await client.auth.mfa.listFactors();
  if (factors.error) throw new Error("Local Supabase MFA factor lookup failed.");
  const factor = (factors.data?.totp ?? []).find((candidate) => candidate.status === "verified");
  if (!factor) throw new Error("Local Supabase MFA fixture factor is missing.");
  const verification = await client.auth.mfa.challengeAndVerify({
    factorId: factor.id,
    code: generateTotpCode(credential.totpSecret),
  });
  if (verification.error) throw new Error("Local Supabase MFA challenge failed.");

  const browserCookies = cookieJar
    .filter((cookie) => cookie.value !== "")
    .map((cookie) => ({
      name: cookie.name,
      value: cookie.value,
      url: configuration.applicationOrigin,
      httpOnly: cookie.options?.httpOnly ?? true,
      secure: cookie.options?.secure ?? false,
      sameSite: playwrightSameSite(cookie.options?.sameSite),
    }));
  if (browserCookies.length === 0) {
    throw new Error("Local Supabase sign-in did not produce browser cookies.");
  }

  const context = await browser.newContext({ baseURL: configuration.applicationOrigin });
  await context.addCookies(browserCookies);
  const page = await context.newPage();
  return { context, page };
}

export async function authCookieFingerprint(page: Page): Promise<string> {
  const authCookies = (await page.context().cookies())
    .filter((cookie: Cookie) => cookie.name.startsWith("sb-") && cookie.name.includes("auth-token"))
    .sort((left, right) => left.name.localeCompare(right.name));
  if (authCookies.length === 0) throw new Error("Authenticated page has no Supabase auth cookie.");
  return createHash("sha256")
    .update(authCookies.map(({ name, value }) => `${name}=${value}`).join(";"))
    .digest("hex");
}

export async function expireAuthAccessToken(page: Page): Promise<void> {
  const authCookies = (await page.context().cookies())
    .filter((cookie: Cookie) => cookie.name.startsWith("sb-") && cookie.name.includes("auth-token"))
    .sort((left, right) => left.name.localeCompare(right.name));
  if (authCookies.length === 0) throw new Error("Authenticated page has no Supabase auth cookie.");

  const baseName = authCookies[0].name.replace(/[.]\d+$/u, "");
  if (!/^[A-Za-z0-9-]+$/u.test(baseName)) throw new Error("Authenticated cookie name is invalid.");
  const encoded = authCookies.map((cookie) => cookie.value).join("");
  if (!encoded.startsWith("base64-")) throw new Error("Authenticated cookie uses an unsupported encoding.");

  const session = JSON.parse(Buffer.from(encoded.slice("base64-".length), "base64url").toString("utf8")) as Record<string, unknown>;
  session.expires_at = Math.floor(Date.now() / 1000) - 1;
  const expiredValue = `base64-${Buffer.from(JSON.stringify(session), "utf8").toString("base64url")}`;
  const chunkSize = 3180;
  const values = Array.from({ length: Math.ceil(expiredValue.length / chunkSize) }, (_, index) => (
    expiredValue.slice(index * chunkSize, (index + 1) * chunkSize)
  ));
  const template = authCookies[0];

  await page.context().clearCookies({ name: new RegExp(`^${baseName}(?:[.]\\d+)?$`, "u") });
  await page.context().addCookies(values.map((value, index) => ({
    name: values.length === 1 ? baseName : `${baseName}.${index}`,
    value,
    domain: template.domain,
    path: template.path,
    httpOnly: template.httpOnly,
    secure: template.secure,
    sameSite: template.sameSite,
  })));
}

export const test = base.extend<LocalAuthFixtures>({
  authenticatedPage: async ({ browser }, provide) => {
    const contexts: BrowserContext[] = [];
    await provide(async (fixture) => {
      const configuration = readLocalConfiguration();
      const signedIn = await signInContext(browser, configuration.fixtures[fixture]);
      contexts.push(signedIn.context);
      return signedIn.page;
    });
    await Promise.all(contexts.map((context) => context.close()));
  },
  suspendedPage: async ({ browser }, provide) => {
    const configuration = readLocalConfiguration();
    const signedIn = await signInContext(browser, configuration.fixtures.suspended);
    try {
      await provide(signedIn.page);
    } finally {
      await signedIn.context.close();
    }
  },
});
