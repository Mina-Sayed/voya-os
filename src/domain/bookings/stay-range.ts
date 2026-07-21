export type StayRange = Readonly<{
  checkIn: string;
  checkOut: string;
}>;

function isIsoDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return false;
  }

  const date = new Date(`${value}T00:00:00.000Z`);
  return !Number.isNaN(date.valueOf()) && date.toISOString().slice(0, 10) === value;
}

export function createStayRange(checkIn: string, checkOut: string): StayRange {
  if (!checkIn || !checkOut || !isIsoDate(checkIn) || !isIsoDate(checkOut)) {
    throw new Error("Stay dates are required");
  }

  if (checkIn >= checkOut) {
    throw new Error("Check-out must be after check-in");
  }

  return { checkIn, checkOut };
}

export function stayRangesOverlap(left: StayRange, right: StayRange): boolean {
  return left.checkIn < right.checkOut && right.checkIn < left.checkOut;
}
