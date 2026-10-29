import Link from "next/link";
import { site } from "@/lib/site";

export function SiteFooter() {
  return (
    <footer className="border-t border-line">
      <div className="mx-auto flex max-w-[90rem] flex-wrap items-center justify-center gap-x-2 gap-y-1 px-6 py-8 text-sm text-faint">
        <span>ark-voice {site.version}</span>
        <span aria-hidden="true">·</span>
        <span>Local speech on Apple Silicon</span>
        <span aria-hidden="true">·</span>
        <Link href="/docs/getting-started" className="hover:text-foreground">
          Docs
        </Link>
        <span aria-hidden="true">·</span>
        <a href={site.repo} className="hover:text-foreground">
          GitHub
        </a>
      </div>
    </footer>
  );
}
