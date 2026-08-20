export type PropertyMutationState = Readonly<{
  status: "idle" | "success" | "invalid" | "denied" | "retry";
  message: string;
}>;

export type PropertyMutationAction = (
  previousState: PropertyMutationState,
  formData: FormData,
) => Promise<PropertyMutationState>;
