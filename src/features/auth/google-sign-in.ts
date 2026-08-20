export type GoogleSignInGateway = Readonly<{
  signInWithGoogle(input: Readonly<{ redirectTo: string }>): Promise<string>;
}>;

export type GoogleSignInResult = Readonly<{
  status: "unavailable" | "retry";
}>;
