import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { PasswordSignInForm } from "./password-sign-in-form";

const REMEMBERED_EMAIL_KEY = "voya.auth.remembered-email.v1";
const REMEMBER_EMAIL_PREFERENCE_KEY = "voya.auth.remember-email.v1";

afterEach(() => {
  window.localStorage.clear();
});

describe("PasswordSignInForm", () => {
  it("submits email and password and navigates only after success", async () => {
    let settle: ((result: { status: "signed_in" }) => void) | undefined;
    const onSignIn = vi.fn().mockImplementation(() => new Promise((resolve) => { settle = resolve; }));
    const navigate = vi.fn();
    render(<PasswordSignInForm configured onSignIn={onSignIn} navigate={navigate} />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني"), { target: { value: "operator@voya.example" } });
    fireEvent.change(screen.getByLabelText("كلمة المرور"), { target: { value: "secret-password" } });
    expect(screen.getByLabelText("البريد الإلكتروني")).toHaveAttribute("name", "email");
    expect(screen.getByLabelText("كلمة المرور")).toHaveAttribute("name", "password");
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

  it("restores only the remembered email after sign-out without persisting the password", async () => {
    window.localStorage.setItem(REMEMBER_EMAIL_PREFERENCE_KEY, "1");
    window.localStorage.setItem(REMEMBERED_EMAIL_KEY, "operator@voya.example");
    const navigate = vi.fn();
    render(<PasswordSignInForm configured onSignIn={vi.fn().mockResolvedValue({ status: "signed_in" })} navigate={navigate} />);

    await waitFor(() => expect(screen.getByLabelText("البريد الإلكتروني")).toHaveValue("operator@voya.example"));
    expect(screen.getByLabelText("كلمة المرور")).toHaveValue("");

    fireEvent.change(screen.getByLabelText("كلمة المرور"), { target: { value: "secret-password" } });
    fireEvent.click(screen.getByRole("button", { name: "دخول بالبريد وكلمة المرور" }));

    await waitFor(() => expect(navigate).toHaveBeenCalledWith("/workspace"));
    expect(window.localStorage.getItem(REMEMBERED_EMAIL_KEY)).toBe("operator@voya.example");
    expect(window.localStorage.getItem("voya.auth.password")).toBeNull();
  });

  it("lets the user clear the remembered email", async () => {
    window.localStorage.setItem(REMEMBER_EMAIL_PREFERENCE_KEY, "1");
    window.localStorage.setItem(REMEMBERED_EMAIL_KEY, "operator@voya.example");
    render(<PasswordSignInForm configured onSignIn={vi.fn()} navigate={vi.fn()} />);

    await waitFor(() => expect(screen.getByLabelText("البريد الإلكتروني")).toHaveValue("operator@voya.example"));
    fireEvent.click(screen.getByRole("checkbox", { name: "تذكر البريد الإلكتروني على هذا الجهاز" }));

    expect(window.localStorage.getItem(REMEMBER_EMAIL_PREFERENCE_KEY)).toBe("0");
    expect(window.localStorage.getItem(REMEMBERED_EMAIL_KEY)).toBeNull();
  });
});
