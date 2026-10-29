import { InfoIcon, TriangleAlertIcon } from "lucide-react";
import type { MDXComponents } from "mdx/types";
import Link from "next/link";
import type { ComponentProps, ReactNode } from "react";
import { CopyButton } from "@/components/site/copy-button";
import { cn } from "@/lib/utils";

function Anchor({ href = "", ...props }: ComponentProps<"a">) {
  if (href.startsWith("/") || href.startsWith("#")) {
    return <Link href={href} {...props} />;
  }
  return <a href={href} target="_blank" rel="noreferrer" {...props} />;
}

function Pre(props: ComponentProps<"pre"> & { "data-language"?: string }) {
  const language = props["data-language"];
  return (
    <div className="code-block group">
      <div className="absolute top-2 right-2 z-10 flex items-center gap-2">
        {language && language !== "text" && (
          <span className="font-mono text-xs text-faint transition-opacity group-hover:opacity-0">
            {language}
          </span>
        )}
        <CopyButton className="absolute right-0 opacity-0 transition-opacity group-hover:opacity-100 focus-visible:opacity-100" />
      </div>
      <pre {...props} />
    </div>
  );
}

export function Callout({
  type = "note",
  title,
  children,
}: {
  type?: "note" | "warning";
  title?: string;
  children: ReactNode;
}) {
  const Icon = type === "warning" ? TriangleAlertIcon : InfoIcon;
  return (
    <div
      className={cn(
        "my-6 flex gap-3 rounded-lg border px-4 py-3.5 text-[0.9375rem] leading-relaxed [&_p]:my-0",
        type === "warning"
          ? "border-amber-500/40 bg-amber-500/10"
          : "border-brand/30 bg-brand-soft",
      )}
    >
      <Icon
        className={cn(
          "mt-1 size-4 shrink-0",
          type === "warning"
            ? "text-amber-600 dark:text-amber-400"
            : "text-brand",
        )}
      />
      <div className="space-y-2">
        {title && <p className="font-semibold text-foreground">{title}</p>}
        {children}
      </div>
    </div>
  );
}

const components: MDXComponents = {
  a: Anchor,
  pre: Pre,
  table: (props) => (
    <div className="table-wrap">
      <table {...props} />
    </div>
  ),
  Callout,
};

export function useMDXComponents(): MDXComponents {
  return components;
}
