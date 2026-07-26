import Link from "next/link";

export default function NotFound() {
  return (
    <main className="grid min-h-screen place-items-center bg-canvas p-6 text-center text-ink">
      <div className="max-w-md rounded-[1.6rem] border border-line bg-surface p-8 shadow-[0_16px_36px_rgba(17,43,50,0.08)]">
        <p className="text-sm font-semibold text-tide">404</p>
        <h1 className="mt-3 text-2xl font-bold tracking-[-0.07em] text-harbor">الصفحة غير موجودة</h1>
        <p className="mt-3 text-sm leading-7 text-muted">قد يكون الرابط غير صحيح أو أن الصفحة لم تعد متاحة.</p>
        <Link className="mt-6 inline-flex rounded-xl bg-harbor px-4 py-3 text-sm font-bold text-white" href="/">
          العودة إلى لوحة العمليات
        </Link>
      </div>
    </main>
  );
}
