import type { Metadata } from "next";
import { Geist_Mono, Noto_Kufi_Arabic } from "next/font/google";
import "./globals.css";

const notoKufiArabic = Noto_Kufi_Arabic({
  variable: "--font-noto-kufi-arabic",
  subsets: ["arabic", "latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
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
