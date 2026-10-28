"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import type { DocSection } from "@/lib/docs";
import { cn } from "@/lib/utils";

export function DocsNav({
  sections,
  onNavigate,
}: {
  sections: DocSection[];
  onNavigate?: () => void;
}) {
  const pathname = usePathname();

  return (
    <nav className="flex flex-col">
      {sections.map((section, index) => (
        <div
          key={section.title}
          className={cn("py-5", index > 0 && "border-t border-line")}
        >
          <p className="mb-2 text-[0.9375rem] font-semibold">{section.title}</p>
          <ul className="flex flex-col gap-0.5">
            {section.pages.map((page) => {
              const href = `/docs/${page.slug}`;
              const active = pathname === href;
              return (
                <li key={page.slug}>
                  <Link
                    href={href}
                    onClick={onNavigate}
                    aria-current={active ? "page" : undefined}
                    className={cn(
                      "-mx-2 block rounded-md px-2 py-1.5 text-[0.9375rem] text-subtle transition-colors hover:text-foreground",
                      active && "bg-brand-soft font-medium text-brand-strong",
                    )}
                  >
                    {page.title}
                  </Link>
                </li>
              );
            })}
          </ul>
        </div>
      ))}
    </nav>
  );
}
