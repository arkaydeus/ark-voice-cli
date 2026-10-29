import { ArrowRightIcon, ArrowUpRightIcon } from "lucide-react";
import Link from "next/link";
import { CopyButton } from "@/components/site/copy-button";
import { SiteFooter } from "@/components/site/site-footer";
import { Terminal, type TerminalLine } from "@/components/site/terminal";
import { site } from "@/lib/site";
import { cn } from "@/lib/utils";

const installCommand = `git clone ${site.repo}`;

const session: TerminalLine[] = [
  { kind: "command", text: 'ark-voice tts "Hello from my Mac" -o hello.m4a' },
  { kind: "output", text: "hello.m4a", tone: "dim" },
  { kind: "command", text: "ark-voice stt hello.m4a --stream" },
  { kind: "output", text: "Hello from my Mac.", tone: "brand" },
  { kind: "divider" },
  { kind: "command", text: "ark-voice serve &" },
  {
    kind: "command",
    text: 'ark-voice client tts "No reload for this one" -o quick.wav',
  },
  { kind: "output", text: "quick.wav", tone: "dim" },
  { kind: "command", text: "ark-voice client status" },
  { kind: "output", text: "synthesis model loaded: true", tone: "good" },
  { kind: "output", text: "requests served: 1" },
];

const bindings = [
  { name: "Swift", href: "/docs/swift-client" },
  { name: "TypeScript", href: "/docs/typescript" },
  { name: "Python", href: "/docs/python" },
  { name: "Protocol", href: "/docs/protocol" },
];

const modes = [
  {
    label: "01 / Command line",
    command: "ark-voice stt memo.m4a",
    body: "Transcribe or speak files, or stream audio through pipes.",
    href: "/docs/transcription",
  },
  {
    label: "02 / Swift library",
    command: "import ArkVoiceKit",
    body: "Run the models inside your own app, with no IPC.",
    href: "/docs/swift-library",
  },
  {
    label: "03 / Server",
    command: "ark-voice serve",
    body: "Keep models loaded and answer requests over a Unix socket.",
    href: "/docs/server",
  },
];

const features = [
  {
    title: "Streaming in both directions",
    body: "Synthesis writes audio to stdout as each chunk is generated, so playback starts before the whole utterance is done. Recognition can print text as it is recognized, and reads audio from stdin.",
    link: "Pipe audio through it",
    href: "/docs/streaming",
  },
  {
    title: "Pinned, verified models",
    body: "Nothing is bundled and nothing downloads until you ask. Downloads are pinned to reviewed Hugging Face revisions, weights are SHA-256 checked, and a snapshot only becomes active once it is complete.",
    link: "See how models are stored",
    href: "/docs/models",
  },
  {
    title: "Reusable voice profiles",
    body: "Clone a voice from a reference recording, or save it as a named profile so later generations skip processing the recording. Profiles stay on your Mac.",
    link: "Create a voice profile",
    href: "/docs/voice-profiles",
  },
  {
    title: "Three recognizers",
    body: "Parakeet v2 for fast English on the GPU, Parakeet Ultra on the Neural Engine for 25 European languages in about 0.1 GB, and Qwen3-ASR for 30 languages and 22 Chinese dialects.",
    link: "Choose a recognizer",
    href: "/docs/recognizers",
  },
];

const latency = [
  { label: "client tts", value: 0.24, display: "0.24 s", highlight: true },
  { label: "tts", value: 5.9, display: "~5.9 s" },
];

const throughput = [
  { label: "parakeet-ultra", value: 175, display: "~175×", highlight: true },
  { label: "qwen", value: 50, display: "~50×" },
];

export default function Home() {
  return (
    <>
      <main className="flex-1">
        <Hero />
        <div className="mx-auto max-w-6xl px-6 sm:px-10">
          <BindingsStrip />
          <Modes />
          <Features />
          <Benchmarks />
        </div>
      </main>
      <SiteFooter />
    </>
  );
}

function Hero() {
  return (
    <section className="mx-auto grid max-w-6xl items-center gap-14 px-6 pt-16 pb-20 sm:px-10 lg:grid-cols-[1.05fr_1fr] lg:pt-24 *:min-w-0">
      <div>
        <a
          href={site.releases}
          className="inline-flex items-center gap-2 border-b border-line pb-2 text-sm text-faint transition-colors hover:text-foreground"
        >
          <span className="font-mono text-foreground">v{site.version}</span>
          <span aria-hidden="true">·</span>
          Releases
          <ArrowUpRightIcon className="size-3.5" />
        </a>
        <h1 className="mt-6 text-5xl leading-[1.02] font-medium tracking-[-0.035em] sm:text-6xl">
          Local speech for Apple Silicon
        </h1>
        <p className="mt-7 max-w-xl text-lg leading-relaxed text-subtle">
          ark-voice transcribes speech and speaks English on your Mac, with no
          cloud API. Use it from the command line, link it into a Swift app, or
          keep the models loaded behind{" "}
          <code className="rounded bg-surface-soft px-1.5 py-0.5 font-mono text-[0.85em] text-brand-strong dark:text-brand">
            ark-voice serve
          </code>{" "}
          and call it from any language.
        </p>
        <div className="mt-9 flex flex-wrap items-center gap-6">
          <Link
            href="/docs/getting-started"
            className="inline-flex h-12 items-center gap-3 rounded-md bg-brand px-6 font-medium text-brand-ink transition-colors hover:bg-brand-strong dark:hover:bg-brand-strong"
          >
            Get started
            <ArrowRightIcon className="size-4" />
          </Link>
          <Link
            href="/docs/cli"
            className="inline-flex items-center gap-2 font-medium text-brand transition-colors hover:text-brand-strong"
          >
            CLI reference
            <ArrowRightIcon className="size-4" />
          </Link>
        </div>
        <div className="mt-8 flex max-w-xl items-center gap-3 rounded-lg border border-line bg-surface py-2 pr-2 pl-4 font-mono text-[0.8125rem]">
          <span className="text-faint select-none">$</span>
          <span className="flex-1 overflow-x-auto whitespace-nowrap">
            {installCommand}
          </span>
          <CopyButton value={installCommand} label />
        </div>
        <p className="mt-3 text-sm text-faint">
          Then run <code className="font-mono">./Scripts/build-release.sh</code>{" "}
          ·{" "}
          <Link
            href="/docs/installation"
            className="text-brand underline underline-offset-2"
          >
            Installation guide
          </Link>
        </p>
      </div>
      <div>
        <Terminal
          title="~/notes"
          lines={session}
          className="lg:rotate-[-1deg]"
        />
        <p className="mt-4 text-sm text-faint">
          Illustrative session. Progress messages go to stderr and are omitted.
        </p>
      </div>
    </section>
  );
}

