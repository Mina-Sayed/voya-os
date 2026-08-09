import { redirect } from "next/navigation";

type HomeProps = Readonly<{
  searchParams: Promise<Readonly<{ code?: string | string[] }>>;
}>;

export default async function Home({ searchParams }: HomeProps) {
  const code = (await searchParams).code;
  if (typeof code === "string" && code.length > 0) {
    redirect(`/auth/callback?code=${encodeURIComponent(code)}`);
  }
  redirect("/workspace");
}
