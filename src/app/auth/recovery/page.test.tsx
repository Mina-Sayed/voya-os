import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import RecoveryPage from "./page";

const navigation = vi.hoisted(() => ({ replace: vi.fn() }));
const actions = vi.hoisted(() => ({ updatePassword: vi.fn() }));

vi.mock("next/navigation", () => ({ useRouter: () => ({ replace: navigation.replace }) }));
vi.mock("./actions", () => ({ updatePasswordAction: actions.updatePassword }));

afterEach(() => {
  navigation.replace.mockReset();
  actions.updatePassword.mockReset();
});

describe("RecoveryPage", () => {
  it("uses client-side navigation after updating the password", async () => {
    actions.updatePassword.mockResolvedValue({ status: "success", message: "تم التحديث." });
    render(<RecoveryPage />);

    fireEvent.change(screen.getByLabelText("كلمة المرور الجديدة"), { target: { value: "long-enough-password" } });
    fireEvent.change(screen.getByLabelText("تأكيد كلمة المرور"), { target: { value: "long-enough-password" } });
    fireEvent.click(screen.getByRole("button", { name: "حفظ كلمة المرور" }));

    await waitFor(() => expect(navigation.replace).toHaveBeenCalledWith("/workspace"), { timeout: 2_000 });
  });
});
