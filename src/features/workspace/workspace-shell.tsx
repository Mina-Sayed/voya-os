import {
  Activity,
  Bell,
  Building2,
  CarFront,
  CalendarDays,
  CircleUserRound,
  ClipboardCheck,
  Home,
  KeyRound,
  LayoutDashboard,
  ListTodo,
  MessageCircle,
  RadioTower,
  Sparkles,
  UsersRound,
  Wrench,
} from "lucide-react";
import Link from "next/link";
import { MobileNavigation } from "@/features/dashboard/mobile-navigation";
import { signOutAction } from "@/features/auth/sign-out-action";

type WorkspaceShellProps = Readonly<{
  activeHref: string;
  organizationName: string;
  role: string;
  children: React.ReactNode;
}>;

type ShellNavigationItem = Readonly<{
  href?: string;
  label: string;
  icon: typeof LayoutDashboard;
  allowedRoles?: readonly string[];
  section?: "workspace" | "extensions";
  disabledReason?: string;
}>;

export const workspaceNavigationItems: readonly ShellNavigationItem[] = [
  { href: "/workspace", label: "نظرة عامة", icon: LayoutDashboard },
  { href: "/workspace/leads", label: "العملاء المحتملون", icon: RadioTower, allowedRoles: ["owner", "manager", "sales_agent"] },
  { href: "/workspace/clients", label: "العملاء", icon: UsersRound },
  { href: "/workspace/bookings", label: "الإقامات", icon: CalendarDays, allowedRoles: ["owner", "manager", "sales_agent", "operations"] },
  { href: "/workspace/tasks", label: "مهام التشغيل", icon: ListTodo, allowedRoles: ["owner", "manager", "operations"] },
  { href: "/workspace/transport", label: "السيارات والتحويلات", icon: CarFront, allowedRoles: ["owner", "manager", "sales_agent", "operations"] },
  { href: "/workspace/availability", label: "التوفر", icon: Wrench },
  { href: "/workspace/properties", label: "العقارات", icon: Building2 },
  { href: "/workspace/property-owners", label: "ملاك العقارات", icon: Home },
  { href: "/workspace/approvals", label: "الموافقات", icon: ClipboardCheck, allowedRoles: ["owner", "manager", "sales_agent", "operations", "accountant"] },
  { href: "/workspace/activity", label: "سجل النشاط", icon: Activity, allowedRoles: ["owner", "manager", "sales_agent", "operations", "accountant"] },
  { href: "/workspace/notifications", label: "الإشعارات", icon: Bell },
  { href: "/workspace/ai", label: "مركز الذكاء", icon: Sparkles, section: "extensions", allowedRoles: ["owner", "manager", "sales_agent", "operations", "accountant"] },
  { href: "/workspace/whatsapp", label: "صندوق واتساب", icon: MessageCircle, section: "extensions", allowedRoles: ["owner", "manager", "sales_agent", "operations"] },
];

const roleCopy: Record<string, string> = {
  owner: "مالك المؤسسة",
  manager: "مدير",
  sales_agent: "مبيعات",
  operations: "تشغيل",
  accountant: "محاسبة",
  viewer: "مشاهد",
};

function NavigationLink({ item, activeHref }: Readonly<{ item: ShellNavigationItem; activeHref: string }>) {
  const Icon = item.icon;
  const active = item.href === activeHref;
  const className = `group flex min-h-11 items-center gap-3 rounded-xl px-3 text-[13px] font-semibold transition-colors ${
    active ? "bg-[#d5e9df] text-[#153f36]" : "text-[#c6d4cd] hover:bg-white/10 hover:text-white"
  }`;

  if (!item.href) {
    return (
      <span aria-disabled="true" className={`${className} cursor-not-allowed opacity-55`} title={item.disabledReason}>
        <Icon aria-hidden="true" className="size-[17px] shrink-0" strokeWidth={1.8} />
        <span>{item.label}</span>
        <span className="mr-auto text-[10px] font-medium">{item.disabledReason}</span>
      </span>
    );
  }

  return (
    <Link aria-current={active ? "page" : undefined} className={className} href={item.href}>
      <Icon aria-hidden="true" className="size-[17px] shrink-0" strokeWidth={1.8} />
      <span>{item.label}</span>
      {active ? <span aria-hidden="true" className="mr-auto size-1.5 rounded-full bg-[#b88a3a]" /> : null}
    </Link>
  );
}

