import "server-only";

import { readFileSync } from "node:fs";
import path from "node:path";
import GithubSlugger from "github-slugger";

export type DocMeta = { slug: string; title: string; description: string };
export type DocSection = { title: string; pages: DocMeta[] };
export type Heading = { id: string; text: string; depth: 2 | 3 };
export type SearchEntry = DocMeta & { section: string; headings: Heading[] };

/** Sidebar order. Each slug has a matching `content/docs/<slug>.mdx`. */
export const docsNav: DocSection[] = [
  {
    title: "Start here",
    pages: [
      {
        slug: "getting-started",
        title: "Getting started",
        description:
          "Build ark-voice, download the models, and run your first transcription and synthesis.",
      },
      {
        slug: "installation",
        title: "Installation",
        description:
          "Requirements, the release build, and installing ark-voice system-wide.",
      },
      {
        slug: "models",
        title: "Models and downloads",
        description:
          "Which models ark-voice uses, where they live, and how downloads are verified.",
      },
    ],
  },
  {
    title: "Using the CLI",
    pages: [
      {
        slug: "transcription",
        title: "Transcription",
        description:
          "Turn WAV, AAC, M4A and MP4 audio, or PCM on stdin, into text.",
      },
      {
        slug: "synthesis",
        title: "Speech synthesis",
        description:
          "Generate English speech as WAV, M4A or AAC from inline text, files or stdin.",
      },
      {
        slug: "streaming",
        title: "Streaming and pipes",
        description:
          "Write audio to stdout as it is generated and read audio from stdin.",
      },
      {
        slug: "voice-profiles",
        title: "Voice profiles",
        description:
          "Clone a voice from a reference recording and save it under a name.",
      },
      {
        slug: "recognizers",
        title: "Choosing a recognizer",
        description:
          "Parakeet v2, Parakeet Ultra and Qwen3-ASR compared: languages, memory and speed.",
      },
    ],
  },
  {
    title: "Integrate",
    pages: [
      {
        slug: "swift-library",
        title: "Swift library",
        description:
          "Link ArkVoiceKit and run the models inside your own process.",
      },
      {
        slug: "server",
        title: "Running the server",
        description:
          "Keep the models resident with ark-voice serve and drive it with ark-voice client.",
      },
      {
        slug: "protocol",
        title: "Socket protocol",
        description:
          "The framing, operations, events and error codes spoken over the Unix socket.",
      },
    ],
  },
  {
    title: "Client bindings",
    pages: [
      {
        slug: "swift-client",
        title: "Swift client",
        description:
          "ArkVoiceClient: an async/await client for the server with no dependencies.",
      },
      {
        slug: "typescript",
        title: "TypeScript",
        description:
          "A zero-dependency client for Node 18+ and Bun built on async iterables.",
      },
      {
        slug: "python",
        title: "Python",
        description:
          "A standard-library client for Python 3.10+, with sync and asyncio APIs.",
      },
    ],
  },
  {
    title: "Reference",
    pages: [
      {
        slug: "cli",
        title: "CLI reference",
        description: "Every ark-voice command, option and alias.",
      },
      {
        slug: "performance",
        title: "Performance",
        description:
          "Measured latency, throughput, memory and accuracy on Apple Silicon.",
      },
      {
        slug: "notes",
        title: "Limitations and notes",
        description:
          "Language support, output formats, stdout behaviour and other details.",
      },
      {
        slug: "development",
        title: "Building and testing",
        description:
          "Run the Swift test suites, the binding suites, and this documentation site.",
      },
    ],
  },
];

const contentDir = path.join(process.cwd(), "content", "docs");

export const allDocs: (DocMeta & { section: string })[] = docsNav.flatMap(
  (section) =>
    section.pages.map((page) => ({ ...page, section: section.title })),
);

export function getDoc(slug: string) {
  const index = allDocs.findIndex((doc) => doc.slug === slug);
  if (index === -1) return undefined;
  return {
    doc: allDocs[index],
    previous: allDocs[index - 1],
    next: allDocs[index + 1],
  };
}

/**
 * Reads `##` and `###` headings from an MDX file, skipping code fences, and
 * slugs them the same way rehype-slug does so the ids match the rendered page.
 */
export function getHeadings(slug: string): Heading[] {
  const source = readFileSync(path.join(contentDir, `${slug}.mdx`), "utf8");
  const slugger = new GithubSlugger();
  const headings: Heading[] = [];
  let inFence = false;

  for (const line of source.split("\n")) {
    if (/^\s*(```|~~~)/.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    const match = /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line);
    if (!match) continue;
    const text = match[2]
      .replace(/`([^`]+)`/g, "$1")
      .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
      .replace(/[*_]/g, "");
    const id = slugger.slug(text);
    const depth = match[1].length;
    if (depth === 2 || depth === 3) headings.push({ id, text, depth });
  }
  return headings;
}

export function getSearchIndex(): SearchEntry[] {
  return allDocs.map((doc) => ({ ...doc, headings: getHeadings(doc.slug) }));
}
