import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { PasswordSignUpForm } from "./password-sign-up-form";

const navigation = vi.hoisted(() => ({ replace: vi.fn() }));
vi.mock("next/navigation", () => ({ useRouter: () => ({ replace: navigation.replace }) }));

function fillForm(password = "safe-password", confirmation = password) {
  fireEvent.change(screen.getByLabelText("البريد الإلكتروني"), { target: { value: "operator@example.com" } });
  fireEvent.change(screen.getByLabelText("كلمة مرور فُويا"), { target: { value: password } });
  fireEvent.change(screen.getByLabelText("تأكيد كلمة المرور"), { target: { value: confirmation } });
}

describe("PasswordSignUpForm", () => {
  it("keeps signup unavailable when configuration is missing", () => {
    render(<PasswordSignUpForm configured={false} onSignUp={vi.fn()} />);

    expect(screen.getByRole("button", { name: "إنشاء حساب بالبريد" })).toBeDisabled();
    expect(screen.getByText("التسجيل غير مهيأ في هذه البيئة بعد.")).toBeInTheDocument();
  });

  it("rejects mismatched passwords before calling the server action", () => {
    const onSignUp = vi.fn();
    render(<PasswordSignUpForm configured onSignUp={onSignUp} />);
    fillForm("safe-password", "different-password");

    fireEvent.submit(screen.getByRole("button", { name: "إنشاء حساب بالبريد" }).closest("form")!);

    expect(screen.getByText("كلمتا المرور غير متطابقتين.")).toBeInTheDocument();
    expect(onSignUp).not.toHaveBeenCalled();
  });

  it("shows the confirmation-required state returned by the action", async () => {
    const onSignUp = vi.fn().mockResolvedValue({ status: "created" });
    render(<PasswordSignUpForm configured onSignUp={onSignUp} />);
    fillForm();

    fireEvent.submit(screen.getByRole("button", { name: "إنشاء حساب بالبريد" }).closest("form")!);

    await screen.findByText("تم إنشاء الحساب. افتح رسالة التأكيد، وبعدها أكمل إعداد المؤسسة.");
    expect(onSignUp).toHaveBeenCalledWith("operator@example.com", "safe-password");
  });

  it("navigates to onboarding when the action returns an active session", async () => {
    const navigate = vi.fn();
    const onSignUp = vi.fn().mockResolvedValue({ status: "signed_in" });
    render(<PasswordSignUpForm configured onSignUp={onSignUp} navigate={navigate} />);
    fillForm();

    fireEvent.submit(screen.getByRole("button", { name: "إنشاء حساب بالبريد" }).closest("form")!);

    await waitFor(() => expect(navigate).toHaveBeenCalledWith("/onboarding"));
    expect(screen.queryByText("تعذّر إنشاء الحساب الآن. حاول مرة أخرى بعد قليل.")).not.toBeInTheDocument();
  });

  it("uses client-side navigation when no navigation override is provided", async () => {
    const onSignUp = vi.fn().mockResolvedValue({ status: "signed_in" });
    render(<PasswordSignUpForm configured onSignUp={onSignUp} />);
    fillForm();

    fireEvent.submit(screen.getByRole("button", { name: "إنشاء حساب بالبريد" }).closest("form")!);

    await waitFor(() => expect(navigation.replace).toHaveBeenCalledWith("/onboarding"));
  });

  it("maps action exceptions to a retry state", async () => {
    const onSignUp = vi.fn().mockRejectedValue(new Error("temporary failure"));
    render(<PasswordSignUpForm configured onSignUp={onSignUp} />);
    fillForm();

    fireEvent.submit(screen.getByRole("button", { name: "إنشاء حساب بالبريد" }).closest("form")!);

    await screen.findByText("تعذّر إنشاء الحساب الآن. حاول مرة أخرى بعد قليل.");
  });
});
