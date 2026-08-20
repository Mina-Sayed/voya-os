export type PropertyOwnerMutationState = Readonly<{
  status: "idle" | "success" | "invalid" | "denied" | "retry";
  message: string;
}>;

export type PropertyOwnerMutationAction = (
  previousState: PropertyOwnerMutationState,
  formData: FormData,
) => Promise<PropertyOwnerMutationState>;
