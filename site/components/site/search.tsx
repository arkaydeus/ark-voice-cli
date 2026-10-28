"use client";

import { FileTextIcon, HashIcon, SearchIcon } from "lucide-react";
import { useRouter } from "next/navigation";
import { useEffect, useState } from "react";
import {
  Command,
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
} from "@/components/ui/command";
import type { SearchEntry } from "@/lib/docs";
import { cn } from "@/lib/utils";

// cmdk's default fuzzy scoring matches scattered letters, which is noisy for
// prose. Require every word of the query to appear somewhere in the item.
function filter(value: string, search: string, keywords?: string[]) {
  const haystack = [value, ...(keywords ?? [])].join(" ").toLowerCase();
  const words = search.toLowerCase().split(/\s+/).filter(Boolean);
  return words.every((word) => haystack.includes(word)) ? 1 : 0;
}

export function Search({
  index,
  className,
}: {
  index: SearchEntry[];
  className?: string;
}) {
  const [open, setOpen] = useState(false);
  const router = useRouter();

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "k" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault();
        setOpen((value) => !value);
      }
    }
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, []);

  function go(href: string) {
    setOpen(false);
    router.push(href);
  }

  const sections = [...new Set(index.map((entry) => entry.section))];

  return (
    <>
      <button
        type="button"
        onClick={() => setOpen(true)}
        className={cn(
          "flex h-9 items-center gap-2 rounded-lg bg-surface-soft px-3 text-sm text-faint transition-colors hover:text-foreground",
          className,
        )}
      >
        <SearchIcon className="size-4" />
        <span className="max-lg:sr-only">Search</span>
        <kbd className="ml-auto max-lg:hidden rounded border border-line bg-background px-1.5 font-mono text-[0.7rem]">
          ⌘K
        </kbd>
      </button>
      <CommandDialog
        open={open}
        onOpenChange={setOpen}
        title="Search the docs"
        description="Find a page or section"
        className="sm:max-w-xl"
      >
        <Command filter={filter}>
          <CommandInput placeholder="Search the docs…" />
          <CommandList className="max-h-[60vh]">
            <CommandEmpty>No results.</CommandEmpty>
            {sections.map((section) => (
              <CommandGroup key={section} heading={section}>
                {index
                  .filter((entry) => entry.section === section)
                  .flatMap((entry) => [
                    <CommandItem
                      key={entry.slug}
                      value={`${entry.title} ${entry.slug}`}
                      keywords={[entry.description]}
                      onSelect={() => go(`/docs/${entry.slug}`)}
                      className="[&>svg:last-child]:hidden"
                    >
                      <FileTextIcon className="text-faint" />
                      <span className="font-medium">{entry.title}</span>
                    </CommandItem>,
                    ...entry.headings.map((heading) => (
                      <CommandItem
                        key={`${entry.slug}#${heading.id}`}
                        value={`${entry.title} › ${heading.text} ${entry.slug}#${heading.id}`}
                        onSelect={() => go(`/docs/${entry.slug}#${heading.id}`)}
                        className="pl-7 [&>svg:last-child]:hidden"
                      >
                        <HashIcon className="text-faint" />
                        <span className="truncate">{heading.text}</span>
                        <span className="ml-auto shrink-0 text-xs text-faint">
                          {entry.title}
                        </span>
                      </CommandItem>
                    )),
                  ])}
              </CommandGroup>
            ))}
          </CommandList>
        </Command>
      </CommandDialog>
    </>
  );
}
