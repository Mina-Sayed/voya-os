import { describe, expect, it } from "vitest";
import { canonicalHostRedirectUrl } from "./canonical-host";

const canonicalOrigin = "https://www.vigor.dpdns.org";

function redirectFor(overrides: Partial<Parameters<typeof canonicalHostRedirectUrl>[0]> = {}) {
  return canonicalHostRedirectUrl({
    pathname: "/sign-in",
    search: "",
    host: "voya-os.vercel.app",
    isProduction: true,
    applicationOrigin: canonicalOrigin,
    deploymentAlias: "voya-os.vercel.app",
    ...overrides,
  });
}

describe("canonicalHostRedirectUrl", () => {
  it("redirects the retired production alias to the canonical origin", () => {
    expect(redirectFor()?.href).toBe("https://www.vigor.dpdns.org/sign-in");
  });

  it("preserves the path and query string", () => {
    const target = redirectFor({ pathname: "/auth/callback", search: "?code=abc&next=%2Fworkspace" });
    expect(target?.href).toBe("https://www.vigor.dpdns.org/auth/callback?code=abc&next=%2Fworkspace");
  });

  it("redirects the Vercel deployment alias reported by the platform", () => {
    const target = redirectFor({ host: "voya-os-git-main-minas-projects.vercel.app", deploymentAlias: "voya-os-git-main-minas-projects.vercel.app" });
    expect(target?.href).toBe("https://www.vigor.dpdns.org/sign-in");
  });

  it("leaves the canonical host untouched", () => {
    expect(redirectFor({ host: "www.vigor.dpdns.org" })).toBeNull();
  });

  it("leaves a Cloudflare-rewritten origin host untouched", () => {
    expect(redirectFor({ host: "voya-os-minas-projects-ed065580.vercel.app" })).toBeNull();
  });

  it("leaves preview and unrelated hosts untouched", () => {
    for (const host of ["voya-mwrjozbu8-minas-projects.vercel.app", "evil.example", "voya-os.vercel.app.evil.example"]) {
      expect(redirectFor({ host })).toBeNull();
    }
  });

  it("never redirects API traffic", () => {
    for (const pathname of ["/api", "/api/health", "/api/webhooks/whatsapp/openwa"]) {
      expect(redirectFor({ pathname })).toBeNull();
    }
  });

  it("does nothing outside production", () => {
    expect(redirectFor({ isProduction: false })).toBeNull();
  });

  it("does nothing without a usable https application origin", () => {
    for (const applicationOrigin of [null, "", "not-a-url", "http://www.vigor.dpdns.org", "https://www.vigor.dpdns.org/path", "https://www.vigor.dpdns.org?x=1"]) {
      expect(redirectFor({ applicationOrigin })).toBeNull();
    }
  });

  it("does nothing without a host", () => {
    expect(redirectFor({ host: null })).toBeNull();
    expect(redirectFor({ host: "   " })).toBeNull();
  });

  it("normalizes case, port, trailing dot, and forwarded-host lists", () => {
    for (const host of ["VOYA-OS.VERCEL.APP", "voya-os.vercel.app:443", "voya-os.vercel.app.", "voya-os.vercel.app, proxy.internal"]) {
      expect(redirectFor({ host })?.host).toBe("www.vigor.dpdns.org");
    }
  });

  it("cannot loop when the deployment alias is the canonical host", () => {
    expect(redirectFor({ host: "voya-os.vercel.app", deploymentAlias: "www.vigor.dpdns.org" })?.host).toBe("www.vigor.dpdns.org");
    expect(redirectFor({ host: "www.vigor.dpdns.org", deploymentAlias: "www.vigor.dpdns.org" })).toBeNull();
  });

  it("rejects a pathname that is not absolute", () => {
    expect(redirectFor({ pathname: "sign-in" })).toBeNull();
    expect(redirectFor({ pathname: "" })).toBeNull();
  });

  it("rejects a malformed search string", () => {
    expect(redirectFor({ search: "code=abc" })).toBeNull();
  });
});
