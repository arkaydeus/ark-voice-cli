"use client";

import { MoonIcon, SunIcon } from "lucide-react";
import { useTheme } from "next-themes";

export function ThemeToggle() {
  const { resolvedTheme, setTheme } = useTheme();

  return (
    <button
      type="button"
      aria-label="Toggle dark mode"
      onClick={() => setTheme(resolvedTheme === "dark" ? "light" : "dark")}
      className="relative flex h-6 w-10 items-center rounded-full border border-line bg-surface-soft transition-colors hover:border-faint"
    >
      <span className="absolute left-0.5 flex size-[1.125rem] items-center justify-center rounded-full bg-background shadow-sm transition-transform dark:translate-x-4">
        <SunIcon className="size-3 text-faint dark:hidden" />
        <MoonIcon className="hidden size-3 text-faint dark:block" />
      </span>
    </button>
  );
}
