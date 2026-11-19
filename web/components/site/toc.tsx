"use client";

import { useEffect, useState } from "react";
import type { Heading } from "@/lib/docs";
import { cn } from "@/lib/utils";

export function TableOfContents({ headings }: { headings: Heading[] }) {
  const [active, setActive] = useState<string | undefined>(headings[0]?.id);

  useEffect(() => {
    const elements = headings
      .map((heading) => document.getElementById(heading.id))
      .filter((element): element is HTMLElement => element !== null);
    if (elements.length === 0) return;

    // The active heading is the last one scrolled past the top band.
    function update() {
      let current = elements[0].id;
      for (const element of elements) {
        if (element.getBoundingClientRect().top <= 120) current = element.id;
      }
      setActive(current);
    }

    update();
    window.addEventListener("scroll", update, { passive: true });
    return () => window.removeEventListener("scroll", update);
  }, [headings]);

  if (headings.length === 0) return null;

  return (
    <nav aria-label="On this page" className="border-l border-line pl-4">
      <p className="mb-3 text-sm font-semibold">On this page</p>
      <ul className="space-y-2 text-sm">
        {headings.map((heading) => (
          <li key={heading.id} className={cn(heading.depth === 3 && "pl-3")}>
            <a
              href={`#${heading.id}`}
              className={cn(
                "block text-faint transition-colors hover:text-foreground",
                active === heading.id && "font-medium text-brand",
              )}
            >
              {heading.text}
            </a>
          </li>
        ))}
      </ul>
    </nav>
  );
}
