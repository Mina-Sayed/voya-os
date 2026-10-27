import Image from "next/image";
import Link from "next/link";
import { ArrowLeft, BedDouble, UsersRound } from "lucide-react";
import type { VoyaStayPublicListing } from "@/lib/stay/public-catalog";
import styles from "./stay-home-page.module.css";
import searchStyles from "./stay-search-pages.module.css";

export function StayPublicListingCard({
  listing,
  eager = false,
}: Readonly<{ listing: VoyaStayPublicListing; eager?: boolean }>) {
  const image = listing.images[0];
  return (
    <article className={styles.conceptCard}>
      <div className={styles.conceptImageWrap}>
        {image ? (
          <Image
            alt={image.alt}
            className={styles.conceptImage}
            fill
            loading={eager ? "eager" : "lazy"}
            sizes="(max-width: 700px) 92vw, (max-width: 1100px) 46vw, 31vw"
            src={image.url}
            unoptimized
          />
        ) : (
          <div aria-label="لا توجد صورة عامة لهذه الإقامة" className={searchStyles.publicImageFallback} role="img">VOYA STAY</div>
        )}
        <span className={styles.imageDemoTag}>صور منشورة بموافقة الموظف</span>
      </div>
      <div className={styles.conceptCardBody}>
        <div className={styles.conceptCardMeta}>
          <span>{listing.areaLabel}</span>
          <span>بيانات إقامة منشورة</span>
        </div>
        <h2 className={searchStyles.publicListingTitle}>{listing.title}</h2>
        <p>{listing.description}</p>
        <div aria-label="تفاصيل الإقامة" className={searchStyles.publicListingFacts}>
          <span><BedDouble aria-hidden="true" />{listing.bedrooms === 0 ? "استوديو" : `${listing.bedrooms} غرف نوم`}</span>
          <span><UsersRound aria-hidden="true" />حتى {listing.maxGuests} ضيوف</span>
        </div>
        {listing.advisoryAvailable === true ? <p className={searchStyles.advisoryAvailable}>الفترة تبدو متاحة وفق السجل الحالي، والتأكيد بعد مراجعة الفريق.</p> : null}
        {listing.advisoryAvailable === false ? <p className={searchStyles.advisoryUnavailable}>قد تتعارض الفترة مع سجل الإشغال؛ يراجع الفريق الطلب قبل أي تأكيد.</p> : null}
        <Link className={styles.conceptDetailLink} href={`/stay/property/${listing.slug}`}>
          عرض تفاصيل الإقامة
          <ArrowLeft aria-hidden="true" className={styles.inlineIcon} />
        </Link>
      </div>
    </article>
  );
}
