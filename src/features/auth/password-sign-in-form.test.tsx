import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { PasswordSignInForm } from "./password-sign-in-form";

describe("PasswordSignInForm", () => {
  it("submits email and password and navigates only after success", async () => {
    let settle: ((result: { status: "signed_in" }) => void) | undefined;
    const onSignIn = vi.fn().mockImplementation(() => new Promise((resolve) => { settle = resolve; }));
    const navigate = vi.fn();
    render(<PasswordSignInForm configured onSignIn={onSignIn} navigate={navigate} />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني"), { target: { value: "operator@voya.example" } });
    fireEvent.change(screen.getByLabelText("كلمة المرور"), { target: { value: "secret-password" } });
    const submitButton = screen.getByRole("button", { name: "دخول بالبريد وكلمة المرور" });
    const form = submitButton.closest("form");
    expect(form).not.toBeNull();
    fireEvent.submit(form!);
    fireEvent.submit(form!);

    expect(onSignIn).toHaveBeenCalledWith("operator@voya.example", "secret-password");
    expect(onSignIn).toHaveBeenCalledTimes(1);
    expect(await screen.findByText("جارٍ فتح مساحة العمل…")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "دخول بالبريد وكلمة المرور" })).toBeDisabled();
    settle?.({ status: "signed_in" });
    await screen.findByRole("button", { name: "دخول بالبريد وكلمة المرور" });
    expect(navigate).toHaveBeenCalledWith("/workspace");
  });

  it("shows generic invalid-credential feedback and does not navigate", async () => {
    const navigate = vi.fn();
    render(<PasswordSignInForm configured onSignIn={vi.fn().mockResolvedValue({ status: "invalid_credentials" })} navigate={navigate} />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني"), { target: { value: "operator@voya.example" } });
    fireEvent.change(screen.getByLabelText("كلمة المرور"), { target: { value: "wrong" } });
    fireEvent.click(screen.getByRole("button", { name: "دخول بالبريد وكلمة المرور" }));

    expect(await screen.findByText("البريد الإلكتروني أو كلمة المرور غير صحيحة.")).toBeInTheDocument();
    expect(navigate).not.toHaveBeenCalled();
  });

  it("recovers from a rejected action transport and allows a successful retry", async () => {
    const onSignIn = vi.fn()
      .mockRejectedValueOnce(new Error("Failed to find Server Action"))
      .mockResolvedValueOnce({ status: "signed_in" });
    const navigate = vi.fn();
    render(<PasswordSignInForm configured onSignIn={onSignIn} navigate={navigate} />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني"), { target: { value: "operator@voya.example" } });
    fireEvent.change(screen.getByLabelText("كلمة المرور"), { target: { value: "secret-password" } });
    fireEvent.click(screen.getByRole("button", { name: "دخول بالبريد وكلمة المرور" }));

    expect(await screen.findByText("تعذّر تسجيل الدخول الآن. حاول مرة أخرى بعد قليل.")).toBeInTheDocument();
    const retryButton = screen.getByRole("button", { name: "دخول بالبريد وكلمة المرور" });
    expect(retryButton).toBeEnabled();

    fireEvent.click(retryButton);

    await waitFor(() => expect(navigate).toHaveBeenCalledWith("/workspace"));
    expect(onSignIn).toHaveBeenCalledTimes(2);
  });

  it("requires configuration and keeps the password masked", () => {
    render(<PasswordSignInForm configured={false} onSignIn={vi.fn()} navigate={vi.fn()} />);

    expect(screen.getByText("الدخول غير مهيأ في هذه البيئة بعد.")).toBeInTheDocument();
    expect(screen.getByLabelText("كلمة المرور")).toHaveAttribute("type", "password");
    expect(screen.getByRole("button", { name: "دخول بالبريد وكلمة المرور" })).toBeDisabled();
  });
});
