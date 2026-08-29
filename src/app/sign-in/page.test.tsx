import { render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("@/lib/supabase/public-config", () => ({
  readSupabasePublicConfig: vi.fn(() => ({ url: "https://project.supabase.co", publishableKey: "publishable-key" })),
}));
vi.mock("next/navigation", () => ({ useRouter: () => ({ replace: vi.fn() }) }));

import SignInPage from "./page";

afterEach(() => vi.unstubAllEnvs());

describe("/sign-in", () => {
  it("offers password signup and Google while removing magic-link login", () => {
    vi.stubEnv("VOYA_APP_URL", "https://app.voya.example");
    render(<SignInPage />);

    expect(screen.getByRole("heading", { name: "إنشاء مؤسسة جديدة" })).toBeInTheDocument();
    expect(screen.getByText("لو لديك حساب بالفعل، استخدم نموذج الدخول بالأعلى. إيقاف السيرفر أو تسجيل الخروج لا يحذف حسابك.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "إنشاء حساب بالبريد" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "متابعة باستخدام Google" })).toBeInTheDocument();
    expect(screen.queryByText("الدخول برابط آمن")).not.toBeInTheDocument();
  });
});