function BindingsStrip() {
  return (
    <section className="flex flex-wrap items-center justify-between gap-6 border-y border-line py-6">
      <p className="text-subtle">Clients for the server</p>
      <div className="flex flex-wrap gap-x-10 gap-y-3">
        {bindings.map((binding) => (
          <Link
            key={binding.name}
            href={binding.href}
            className="group inline-flex items-center gap-1.5 text-lg font-medium"
          >
            {binding.name}
            <ArrowUpRightIcon className="size-4 text-brand transition-transform group-hover:translate-x-0.5 group-hover:-translate-y-0.5" />
          </Link>
        ))}
      </div>
    </section>
  );
}

function Modes() {
  return (
    <section className="py-20">
      <h2 className="text-4xl font-medium tracking-tight">
        Three ways to use it
      </h2>
      <div className="mt-8 grid overflow-hidden rounded-lg border border-line bg-surface md:grid-cols-3">
        {modes.map((mode, index) => (
          <Link
            key={mode.label}
            href={mode.href}
            className={cn(
              "group p-6 transition-colors hover:bg-surface-soft",
              index > 0 && "border-t border-line md:border-t-0 md:border-l",
            )}
          >
            <p className="text-sm text-faint">{mode.label}</p>
            <p className="mt-5 font-mono text-lg text-brand">{mode.command}</p>
            <p className="mt-4 leading-relaxed text-subtle">{mode.body}</p>
          </Link>
        ))}
      </div>
    </section>
  );
}

function Features() {
  return (
    <section className="grid gap-x-16 pb-8 md:grid-cols-2">
      {features.map((feature) => (
        <article key={feature.title} className="border-b border-line py-10">
          <h3 className="text-3xl font-medium tracking-tight">
            {feature.title}
          </h3>
          <p className="mt-5 leading-relaxed text-subtle">{feature.body}</p>
          <Link
            href={feature.href}
            className="mt-6 inline-flex items-center gap-2 font-medium text-brand transition-colors hover:text-brand-strong"
          >
            {feature.link}
            <ArrowRightIcon className="size-4" />
          </Link>
        </article>
      ))}
    </section>
  );
}

function Bars({
  caption,
  rows,
}: {
  caption: string;
  rows: {
    label: string;
    value: number;
    display: string;
    highlight?: boolean;
  }[];
}) {
  const max = Math.max(...rows.map((row) => row.value));
  return (
    <figure>
      <figcaption className="text-sm text-faint">{caption}</figcaption>
      <div className="mt-5 space-y-3.5">
        {rows.map((row) => (
          <div
            key={row.label}
            className="grid grid-cols-[7.5rem_1fr_4.5rem] items-center gap-4 font-mono text-sm"
          >
            <span
              className={
                row.highlight ? "font-medium text-brand" : "text-subtle"
              }
            >
              {row.label}
            </span>
            <span className="h-3.5">
              <span
                className={cn(
                  "block h-full rounded-[3px]",
                  row.highlight ? "bg-brand" : "bg-faint/70",
                )}
                style={{ width: `${Math.max((row.value / max) * 100, 2)}%` }}
              />
            </span>
            <span
              className={cn(
                "text-right",
                row.highlight && "font-medium text-brand",
              )}
            >
              {row.display}
            </span>
          </div>
        ))}
      </div>
    </figure>
  );
}

function Benchmarks() {
  return (
    <section
      id="benchmarks"
      className="grid items-center gap-12 py-24 lg:grid-cols-2 *:min-w-0"
    >
      <div>
        <h2 className="text-4xl font-medium tracking-tight">
          Models stay loaded
        </h2>
        <p className="mt-5 max-w-lg leading-relaxed text-subtle">
          A process per call reloads about a gigabyte of weights every time. The
          server loads them once and answers in a fraction of a second.
          Recognition runs many times faster than real time.
        </p>
        <Link
          href="/docs/performance"
          className="mt-6 inline-flex items-center gap-2 font-medium text-brand transition-colors hover:text-brand-strong"
        >
          Measurements and method
          <ArrowRightIcon className="size-4" />
        </Link>
      </div>
      <div className="space-y-9 rounded-lg border border-line bg-surface p-7">
        <Bars
          caption="One short utterance · seconds · lower is better"
          rows={latency}
        />
        <Bars
          caption="Recognition speed · × real time · higher is better"
          rows={throughput}
        />
        <p className="text-xs leading-relaxed text-faint">
          Latency on an M-series Mac with weights in the page cache. Recognition
          on an M5 Max over 32 minutes of LibriSpeech read English.
        </p>
      </div>
    </section>
  );
}
