import Image from "next/image";
import Link from "next/link";
import {
  ArrowLeft,
  CarFront,
  Check,
  ClipboardCheck,
  Headphones,
  House,
  MapPin,
  Menu,
  Plane,
  Search,
  ShieldCheck,
  Sparkles,
} from "lucide-react";
import { StaySearchForm } from "./stay-search-form";
import { stayDemoExamples } from "./stay-demo-content";
import { StayConceptCard } from "./stay-concept-card";
import { StayPublicListingCard } from "./stay-public-listing-card";
import type { VoyaStayPublicListing } from "@/lib/stay/public-catalog";
import styles from "./stay-home-page.module.css";

const navigationLinks = [
  { href: "#featured", label: "الإقامات" },
  { href: "#services", label: "الخدمات" },
  { href: "#how-it-works", label: "كيف تعمل" },
  { href: "#support", label: "المساندة" },
] as const;

export type StayPageMode = "home" | "search" | "detail";

function linksForMode(mode: StayPageMode) {
  if (mode === "home") return navigationLinks;

  return [
    { href: "/stay/search", label: "الإقامات" },
    { href: "/#services", label: "الخدمات" },
    { href: "/#how-it-works", label: "كيف تعمل" },
    { href: "/#support", label: "المساندة" },
  ] as const;
}

function StayHeader({ mode }: Readonly<{ mode: StayPageMode }>) {
  const pageLinks = linksForMode(mode);
  const homeHref = mode === "home" ? "#top" : "/#top";
  const searchHref = mode === "home" ? "#stay-search" : "/stay/search";

  return (
    <header className={styles.header}>
      <div className={styles.headerInner}>
        <Link aria-label="VOYA Stay، الصفحة الرئيسية" className={styles.brand} href={homeHref}>
          <span className={styles.brandWord}>VOYA</span>
          <span className={styles.brandSub}>STAY</span>
        </Link>

        <nav aria-label="التنقل الرئيسي" className={styles.desktopNav}>
          {pageLinks.map((item) => (
            <a className={styles.navLink} href={item.href} key={item.href}>
              {item.label}
            </a>
          ))}
        </nav>

        <div className={styles.headerActions}>
          <Link className={styles.teamLink} href="/sign-in">
            دخول الفريق
          </Link>
          <a className={styles.headerCta} href={searchHref}>
            ابدأ البحث
            <ArrowLeft aria-hidden="true" className={styles.inlineIcon} />
          </a>
          <details className={styles.mobileMenu}>
            <summary aria-label="فتح قائمة الموقع" className={styles.menuTrigger}>
              <Menu aria-hidden="true" className={styles.menuIcon} />
            </summary>
            <nav aria-label="التنقل على الهاتف" className={styles.mobileMenuPanel}>
              {pageLinks.map((item) => (
                <a className={styles.mobileMenuLink} href={item.href} key={item.href}>
                  {item.label}
                </a>
              ))}
              <Link className={styles.mobileMenuLink} href="/sign-in">
                دخول الفريق
              </Link>
            </nav>
          </details>
        </div>
      </div>
    </header>
  );
}

function StayHero() {
  return (
    <section aria-labelledby="stay-title" className={styles.hero} id="top">
      <Image
        alt=""
        className={styles.heroImage}
        fill
        priority
        sizes="100vw"
        src="/images/demo/voya-stay-hero.webp"
      />
      <div aria-hidden="true" className={styles.heroScrim} />
      <div className={styles.heroInner}>
        <div className={styles.heroCopy}>
          <p className={styles.heroEyebrow}>
            <span className={styles.eyebrowMark} />
            VOYA STAY
            <span className={styles.demoBadge}>إقامات منشورة بمراجعة VOYA</span>
          </p>
          <h1 className={styles.heroTitle} id="stay-title">
            إقامتك المفروشة
            <br />
            تبدأ من هنا
          </h1>
          <p className={styles.heroDescription}>
            ابحث بين الإقامات التي راجعها فريق VOYA، ثم أرسل طلباً ليتم مراجعته قبل أي تأكيد.
          </p>
          <div className={styles.heroActions}>
            <a className={styles.heroPrimaryAction} href="#stay-search">
              <Search aria-hidden="true" className={styles.inlineIcon} />
              ابدأ البحث
            </a>
            <a className={styles.heroSecondaryAction} href="#featured">
              تصفح الإقامات
              <ArrowLeft aria-hidden="true" className={styles.inlineIcon} />
            </a>
          </div>
        </div>
        <p className={styles.photoCaption}>
          <Sparkles aria-hidden="true" className={styles.captionIcon} />
          صورة توضيحية — ليست وحدة فعلية
        </p>
      </div>
    </section>
  );
}

