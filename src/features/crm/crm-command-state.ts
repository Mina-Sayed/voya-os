export type CrmCommandState = Readonly<{
  status: "idle" | "success" | "invalid" | "denied" | "retry";
  message: string;
}>;

export type CrmCommandAction = (
  previousState: CrmCommandState,
  formData: FormData,
) => Promise<CrmCommandState>;
