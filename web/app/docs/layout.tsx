import { DocsNav } from "@/components/site/docs-nav";
import { SiteFooter } from "@/components/site/site-footer";
import { docsNav } from "@/lib/docs";

export default function DocsLayout({ children }: LayoutProps<"/docs">) {
  return (
    <>
      <div className="mx-auto flex w-full max-w-[90rem] flex-1">
        <aside className="sticky top-16 hidden h-[calc(100svh-4rem)] w-72 shrink-0 overflow-y-auto border-r border-line bg-surface px-8 pb-10 md:block">
          <DocsNav sections={docsNav} />
        </aside>
        <div className="min-w-0 flex-1">{children}</div>
      </div>
      <SiteFooter />
    </>
  );
}
