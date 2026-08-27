export type ExecutableBookingChangeProjection = Readonly<{
  booking_id: string;
  approval_request_id: string;
  proposed_action: "booking.confirm" | "booking.amend";
}>;

export function indexExecutableBookingChanges(rows: readonly ExecutableBookingChangeProjection[]) {
  const confirmationBookingIds = new Set<string>();
  const amendmentByBooking = new Map<string, string>();

  for (const row of rows) {
    if (row.proposed_action === "booking.confirm") {
      confirmationBookingIds.add(row.booking_id);
    } else if (!amendmentByBooking.has(row.booking_id)) {
      amendmentByBooking.set(row.booking_id, row.approval_request_id);
    }
  }

  return { confirmationBookingIds, amendmentByBooking };
}
