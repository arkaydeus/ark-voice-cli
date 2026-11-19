import { ArrowLeftIcon, ArrowRightIcon } from "lucide-react";
import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { Suspense } from "react";
import { TableOfContents } from "@/components/site/toc";
import { allDocs, getDoc, getHeadings } from "@/lib/docs";

export function generateStaticParams() {
  return allDocs.map((doc) => ({ slug: doc.slug }));
}

export async function generateMetadata({
  params,
}: PageProps<"/docs/[slug]">): Promise<Metadata> {
  const { slug } = await params;
  const entry = getDoc(slug);
  if (!entry) return {};
  return { title: entry.doc.title, description: entry.doc.description };
}

export default function DocPage({ params }: PageProps<"/docs/[slug]">) {
  // Reading params suspends, so the docs shell renders at once on navigation.
  return (
    <Suspense fallback={<DocSkeleton />}>
      <Doc params={params} />
    </Suspense>
  );
}

function DocSkeleton() {
  return (
    <div className="max-w-3xl animate-pulse space-y-5 px-6 py-12 sm:px-12 lg:py-14">
      <div className="h-4 w-24 rounded bg-surface-soft" />
      <div className="h-11 w-2/3 rounded bg-surface-soft" />
      <div className="h-6 w-full rounded bg-surface-soft" />
    </div>
  );
}

async function Doc({ params }: Pick<PageProps<"/docs/[slug]">, "params">) {
  const { slug } = await params;
  const entry = getDoc(slug);
  if (!entry) notFound();

  const { doc, previous, next } = entry;
  const { default: Content } = await import(`@/content/docs/${slug}.mdx`);

  return (
    <div className="flex gap-12 px-6 py-12 sm:px-12 lg:py-14">
      <article className="min-w-0 max-w-3xl flex-1">
        <p className="text-sm font-medium text-brand">{doc.section}</p>
        <h1 className="mt-2 text-4xl font-medium tracking-[-0.03em] sm:text-[2.75rem]">
          {doc.title}
        </h1>
        <p className="mt-4 text-xl leading-relaxed text-subtle">
          {doc.description}
        </p>
        <div className="prose-docs mt-10 border-t border-line pt-10">
          <Content />
        </div>
        <nav className="mt-16 grid gap-4 border-t border-line pt-8 sm:grid-cols-2">
          {previous ? (
            <Link
              href={`/docs/${previous.slug}`}
              className="group rounded-lg border border-line p-4 transition-colors hover:border-brand"
            >
              <span className="flex items-center gap-1.5 text-sm text-faint">
                <ArrowLeftIcon className="size-3.5" />
                Previous
              </span>
              <span className="mt-1 block font-medium group-hover:text-brand">
                {previous.title}
              </span>
            </Link>
          ) : (
            <span />
          )}
          {next && (
            <Link
              href={`/docs/${next.slug}`}
              className="group rounded-lg border border-line p-4 text-right transition-colors hover:border-brand"
            >
              <span className="flex items-center justify-end gap-1.5 text-sm text-faint">
                Next
                <ArrowRightIcon className="size-3.5" />
              </span>
              <span className="mt-1 block font-medium group-hover:text-brand">
                {next.title}
              </span>
            </Link>
          )}
        </nav>
      </article>
      <aside className="sticky top-28 hidden h-fit w-56 shrink-0 xl:block">
        <TableOfContents headings={getHeadings(slug)} />
      </aside>
    </div>
  );
}
