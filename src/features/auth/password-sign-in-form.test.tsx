import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { PasswordSignInForm } from "./password-sign-in-form";

describe("PasswordSignInForm", () => {
  it("submits credentials and navigates only after a successful sign-in", async () => {
    const onSignIn = vi.fn().mockResolvedValue({ status: "signed_in" });
    const navigate = vi.fn();
    render(<PasswordSignInForm configured navigate={navigate} onSignIn={onSignIn} />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني", { selector: "#password-email" }), {
      target: { value: "operator@voya.example" },
    });
    fireEvent.change(screen.getByLabelText("كلمة المرور"), { target: { value: "correct horse battery staple" } });
    fireEvent.click(screen.getByRole("button", { name: "دخول بالبريد وكلمة المرور" }));

    expect(onSignIn).toHaveBeenCalledWith("operator@voya.example", "correct horse battery staple");
    expect(await screen.findByText("جارٍ فتح مساحة العمل…")).toBeInTheDocument();
    expect(navigate).toHaveBeenCalledWith("/workspace");
  });

  it("shows safe invalid-credential feedback without navigating", async () => {
    const navigate = vi.fn();
    render(<PasswordSignInForm
      configured
      navigate={navigate}
      onSignIn={vi.fn().mockResolvedValue({ status: "invalid_credentials" })}
    />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني", { selector: "#password-email" }), {
      target: { value: "operator@voya.example" },
    });
    fireEvent.change(screen.getByLabelText("كلمة المرور"), { target: { value: "incorrect password" } });
    fireEvent.click(screen.getByRole("button", { name: "دخول بالبريد وكلمة المرور" }));

    expect(await screen.findByText("البريد الإلكتروني أو كلمة المرور غير صحيحة.")).toBeInTheDocument();
    expect(navigate).not.toHaveBeenCalled();
  });

  it("shows neutral feedback and does not navigate while access is pending", async () => {
    const navigate = vi.fn();
    render(<PasswordSignInForm
      configured
      navigate={navigate}
      onSignIn={vi.fn().mockResolvedValue({ status: "access_pending" })}
    />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني", { selector: "#password-email" }), {
      target: { value: "suspended@voya.example" },
    });
    fireEvent.change(screen.getByLabelText("كلمة المرور"), { target: { value: "correct horse battery staple" } });
    fireEvent.click(screen.getByRole("button", { name: "دخول بالبريد وكلمة المرور" }));

    expect(await screen.findByText("الوصول إلى مساحة العمل قيد المراجعة. تواصل مع مسؤول مؤسستك.")).toBeInTheDocument();
    expect(navigate).not.toHaveBeenCalled();
  });

  it("shows retry feedback and restores the form when the sign-in action rejects", async () => {
    render(<PasswordSignInForm
      configured
      onSignIn={vi.fn().mockRejectedValue(new Error("network unavailable"))}
    />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني", { selector: "#password-email" }), {
      target: { value: "operator@voya.example" },
    });
    fireEvent.change(screen.getByLabelText("كلمة المرور"), { target: { value: "correct horse battery staple" } });
    fireEvent.click(screen.getByRole("button", { name: "دخول بالبريد وكلمة المرور" }));

    expect(await screen.findByText("تعذّر تسجيل الدخول الآن. حاول مرة أخرى بعد قليل.")).toBeInTheDocument();
    await waitFor(() => expect(screen.getByRole("button", { name: "دخول بالبريد وكلمة المرور" })).toBeEnabled());
  });
});
