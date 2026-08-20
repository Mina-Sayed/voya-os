import { z } from "zod";

export type ActionResult<T> =
  | Readonly<{
      status: "success";
      data: T;
      requestId: string;
    }>
  | Readonly<{
      status: "error";
      code: string;
      message: string;
      requestId: string;
      fieldErrors?: Readonly<Record<string, readonly string[]>>;
    }>;

export type CommandContext = Readonly<{
  userId: string;
  membershipId: string;
  organizationId: string;
  requestId: string;
}>;

export const moneyDtoSchema = z.object({
  amountMinor: z.string().regex(/^(0|[1-9]\d*)$/, "amountMinor must be a non-negative integer string"),
  currency: z.string().regex(/^[A-Z]{3}$/, "currency must be an ISO 4217 code"),
});

export type MoneyDto = Readonly<z.infer<typeof moneyDtoSchema>>;

export const commandIdempotencyKeySchema = z.string().trim().min(1).max(160);

export function success<T>(data: T, requestId: string): ActionResult<T> {
  return { status: "success", data, requestId };
}

export function failure<T = never>(
  requestId: string,
  code: string,
  message: string,
  fieldErrors?: Readonly<Record<string, readonly string[]>>,
): ActionResult<T> {
  return { status: "error", code, message, requestId, ...(fieldErrors ? { fieldErrors } : {}) };
}
