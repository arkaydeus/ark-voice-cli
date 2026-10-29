"use client";

import { MenuIcon } from "lucide-react";
import Link from "next/link";
import { useState } from "react";
import {
  Sheet,
  SheetContent,
  SheetTitle,
  SheetTrigger,
} from "@/components/ui/sheet";
import type { DocSection } from "@/lib/docs";
import { headerNav } from "@/lib/site";
import { DocsNav } from "./docs-nav";
import { LogoMark } from "./logo";

export function MobileNav({ sections }: { sections: DocSection[] }) {
  const [open, setOpen] = useState(false);
  const close = () => setOpen(false);

  return (
    <Sheet open={open} onOpenChange={setOpen}>
      <SheetTrigger
        aria-label="Open navigation"
        className="flex size-9 items-center justify-center rounded-md text-subtle hover:text-foreground md:hidden"
      >
        <MenuIcon className="size-5" />
      </SheetTrigger>
      <SheetContent side="left" className="w-80 overflow-y-auto px-6 py-5">
        <SheetTitle className="flex items-center gap-2 text-lg font-semibold">
          <LogoMark className="size-6" />
          ark-voice
        </SheetTitle>
        <div className="flex flex-col gap-1 border-b border-line pb-4">
          {headerNav.map((item) =>
            "href" in item ? (
              <Link
                key={item.title}
                href={item.href}
                onClick={close}
                className="py-1 font-medium"
              >
                {item.title}
              </Link>
            ) : (
              item.items.map((link) => (
                <Link
                  key={link.href}
                  href={link.href}
                  onClick={close}
                  className="py-1 font-medium"
                >
                  {link.title}
                </Link>
              ))
            ),
          )}
        </div>
        <DocsNav sections={sections} onNavigate={close} />
      </SheetContent>
    </Sheet>
  );
}
