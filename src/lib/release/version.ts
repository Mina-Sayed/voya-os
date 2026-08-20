export type ReleaseInfo = Readonly<{
  version: string;
  commit: string;
  environment: string;
}>;

type ReleaseEnvironment = Readonly<Record<string, string | undefined>>;

export function readReleaseInfo(environment: ReleaseEnvironment = process.env): ReleaseInfo {
  return {
    version: environment.VOYA_RELEASE_VERSION?.trim() || "v1",
    commit: environment.VOYA_RELEASE_SHA?.trim() || environment.VERCEL_GIT_COMMIT_SHA?.trim() || "unknown",
    environment: environment.VERCEL_ENV?.trim() || environment.NODE_ENV?.trim() || "unknown",
  };
}