export function WorkspaceShell({ activeHref, organizationName, role, children }: WorkspaceShellProps) {
  const visibleNavigationItems = workspaceNavigationItems.filter((item) => !item.allowedRoles || item.allowedRoles.includes(role));
  const workspaceItems = visibleNavigationItems.filter((item) => item.section !== "extensions");
  const extensionItems = visibleNavigationItems.filter((item) => item.section === "extensions");
  const mobileItems = visibleNavigationItems.filter((item) => item.href || item.label === "مركز الذكاء").map((item) => ({
    href: item.href,
    label: item.label,
    disabledReason: item.disabledReason,
  }));

  return (
    <div className="min-h-screen bg-[#f3efe6] p-0 text-[#172a28] lg:p-4">
      <div className="mx-auto flex min-h-screen max-w-[1760px] overflow-hidden bg-[#fbfaf7] shadow-[0_24px_90px_rgba(26,52,45,0.12)] lg:min-h-[calc(100vh-2rem)] lg:rounded-[1.75rem] lg:border lg:border-[#d9dfd8]">
        <aside className="hidden w-[276px] shrink-0 flex-col bg-[#153b34] px-4 py-5 text-white lg:flex">
          <Link className="flex items-center gap-3 px-2" href="/workspace">
            <span className="grid size-10 place-items-center rounded-[14px] bg-[#d5e9df] text-[#153b34] shadow-[0_10px_24px_rgba(0,0,0,0.16)]">
              <KeyRound aria-hidden="true" className="size-5" strokeWidth={2.2} />
            </span>
            <span>
              <span className="block text-lg font-extrabold tracking-[-0.08em]">فُويا</span>
              <span className="mt-0.5 block text-[10px] tracking-[0.18em] text-[#9dbcb1]">VOYA OS</span>
            </span>
          </Link>

          <div className="mt-8 rounded-2xl border border-white/10 bg-white/[0.06] p-3">
            <div className="flex items-center gap-2">
              <Building2 aria-hidden="true" className="size-4 text-[#d5e9df]" />
              <p className="truncate text-xs font-bold text-white">{organizationName}</p>
            </div>
            <p className="mt-2 text-[11px] text-[#a9c2b9]">مساحة تشغيل محمية</p>
          </div>

          <nav aria-label="التنقل الرئيسي" className="mt-8 flex-1 space-y-1">
            <p className="mb-3 px-3 text-[10px] font-bold tracking-[0.12em] text-[#86a79b]">مساحة العمل</p>
            {workspaceItems.map((item) => <NavigationLink activeHref={activeHref} item={item} key={item.label} />)}
            {extensionItems.length > 0 ? <><p className="mb-3 mt-7 px-3 text-[10px] font-bold tracking-[0.12em] text-[#86a79b]">امتدادات المنتج</p>{extensionItems.map((item) => <NavigationLink activeHref={activeHref} item={item} key={item.label} />)}</> : null}
          </nav>

          <div className="mt-5 rounded-2xl border border-white/10 bg-[#0e2c27] p-3.5">
            <div className="flex items-center gap-2 text-[#d5e9df]"><CircleUserRound aria-hidden="true" className="size-4" /><p className="text-xs font-bold">{roleCopy[role] ?? role}</p></div>
            <p className="mt-2 text-[11px] leading-5 text-[#a9c2b9]">صلاحياتك تطبق على الخادم قبل عرض البيانات أو تنفيذ أي إجراء.</p>
          </div>
        </aside>

        <section className="min-w-0 flex-1 bg-[#fbfaf7]">
          <header className="sticky top-0 z-20 flex min-h-[74px] items-center justify-between gap-4 border-b border-[#e4e6df] bg-[#fbfaf7]/95 px-4 backdrop-blur sm:px-7 lg:px-9">
            <div className="flex items-center gap-3">
              <div className="lg:hidden"><MobileNavigation items={mobileItems} /></div>
              <div className="lg:hidden grid size-9 place-items-center rounded-xl bg-[#153b34] text-[#d5e9df]"><KeyRound aria-hidden="true" className="size-4" /></div>
              <div className="hidden items-center gap-2 text-xs text-[#6c7e78] sm:flex">
                <span className="size-2 rounded-full bg-[#b88a3a] shadow-[0_0_0_4px_rgba(184,138,58,0.13)]" />
                <span>تشغيل مباشر</span>
                <span aria-hidden="true" className="text-[#cfd6d0]">/</span>
                <span className="font-bold text-[#203b35]">{organizationName}</span>
              </div>
            </div>
            <div className="flex items-center gap-2">
              <Link className="hidden items-center gap-2 rounded-xl border border-[#d9dfd8] bg-white px-3 py-2 text-xs font-bold text-[#32534a] transition hover:border-[#b88a3a] sm:flex" href="/workspace/notifications">
                <Bell aria-hidden="true" className="size-4" />
                التنبيهات
              </Link>
              <div className="flex items-center gap-2 rounded-xl border border-[#d9dfd8] bg-white px-2 py-1.5">
                <span className="grid size-7 place-items-center rounded-lg bg-[#d5e9df] text-[10px] font-extrabold text-[#153b34]">م</span>
                <span className="hidden text-xs font-bold text-[#203b35] sm:block">{roleCopy[role] ?? role}</span>
                <form action={signOutAction}>
                  <button className="rounded-lg px-2 py-1 text-[11px] font-bold text-[#6c7e78] transition hover:bg-[#fff1ed] hover:text-[#a84e3e]" type="submit">
                    خروج
                  </button>
                </form>
              </div>
            </div>
          </header>
          <div className="min-w-0">{children}</div>
        </section>
      </div>
    </div>
  );
}
