import { ChevronDownIcon } from "lucide-react";
import Link from "next/link";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { docsNav, getSearchIndex } from "@/lib/docs";
import { headerNav, site } from "@/lib/site";
import { GitHubIcon } from "./icons";
import { Logo } from "./logo";
import { MobileNav } from "./mobile-nav";
import { Search } from "./search";
import { ThemeToggle } from "./theme-toggle";

const navLink =
  "rounded-md px-2.5 py-1.5 text-[0.9375rem] font-medium text-foreground/85 transition-colors hover:text-brand";

export function SiteHeader() {
  return (
    <header className="sticky top-0 z-40 border-b border-line bg-background/90 backdrop-blur supports-[backdrop-filter]:bg-background/75">
      <div className="mx-auto flex h-16 max-w-[90rem] items-center gap-4 px-4 sm:px-8">
        <MobileNav sections={docsNav} />
        <Logo />
        <Search
          index={getSearchIndex()}
          className="w-9 justify-center px-0 sm:ml-4 lg:w-52 lg:justify-start lg:px-3"
        />

        <nav className="ml-auto hidden items-center gap-1 md:flex">
          {headerNav.map((item) =>
            "href" in item ? (
              <Link key={item.title} href={item.href} className={navLink}>
                {item.title}
              </Link>
            ) : (
              <DropdownMenu key={item.title}>
                <DropdownMenuTrigger
                  className={`${navLink} inline-flex items-center gap-1 data-popup-open:text-brand`}
                >
                  {item.title}
                  <ChevronDownIcon className="size-3.5" />
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" className="w-60 p-1.5">
                  {item.items.map((link) => (
                    <DropdownMenuItem
                      key={link.href}
                      render={<Link href={link.href} />}
                      className="flex-col items-start gap-0 px-2.5 py-2"
                    >
                      <span className="font-medium">{link.title}</span>
                      {link.description && (
                        <span className="text-xs text-faint">
                          {link.description}
                        </span>
                      )}
                    </DropdownMenuItem>
                  ))}
                </DropdownMenuContent>
              </DropdownMenu>
            ),
          )}
        </nav>

        <div className="ml-auto flex items-center gap-3 md:ml-2 md:border-l md:border-line md:pl-5">
          <ThemeToggle />
          <a
            href={site.repo}
            target="_blank"
            rel="noreferrer"
            aria-label="ark-voice on GitHub"
            className="text-foreground/85 transition-colors hover:text-foreground"
          >
            <GitHubIcon className="size-5" />
          </a>
        </div>
      </div>
    </header>
  );
}
