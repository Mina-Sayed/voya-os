import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import SignInPage from "@/app/sign-in/page";
import { SignInForm } from "./sign-in-form";

afterEach(() => {
  vi.unstubAllEnvs();
});

describe("SignInForm", () => {
  it("presents Arabic email sign-in controls and sends the email", async () => {
    const onRequestSignIn = vi.fn().mockResolvedValue({ status: "sent" });
    render(<SignInForm configured onRequestSignIn={onRequestSignIn} />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني"), { target: { value: "operator@voya.example" } });
    fireEvent.click(screen.getByRole("button", { name: "أرسل رابط الدخول" }));

    expect(onRequestSignIn).toHaveBeenCalledWith("operator@voya.example");
    expect(await screen.findByText("أرسلنا رابطًا آمنًا إلى بريدك الإلكتروني.")) .toBeInTheDocument();
  });

  it("explains and disables sign-in when Supabase is not configured", () => {
    render(<SignInForm configured={false} onRequestSignIn={vi.fn()} />);

    expect(screen.getByText("الدخول غير مهيأ في هذه البيئة بعد.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "أرسل رابط الدخول" })).toBeDisabled();
  });

  it("keeps both sign-in methods unavailable without the server limiter secret", async () => {
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.supabase.co");
    vi.stubEnv("NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY", "publishable-key");
    vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");
    vi.stubEnv("SUPABASE_SERVICE_ROLE_KEY", "");

    render(await SignInPage({}));

    expect(screen.getByRole("button", { name: "دخول بالبريد وكلمة المرور" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "أرسل رابط الدخول" })).toBeDisabled();
  });

  it("applies a visible cooldown after a rate-limited request", async () => {
    render(<SignInForm configured onRequestSignIn={vi.fn().mockResolvedValue({ status: "rate_limited" })} />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني"), { target: { value: "operator@voya.example" } });
    fireEvent.click(screen.getByRole("button", { name: "أرسل رابط الدخول" }));

    expect(await screen.findByText("تم طلب روابط كثيرة. انتظر 15 دقيقة ثم استخدم أحدث رابط فقط.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "حاول بعد 900 ثانية" })).toBeDisabled();
  });

  it("shows retry feedback and restores the form when the request action rejects", async () => {
    render(<SignInForm
      configured
      onRequestSignIn={vi.fn().mockRejectedValue(new Error("network unavailable"))}
    />);

    fireEvent.change(screen.getByLabelText("البريد الإلكتروني"), { target: { value: "operator@voya.example" } });
    fireEvent.click(screen.getByRole("button", { name: "أرسل رابط الدخول" }));

    expect(await screen.findByText("تعذّر إرسال الرابط الآن. حاول مرة أخرى بعد قليل.")).toBeInTheDocument();
    await waitFor(() => expect(screen.getByRole("button", { name: "أرسل رابط الدخول" })).toBeEnabled());
  });
});
