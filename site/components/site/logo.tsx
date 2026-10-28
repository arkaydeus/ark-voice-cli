import Link from "next/link";
import { cn } from "@/lib/utils";

const bars = [5, 10, 16, 10, 5];

export function LogoMark({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 32 32"
      aria-hidden="true"
      className={cn("size-7 shrink-0", className)}
    >
      <rect width="32" height="32" rx="8" className="fill-foreground" />
      {bars.map((height, index) => (
        <rect
          key={index}
          x={7 + index * 4}
          y={16 - height / 2}
          width="2.4"
          height={height}
          rx="1.2"
          className="fill-background"
        />
      ))}
    </svg>
  );
}

export function Logo() {
  return (
    <Link
      href="/"
      className="flex items-center gap-2 text-[1.3rem] font-semibold tracking-tight"
    >
      <LogoMark />
      ark-voice
    </Link>
  );
}