const benefits = [
  {
    icon: House,
    title: "إقامات مفروشة",
    description: "اختر من الإقامات المنشورة بمراجعة فريق VOYA.",
  },
  {
    icon: MapPin,
    title: "ابدأ من وجهتك",
    description: "ابحث حسب الوجهة والتواريخ وعدد الضيوف.",
  },
  {
    icon: ClipboardCheck,
    title: "تفاصيل أوضح",
    description: "راجع معلومات النشر والتوفر الإرشادي.",
  },
] as const;

function StayBenefits() {
  return (
    <section aria-labelledby="benefits-title" className={styles.benefits} id="benefits">
      <h2 className={styles.visuallyHidden} id="benefits-title">مميزات تجربة VOYA Stay</h2>
      <div className={styles.benefitGrid}>
        {benefits.map(({ description, icon: Icon, title }) => (
          <article className={styles.benefit} key={title}>
            <span aria-hidden="true" className={styles.benefitIconWrap}>
              <Icon className={styles.benefitIcon} strokeWidth={1.7} />
            </span>
            <span className={styles.benefitCopy}>
              <span className={styles.benefitTitle}>{title}</span>
              <span className={styles.benefitDescription}>{description}</span>
            </span>
          </article>
        ))}
      </div>
    </section>
  );
}

function SectionHeading({
  id,
  eyebrow,
  title,
  description,
  inverse = false,
}: Readonly<{
  id: string;
  eyebrow: string;
  title: string;
  description: string;
  inverse?: boolean;
}>) {
  return (
    <header className={`${styles.sectionHeading} ${inverse ? styles.sectionHeadingInverse : ""}`}>
      <p className={styles.sectionEyebrow}>{eyebrow}</p>
      <h2 className={styles.sectionTitle} id={id}>{title}</h2>
      <p className={styles.sectionDescription}>{description}</p>
    </header>
  );
}

function FeaturedStaysSection({ listings }: Readonly<{ listings: readonly VoyaStayPublicListing[] }>) {
  const hasPublishedListings = listings.length > 0;
  return (
    <section aria-labelledby="featured-title" className={styles.featuredSection} id="featured">
      <div className={styles.sectionInner}>
        <SectionHeading
          description={hasPublishedListings ? "إقامات اختار فريق VOYA نشر بياناتها وصورها بعد مراجعتها." : "تظهر الإقامات هنا بعد اعتماد بياناتها وصورها للنشر."}
          eyebrow={hasPublishedListings ? "VOYA STAY · إقامات منشورة" : "VOYA STAY · الإقامات المنشورة"}
          id="featured-title"
          title={hasPublishedListings ? "إقامات مختارة لرحلتك" : "استكشف الإقامات المنشورة"}
        />
        {hasPublishedListings ? <div className={styles.conceptGrid}>{listings.map((listing, index) => <StayPublicListingCard eager={index === 0} key={listing.slug} listing={listing} />)}</div> : (
          <div className={styles.conceptGrid}>
            {stayDemoExamples.map((example) => <StayConceptCard example={example} key={example.slug} />)}
          </div>
        )}
        <div className={styles.featuredFooter}>
          <p className={styles.sectionDisclaimer}>
            {hasPublishedListings ? "لا تظهر الإقامة إلا بعد اعتماد معلوماتها وصورها. التوفر إرشادي ولا يؤكد الحجز." : "هذه صور توضيحية فقط؛ لا تمثل وحدات أو أسعاراً أو توافراً حقيقياً."}
          </p>
          <Link className={styles.featuredMore} href="/stay/search">
            استكشف الإقامات
            <ArrowLeft aria-hidden="true" className={styles.inlineIcon} />
          </Link>
        </div>
      </div>
    </section>
  );
}

