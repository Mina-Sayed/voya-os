import type { OrganizationId } from "../tenancy/organization";
import { stayRangesOverlap, type StayRange } from "./stay-range";

export type BookingStatus =
  | "draft"
  | "pending_approval"
  | "confirmed"
  | "checked_in"
  | "checked_out"
  | "cancelled"
  | "completed";

export type ConfirmedBooking = Readonly<{
  id: string;
  organizationId: OrganizationId;
  propertyId: string;
  status: BookingStatus;
  stay: StayRange;
}>;

function isOccupyingStatus(status: BookingStatus): boolean {
  // Both confirmed and checked-in stays hold inventory in the occupancy
  // ledger; checked_out/completed/cancelled release it.
  return status === "confirmed" || status === "checked_in";
}

export function hasConfirmedBookingConflict(
  candidate: ConfirmedBooking,
  existing: readonly ConfirmedBooking[],
): boolean {
  if (!isOccupyingStatus(candidate.status)) {
    return false;
  }

  return existing.some(
    (booking) =>
      booking.id !== candidate.id &&
      isOccupyingStatus(booking.status) &&
      booking.organizationId === candidate.organizationId &&
      booking.propertyId === candidate.propertyId &&
      stayRangesOverlap(candidate.stay, booking.stay),
  );
}
