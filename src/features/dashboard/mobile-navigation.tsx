"use client";

import { Menu, X } from "lucide-react";
import Link from "next/link";
import { useEffect, useState } from "react";
import type { DashboardNavigationItem } from "./operations-dashboard";

export function MobileNavigation({
  items,
}: Readonly<{ items: readonly DashboardNavigationItem[] }>) {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    if (!open) {
      return;
    }

    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setOpen(false);
      }
    };

    window.addEventListener("keydown", closeOnEscape);
    return () => window.removeEventListener("keydown", closeOnEscape);
  }, [open]);

  return (
    <div className="lg:hidden">
      <button
        aria-controls="mobile-navigation"
        aria-expanded={open}
        aria-label="فتح التنقل"
        className="grid size-9 place-items-center rounded-xl border border-line text-harbor"
        onClick={() => setOpen(true)}
        type="button"
      >
        <Menu aria-hidden="true" className="size-5" />
      </button>

      {open ? (
        <div
          aria-label="قائمة التنقل على الهاتف"
          aria-modal="false"
          className="fixed inset-x-3 top-3 z-50 max-h-[calc(100vh-1.5rem)] overflow-y-auto rounded-2xl border border-line bg-surface p-3 shadow-[0_16px_36px_rgba(17,43,50,0.16)]"
          role="dialog"
        >
          <div className="mb-2 flex items-center justify-between gap-3 px-2">
            <p className="text-sm font-bold text-harbor">التنقل</p>
            <button
              aria-label="إغلاق التنقل"
              className="grid size-9 place-items-center rounded-xl text-muted hover:bg-canvas"
              onClick={() => setOpen(false)}
              type="button"
            >
              <X aria-hidden="true" className="size-5" />
            </button>
          </div>
          <nav aria-label="التنقل على الهاتف" className="space-y-1" id="mobile-navigation">
            {items.map((item) => item.href ? (
              <Link
                className="flex rounded-xl px-3 py-3 text-sm font-semibold text-harbor hover:bg-canvas"
                href={item.href}
                key={item.label}
                onClick={() => setOpen(false)}
              >
                {item.label}
              </Link>
            ) : (
              <span
                aria-disabled="true"
                className="flex cursor-not-allowed items-center justify-between rounded-xl px-3 py-3 text-sm font-semibold text-muted opacity-55"
                key={item.label}
                title={item.disabledReason ?? "قريبًا"}
              >
                <span>{item.label}</span>
                <span className="text-[10px]">{item.disabledReason ?? "قريبًا"}</span>
              </span>
            ))}
          </nav>
        </div>
      ) : null}
    </div>
  );
}