const serviceConcepts = [
  {
    icon: Plane,
    title: "نقل من المطار",
    description: "تصوّر للخدمة فقط؛ تفاصيل التنفيذ والتوفر غير معروضة.",
  },
  {
    icon: CarFront,
    title: "تصوّر لسائق خاص",
    description: "تصوّر للسائق الخاص فقط؛ لا يؤكد ذلك وجود عرض أو حجز.",
  },
] as const;

function ServicesSection() {
  return (
    <section aria-labelledby="services-title" className={styles.servicesSection} id="services">
      <div className={styles.servicesInner}>
        <SectionHeading
          description="تصوّرات بصرية لخدمات الرحلة. لا تؤكد وجود خدمة فعلية أو توافرها."
          eyebrow="تفاصيل الرحلة · تصوّرات"
          id="services-title"
          inverse
          title="خدمات الرحلة"
        />
        <div className={styles.serviceGrid}>
          {serviceConcepts.map(({ description, icon: Icon, title }) => (
            <article className={styles.serviceCard} key={title}>
              <div aria-hidden="true" className={styles.serviceIconWrap}>
                <Icon className={styles.serviceIcon} strokeWidth={1.5} />
              </div>
              <div className={styles.serviceCardContent}>
                <p className={styles.serviceCardEyebrow}>تصوّر خدمة</p>
                <h3>{title}</h3>
                <p className={styles.serviceCardDescription}>{description}</p>
              </div>
            </article>
          ))}
        </div>
        <p className={styles.serviceDisclaimer}>
          هذه التصوّرات لا تمثل خدمة متاحة للحجز.
        </p>
      </div>
    </section>
  );
}

const howItWorksSteps = [
  {
    number: "١",
    title: "اختر الوجهة والتواريخ",
    description: "ابحث ضمن الإقامات المنشورة المتوافقة مع احتياجك.",
  },
  {
    number: "٢",
    title: "حدد التواريخ والضيوف",
    description: "راجع التفاصيل والتوفر الإرشادي قبل التواصل.",
  },
  {
    number: "٣",
    title: "أرسل طلباً للمراجعة",
    description: "يتلقى الفريق الطلب؛ ولا يحدث تأكيد أو حجز تلقائي.",
  },
] as const;

function HowItWorksSection({ requestsEnabled }: Readonly<{ requestsEnabled: boolean }>) {
  const steps = requestsEnabled ? howItWorksSteps : [
    howItWorksSteps[0],
    howItWorksSteps[1],
    { number: "٣", title: "استقبال الطلبات متوقف", description: "يمكنك مشاهدة الإقامات المنشورة؛ ولن يقبل الموقع طلبات حتى تفعيل استقبالها." },
  ];
  return (
    <section aria-labelledby="how-title" className={styles.howSection} id="how-it-works">
      <div className={styles.sectionInner}>
        <SectionHeading
          description={requestsEnabled ? "ابحث في الإقامات المنشورة، ثم أرسل طلباً للفريق لمراجعته قبل التأكيد." : "ابحث في الإقامات المنشورة؛ استقبال طلبات الضيوف غير مفعّل الآن."}
          eyebrow="رحلة الإقامة"
          id="how-title"
          title="كيف تعمل VOYA Stay"
        />
        <ol className={styles.stepsList}>
          {steps.map((step) => (
            <li className={styles.stepItem} key={step.number}>
              <span aria-hidden="true" className={styles.stepNumber}>{step.number}</span>
              <div className={styles.stepCopy}>
                <h3>{step.title}</h3>
                <p>{step.description}</p>
              </div>
            </li>
          ))}
        </ol>
        <a className={styles.howCta} href="#stay-search">
          ابدأ البحث
          <ArrowLeft aria-hidden="true" className={styles.inlineIcon} />
        </a>
      </div>
    </section>
  );
}

