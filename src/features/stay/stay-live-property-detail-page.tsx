import Image from "next/image";
import Link from "next/link";
import { ArrowLeft, BedDouble, BadgeInfo, MapPin, ShieldCheck, UsersRound } from "lucide-react";
import type { VoyaStayPublicListing, VoyaStayRequestConfig } from "@/lib/stay/public-catalog";
import { StayGuestRequestForm } from "./stay-guest-request-form";
import { StaySiteFrame } from "./voya-stay-home-page";
import styles from "./stay-search-pages.module.css";
import homeStyles from "./stay-home-page.module.css";

export function StayLivePropertyDetailPage({
  listing,
  requestConfig,
  initialCheckIn,
  initialCheckOut,
  initialGuests,
}: Readonly<{
  listing: VoyaStayPublicListing;
  requestConfig: VoyaStayRequestConfig;
  initialCheckIn?: string;
  initialCheckOut?: string;
  initialGuests?: number;
}>) {
  const image = listing.images[0];

  return (
    <StaySiteFrame mode="detail">
      <div className={styles.detailPage} id="detail">
        <nav aria-label="مسار التنقل" className={styles.breadcrumb}>
          <Link href="/">الرئيسية</Link>
          <span aria-hidden="true">/</span>
          <Link href="/stay/search">الإقامات المنشورة</Link>
          <span aria-hidden="true">/</span>
          <span aria-current="page">{listing.title}</span>
        </nav>

        <header className={styles.detailHeader}>
          <div>
            <p className={homeStyles.sectionEyebrow}>VOYA STAY · إقامة منشورة</p>
            <h1>{listing.title}</h1>
            <p className="inline-flex items-center gap-1.5"><MapPin aria-hidden="true" className="size-3.5 text-tide" />{listing.areaLabel}</p>
          </div>
          <span className={styles.detailDemoBadge}>
            <ShieldCheck aria-hidden="true" />
            راجعها فريق VOYA
          </span>
        </header>

        <div className={styles.detailGrid}>
          {image ? (
            <figure className={styles.detailGalleryLive}>
              <Image alt={image.alt} className={styles.detailGalleryLiveImage} fill priority sizes="(max-width: 700px) 92vw, 60vw" src={image.url} unoptimized />
              <figcaption className={homeStyles.visuallyHidden}>{listing.title} — صورة منشورة بموافقة الموظف</figcaption>
            </figure>
          ) : (
            <div aria-label="لا توجد صورة عامة لهذه الإقامة" className={styles.detailGalleryLiveEmpty} role="img">VOYA STAY</div>
          )}

          <aside aria-labelledby="live-detail-facts-title" className={styles.detailNotice}>
            <span aria-hidden="true" className={styles.detailNoticeIcon}><BadgeInfo /></span>
            <p className={styles.detailNoticeEyebrow}>المعلومات المنشورة</p>
            <h2 id="live-detail-facts-title">تفاصيل الإقامة</h2>
            <p className={styles.detailNoticeText}>{listing.description}</p>
            <dl className={styles.liveDetailFacts}>
              <div><dt><MapPin aria-hidden="true" /> المنطقة</dt><dd>{listing.areaLabel}</dd></div>
              <div><dt><BedDouble aria-hidden="true" /> غرف النوم</dt><dd>{listing.bedrooms === 0 ? "استوديو" : listing.bedrooms}</dd></div>
              <div><dt><UsersRound aria-hidden="true" /> الضيوف</dt><dd>حتى {listing.maxGuests}</dd></div>
              {listing.advisoryAvailable !== null ? <div><dt>التوفر الإرشادي</dt><dd>{listing.advisoryAvailable ? "يبدو متاحًا" : "قد لا يتاح"}</dd></div> : null}
            </dl>
            {listing.amenities.length ? (
              <div className={styles.liveAmenities}>
                <h3>مرافق معلنة</h3>
                <ul>{listing.amenities.map((amenity) => <li key={amenity}>{amenity}</li>)}</ul>
              </div>
            ) : null}
            <p className={styles.liveRequestNotice}>بيانات الإشغال إرشادية لحظة البحث. راجع فريق VOYA الطلب قبل أي تأكيد.</p>
          </aside>
        </div>

        <section aria-labelledby="guest-request-title" className={styles.detailBoundary}>
          <p className={homeStyles.sectionEyebrow}>خطوة غير ملزمة</p>
          <h2 id="guest-request-title">اطلب مراجعة الإقامة</h2>
          <p>سيصل طلبك إلى فريق VOYA لمراجعته والتواصل معك. لا يتم تأكيد حجز أو حجز تواريخ من هذا النموذج.</p>
          {requestConfig.requestsEnabled && requestConfig.privacyNoticeUrl && requestConfig.privacyNoticeVersion ? (
            <StayGuestRequestForm
              initialCheckIn={initialCheckIn}
              initialCheckOut={initialCheckOut}
              initialGuests={initialGuests}
              privacyNoticeUrl={requestConfig.privacyNoticeUrl}
              privacyNoticeVersion={requestConfig.privacyNoticeVersion}
              slug={listing.slug}
            />
          ) : (
            <p className={styles.requestUnavailable}>طلبات الإقامة غير متاحة الآن. تحقق لاحقًا أو اختر إقامة منشورة أخرى.</p>
          )}
          <Link className={styles.detailBackLink} href="/stay/search">
            العودة إلى الإقامات
            <ArrowLeft aria-hidden="true" className={homeStyles.inlineIcon} />
          </Link>
        </section>
      </div>
    </StaySiteFrame>
  );
}
