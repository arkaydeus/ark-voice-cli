export const site = {
  name: "ark-voice",
  version: "0.2.0",
  tagline: "Local speech for Apple Silicon",
  description:
    "Speech recognition and English speech synthesis that run on your Mac. Use ark-voice from the command line, link it into a Swift app, or keep the models resident behind a Unix socket.",
  repo: "https://github.com/arkaydeus/ark-voice-cli",
  releases: "https://github.com/arkaydeus/ark-voice-cli/releases",
};

export function repoFile(path: string) {
  return `${site.repo}/blob/main/${path}`;
}

export type NavLink = { title: string; href: string; description?: string };

export const headerNav: (NavLink | { title: string; items: NavLink[] })[] = [
  { title: "Docs", href: "/docs/getting-started" },
  {
    title: "Reference",
    items: [
      {
        title: "CLI reference",
        href: "/docs/cli",
        description: "Every command and option",
      },
      {
        title: "Socket protocol",
        href: "/docs/protocol",
        description: "Framing, operations and events",
      },
      {
        title: "Error codes",
        href: "/docs/protocol#errors",
        description: "What each server error means",
      },
    ],
  },
  {
    title: "Bindings",
    items: [
      {
        title: "Swift",
        href: "/docs/swift-client",
        description: "ArkVoiceClient, async/await",
      },
      {
        title: "TypeScript",
        href: "/docs/typescript",
        description: "Node 18+ and Bun",
      },
      {
        title: "Python",
        href: "/docs/python",
        description: "3.10+, sync and asyncio",
      },
    ],
  },
  { title: "Performance", href: "/docs/performance" },
];