function SupportSection({ requestsEnabled }: Readonly<{ requestsEnabled: boolean }>) {
  return (
    <section aria-labelledby="support-title" className={styles.supportSection} id="support">
      <div className={styles.supportInner}>
        <div className={styles.supportCopy}>
          <SectionHeading
            description="نوّضح ما تم اعتماده، ونراجع طلب الإقامة قبل التواصل بشأن التأكيد."
            eyebrow="الوضوح أولاً"
            id="support-title"
            title="وضوح ومساندة"
          />
          <ul className={styles.trustList}>
            <li>
              <span aria-hidden="true" className={styles.trustCheck}><Check /></span>
              الإقامات المنشورة وصورها اختيرت بمراجعة الموظفين.
            </li>
            <li>
              <span aria-hidden="true" className={styles.trustCheck}><Check /></span>
              لا نعرض سعراً أو تقييماً أو توفراً غير معتمد.
            </li>
            <li>
              <span aria-hidden="true" className={styles.trustCheck}><Check /></span>
              التوفر إرشادي، وطلب الإقامة لا ينشئ حجزاً.
            </li>
          </ul>
        </div>
        <aside aria-label="حالة قنوات الدعم" className={styles.supportCard}>
          <span aria-hidden="true" className={styles.supportIconWrap}>
            <Headphones className={styles.supportIcon} strokeWidth={1.6} />
          </span>
          <p className={styles.supportLabel}>مراجعة بشرية</p>
          <h3>{requestsEnabled ? "فريق VOYA يراجع طلبك" : "استقبال الطلبات غير مفعّل الآن"}</h3>
          <p className={styles.supportCardNote}>{requestsEnabled ? "بعد إرسال الطلب، يتواصل الفريق باستخدام وسيلة التواصل التي قدمتها." : "يمكنك تصفح الإقامات المنشورة؛ ولا يستقبل الموقع طلبات حتى تفعيلها."}</p>
          <span className={styles.supportState}>
            <ShieldCheck aria-hidden="true" className={styles.inlineIcon} />
            {requestsEnabled ? "طلب غير ملزم" : "الطلبات متوقفة"}
          </span>
        </aside>
      </div>
    </section>
  );
}

function StayFooter({ mode }: Readonly<{ mode: StayPageMode }>) {
  const pageLinks = linksForMode(mode);
  const homeHref = mode === "home" ? "#top" : "/#top";

  return (
    <footer className={styles.footer} id="footer">
      <div className={styles.footerInner}>
        <div className={styles.footerBrandBlock}>
          <Link aria-label="VOYA Stay، العودة إلى البداية" className={styles.footerBrand} href={homeHref}>
            VOYA <span>STAY</span>
          </Link>
          <p>إقامة مفروشة، في تصور أوضح.</p>
        </div>
        <nav aria-label="روابط الصفحة" className={styles.footerNav}>
          {pageLinks.map((item) => (
            <a className={styles.footerLink} href={item.href} key={item.href}>
              {item.label}
            </a>
          ))}
        </nav>
        <div className={styles.footerDisclosure}>
          <span className={styles.footerDemoMark}>
            <Sparkles aria-hidden="true" className={styles.inlineIcon} />
            لا حجز تلقائي
          </span>
          <p>تظهر الإقامات بعد اعتمادها. طلب الإقامة يحتاج مراجعة ولا يحجز التواريخ.</p>
        </div>
        <Link className={styles.footerTeamLink} href="/sign-in">
          دخول فريق VOYA
        </Link>
      </div>
      <div className={styles.footerBottom}>
        <p>VOYA Stay · إقامات منشورة بطلب مراجعة</p>
        <a href={homeHref}>العودة إلى الأعلى <ArrowLeft aria-hidden="true" className={styles.inlineIcon} /></a>
      </div>
    </footer>
  );
}

export function StaySiteFrame({
  children,
  mode,
}: Readonly<{
  children: React.ReactNode;
  mode: StayPageMode;
}>) {
  return (
    <div className={styles.page}>
      <a className={styles.skipLink} href="#main-content">
        تجاوز إلى المحتوى
      </a>
      <StayHeader mode={mode} />
      <main id="main-content">{children}</main>
      <StayFooter mode={mode} />
    </div>
  );
}

export function VoyaStayHomePage({
  featuredListings = [],
  requestsEnabled = false,
}: Readonly<{ featuredListings?: readonly VoyaStayPublicListing[]; requestsEnabled?: boolean }>) {
  return (
    <StaySiteFrame mode="home">
        <StayHero />
        <div className={styles.searchDock} id="stay-search">
          <StaySearchForm />
        </div>
        <StayBenefits />
        <FeaturedStaysSection listings={featuredListings} />
        <ServicesSection />
        <HowItWorksSection requestsEnabled={requestsEnabled} />
        <SupportSection requestsEnabled={requestsEnabled} />
    </StaySiteFrame>
  );
}
