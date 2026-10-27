export type StayDemoEnvironment = Readonly<{
  NODE_ENV?: string;
  VOYA_STAY_DEMO_MODE?: string;
}>;

export function stayDemoModeEnabled(environment: StayDemoEnvironment): boolean {
  return environment.NODE_ENV !== "production" && environment.VOYA_STAY_DEMO_MODE === "1";
}
