import type { Metadata } from "next";
import localFont from "next/font/local";
import "./globals.css";

// The proxy issues a per-request nonce CSP. Next.js can only attach that nonce
// to framework scripts during dynamic rendering, so the root layout opts the
// entire application out of build-time HTML.
export const dynamic = "force-dynamic";

const notoKufiArabic = localFont({
  src: "./fonts/NotoKufiArabic-Variable.woff2",
  variable: "--font-noto-kufi-arabic",
  weight: "100 900",
  style: "normal",
  display: "swap",
});

const geistMono = localFont({
  src: "./fonts/GeistMono-Variable.woff2",
  variable: "--font-geist-mono",
  weight: "100 900",
  style: "normal",
  display: "swap",
});

export const metadata: Metadata = {
  title: "فُويا | عمليات الإقامات المفروشة",
  description: "نظام تشغيل عربي لإدارة الإقامات المفروشة.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html
      lang="ar"
      dir="rtl"
      className={`${notoKufiArabic.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full flex flex-col">{children}</body>
    </html>
  );
}
