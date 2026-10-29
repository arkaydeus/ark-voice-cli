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
  const [status, setStatus] = useState<"idle" | "copied" | "error">("idle");

  useEffect(() => {
    if (status !== "copied") return;
    const timer = setTimeout(() => setStatus("idle"), 1600);
    return () => clearTimeout(timer);
  }, [status]);

  async function copy() {
    const text =
      value ??
      ref.current?.closest(".code-block")?.querySelector("pre")?.textContent ??
      "";
    try {
      if (!navigator.clipboard?.writeText) {
        setStatus("error");
        return;
      }
      await navigator.clipboard.writeText(text.trimEnd());
      setStatus("copied");
    } catch {
      setStatus("error");
    }
  }

  const copied = status === "copied";
  const failed = status === "error";

  return (
    <>
      <button
        ref={ref}
        type="button"
        onClick={copy}
        aria-label={
          failed
            ? "Copy failed. Try again"
            : copied
              ? "Copied"
              : "Copy to clipboard"
        }
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
        {failed ? "Copy failed" : label && (copied ? "Copied" : "Copy")}
      </button>
      <span role="status" className="sr-only">
        {failed
          ? "Copy failed. Select the text to copy manually, or try again."
          : copied
            ? "Copied to clipboard."
            : ""}
      </span>
    </>
  );
}
