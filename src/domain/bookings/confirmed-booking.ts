import type { OrganizationId } from "../tenancy/organization";
import { stayRangesOverlap, type StayRange } from "./stay-range";

export type BookingStatus =
  | "draft"
  | "pending_approval"
  | "confirmed"
  | "cancelled"
  | "completed";

export type ConfirmedBooking = Readonly<{
  id: string;
  organizationId: OrganizationId;
  propertyId: string;
  status: BookingStatus;
  stay: StayRange;
}>;

export function hasConfirmedBookingConflict(
  candidate: ConfirmedBooking,
  existing: readonly ConfirmedBooking[],
): boolean {
  if (candidate.status !== "confirmed") {
    return false;
  }

  return existing.some(
    (booking) =>
      booking.id !== candidate.id &&
      booking.status === "confirmed" &&
      booking.organizationId === candidate.organizationId &&
      booking.propertyId === candidate.propertyId &&
      stayRangesOverlap(candidate.stay, booking.stay),
  );
}
