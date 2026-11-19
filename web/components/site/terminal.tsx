import { cn } from "@/lib/utils";

export type TerminalLine =
  | { kind: "command"; text: string }
  | { kind: "output"; text: string; tone?: "good" | "dim" | "brand" }
  | { kind: "divider" };

const waveBars = [0.5, 0.9, 0.6, 1, 0.7, 0.4, 0.8];

export function Terminal({
  title,
  lines,
  className,
}: {
  title: string;
  lines: TerminalLine[];
  className?: string;
}) {
  return (
    <div
      className={cn(
        "overflow-hidden rounded-xl border border-term-line bg-term font-mono text-[0.8125rem] leading-relaxed text-zinc-200 shadow-[0_30px_80px_-30px_rgb(20_20_40/0.45)]",
        className,
      )}
    >
      <div className="flex items-center justify-between border-b border-term-line px-4 py-2.5 text-xs text-zinc-400">
        <span>{title}</span>
        <span className="flex h-3.5 items-center gap-[3px]" aria-hidden="true">
          {waveBars.map((height, index) => (
            <span
              key={index}
              className="animate-wave block w-[3px] rounded-full bg-[oklch(0.77_0.13_290)]"
              style={{
                height: `${height * 100}%`,
                animationDelay: `${index * 0.13}s`,
              }}
            />
          ))}
        </span>
      </div>
      <div className="space-y-1.5 overflow-x-auto px-5 py-5">
        {lines.map((line, index) => {
          if (line.kind === "divider") {
            return <hr key={index} className="!my-4 border-term-line" />;
          }
          if (line.kind === "command") {
            return (
              <div key={index} className="whitespace-pre text-zinc-100">
                <span className="mr-3 text-[oklch(0.77_0.13_290)]">$</span>
                {line.text}
              </div>
            );
          }
          return (
            <div
              key={index}
              className={cn(
                "whitespace-pre",
                line.tone === "good" && "text-[oklch(0.8_0.14_155)]",
                line.tone === "dim" && "text-zinc-500",
                line.tone === "brand" && "text-[oklch(0.84_0.09_290)]",
                !line.tone && "text-zinc-300",
              )}
            >
              {line.text}
            </div>
          );
        })}
      </div>
    </div>
  );
}
