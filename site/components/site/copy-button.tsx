"use client";

import { CheckIcon, CopyIcon } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { cn } from "@/lib/utils";

type CopyButtonProps = {
  /** Text to copy. Without it, the button copies the nearest `pre` in its `.code-block`. */
  value?: string;
  label?: boolean;
  className?: string;
};

export function CopyButton({ value, label, className }: CopyButtonProps) {
  const ref = useRef<HTMLButtonElement>(null);
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    if (!copied) return;
    const timer = setTimeout(() => setCopied(false), 1600);
    return () => clearTimeout(timer);
  }, [copied]);

  async function copy() {
    const text =
      value ??
      ref.current?.closest(".code-block")?.querySelector("pre")?.textContent ??
      "";
    await navigator.clipboard.writeText(text.trimEnd());
    setCopied(true);
  }

  return (
    <button
      ref={ref}
      type="button"
      onClick={copy}
      aria-label={copied ? "Copied" : "Copy to clipboard"}
      className={cn(
        "inline-flex items-center gap-1.5 rounded-md border border-line bg-background px-2 py-1 font-mono text-xs text-faint transition-colors hover:text-foreground",
        className,
      )}
    >
      {copied ? (
        <CheckIcon className="size-3.5 text-good" />
      ) : (
        <CopyIcon className="size-3.5" />
      )}
      {label && (copied ? "Copied" : "Copy")}
    </button>
  );
}
