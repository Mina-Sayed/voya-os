import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { renderToString } from "react-dom/server";
import { describe, expect, it, vi } from "vitest";
import { MfaChallenge, type MfaChallengeClient } from "./mfa-challenge";

const primaryFactor = {
  id: "factor-primary",
  friendly_name: "تطبيق الفريق",
  factor_type: "totp" as const,
  status: "verified" as const,
  created_at: "2026-08-01T10:00:00.000Z",
  updated_at: "2026-08-01T10:00:00.000Z",
};

const backupFactor = {
  ...primaryFactor,
  id: "factor-backup",
  friendly_name: "الهاتف الاحتياطي",
};

const pendingFactor = {
  ...primaryFactor,
  id: "factor-pending",
  friendly_name: "وسيلة غير مكتملة",
  status: "unverified" as const,
};

const phoneFactor = {
  ...primaryFactor,
  id: "factor-phone",
  friendly_name: "رسالة نصية",
  factor_type: "phone" as const,
};

function challengeClient({
  challengeResults = [{ data: { id: "challenge-a", type: "totp", expires_at: 1_800_000_000 }, error: null }],
  verifyResults = [{ data: {}, error: null }],
}: {
  challengeResults?: Array<{ data: unknown; error: unknown }>;
  verifyResults?: Array<{ data: unknown; error: unknown }>;
} = {}) {
  const challenge = vi.fn();
  for (const result of challengeResults) challenge.mockResolvedValueOnce(result);
  const verify = vi.fn();
  for (const result of verifyResults) verify.mockResolvedValueOnce(result);

  const client: MfaChallengeClient = {
    auth: {
      mfa: {
        listFactors: vi.fn().mockResolvedValue({
          data: {
            all: [primaryFactor, backupFactor, pendingFactor, phoneFactor],
            totp: [primaryFactor, backupFactor, pendingFactor],
            phone: [phoneFactor],
            webauthn: [],
          },
          error: null,
        }),
        challenge,
        verify,
      },
    },
  };
  return { challenge, client, verify };
}

describe("MfaChallenge", () => {
  it("does not create a browser client during server rendering", () => {
    const html = renderToString(<MfaChallenge />);

    expect(html).toContain("جارٍ تحميل وسائل التحقق…");
  });

  it("lists verified TOTP factors, challenges the selected factor, verifies six digits, and opens workspace", async () => {
    const { challenge, client, verify } = challengeClient();
    const navigate = vi.fn();
    render(<MfaChallenge client={client} navigate={navigate} />);

    const factorSelect = await screen.findByRole("combobox", { name: "وسيلة التحقق" });
    expect(factorSelect).toHaveTextContent("تطبيق الفريق");
    expect(factorSelect).toHaveTextContent("الهاتف الاحتياطي");
    expect(factorSelect).not.toHaveTextContent("وسيلة غير مكتملة");
    expect(factorSelect).not.toHaveTextContent("رسالة نصية");
    fireEvent.change(factorSelect, { target: { value: backupFactor.id } });
    fireEvent.change(screen.getByRole("textbox", { name: "رمز التحقق المكوّن من 6 أرقام" }), {
      target: { value: "123456" },
    });
    fireEvent.click(screen.getByRole("button", { name: "تحقق وافتح مساحة العمل" }));

    await waitFor(() => expect(challenge).toHaveBeenCalledWith({ factorId: backupFactor.id }));
    expect(verify).toHaveBeenCalledWith({
      factorId: backupFactor.id,
      challengeId: "challenge-a",
      code: "123456",
    });
    expect(navigate).toHaveBeenCalledWith("/workspace");
  });

  it("shows safe retry feedback and restores the form after a challenge error", async () => {
    const { challenge, client, verify } = challengeClient({
      challengeResults: [
        { data: null, error: new Error("provider detail") },
        { data: { id: "challenge-b", type: "totp", expires_at: 1_800_000_000 }, error: null },
      ],
    });
    render(<MfaChallenge client={client} navigate={vi.fn()} />);

    const codeInput = await screen.findByRole("textbox", { name: "رمز التحقق المكوّن من 6 أرقام" });
    fireEvent.change(codeInput, { target: { value: "654321" } });
    fireEvent.click(screen.getByRole("button", { name: "تحقق وافتح مساحة العمل" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("تعذّر التحقق من الرمز. حاول مرة أخرى.");
    const submit = screen.getByRole("button", { name: "تحقق وافتح مساحة العمل" });
    expect(submit).toBeEnabled();
    fireEvent.click(submit);

    await waitFor(() => expect(challenge).toHaveBeenCalledTimes(2));
    expect(verify).toHaveBeenCalledWith({
      factorId: primaryFactor.id,
      challengeId: "challenge-b",
      code: "654321",
    });
  });

  it("starts a fresh challenge and remains retryable after a verification error", async () => {
    const { challenge, client, verify } = challengeClient({
      challengeResults: [
        { data: { id: "challenge-a", type: "totp", expires_at: 1_800_000_000 }, error: null },
        { data: { id: "challenge-b", type: "totp", expires_at: 1_800_000_000 }, error: null },
      ],
      verifyResults: [
        { data: null, error: new Error("provider detail") },
        { data: {}, error: null },
      ],
    });
    render(<MfaChallenge client={client} navigate={vi.fn()} />);

    const codeInput = await screen.findByRole("textbox", { name: "رمز التحقق المكوّن من 6 أرقام" });
    fireEvent.change(codeInput, { target: { value: "246810" } });
    fireEvent.click(screen.getByRole("button", { name: "تحقق وافتح مساحة العمل" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("تعذّر التحقق من الرمز. حاول مرة أخرى.");
    const submit = screen.getByRole("button", { name: "تحقق وافتح مساحة العمل" });
    expect(submit).toBeEnabled();
    fireEvent.click(submit);

    await waitFor(() => expect(challenge).toHaveBeenCalledTimes(2));
    expect(verify).toHaveBeenLastCalledWith({
      factorId: primaryFactor.id,
      challengeId: "challenge-b",
      code: "246810",
    });
  });
});
