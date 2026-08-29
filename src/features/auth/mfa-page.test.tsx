import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { MfaPage } from "./mfa-page";

const navigation = vi.hoisted(() => ({ replace: vi.fn() }));
const actions = vi.hoisted(() => ({ verify: vi.fn(), begin: vi.fn() }));

vi.mock("next/navigation", () => ({ useRouter: () => ({ replace: navigation.replace }) }));
vi.mock("@/app/security/mfa/actions", () => ({
  beginMfaEnrollmentAction: actions.begin,
  verifyMfaAction: actions.verify,
}));

afterEach(() => {
  navigation.replace.mockReset();
  actions.verify.mockReset();
  actions.begin.mockReset();
});

describe("MfaPage", () => {
  it("uses client-side navigation after a successful challenge", async () => {
    actions.verify.mockResolvedValue({ status: "success", message: "تم التحقق." });
    render(<MfaPage reason="challenge" verifiedFactorId="factor-123456" />);

    fireEvent.change(screen.getByLabelText("رمز تطبيق المصادقة"), { target: { value: "123456" } });
    fireEvent.click(screen.getByRole("button", { name: "تحقق وادخل مساحة العمل" }));

    await waitFor(() => expect(navigation.replace).toHaveBeenCalledWith("/workspace"));
  });
});
