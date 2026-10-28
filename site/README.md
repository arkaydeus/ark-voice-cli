# ark-voice site

The landing page and documentation for ark-voice: Next.js (App Router, MDX), Tailwind CSS and
shadcn/ui, with Bun as the package manager and runtime.

Tasks run through [mise](https://mise.jdx.dev), from anywhere in the repository:

```sh
mise install            # the pinned Bun
mise run site:install   # bun install
mise run site:dev       # dev server on http://localhost:3000
mise run site:fmt       # bun fmt
mise run site:check     # bun fmt --check, next typegen, bun check
mise run site:build     # production build
```

## Layout

- `app/page.tsx`: the landing page
- `app/docs/[slug]/page.tsx`: renders `content/docs/<slug>.mdx`
- `lib/docs.ts`: sidebar order, page titles and descriptions; headings for the table of contents
  and search are read from the MDX files
- `mdx-components.tsx`: code blocks with copy buttons, tables, and `<Callout>`
- `components/ui`: shadcn/ui components (Base UI); `components/site`: everything else

To add a page, add an entry to `docsNav` in `lib/docs.ts` and create the matching `.mdx` file.

`bunfig.toml` selects Bun's hoisted linker, because Turbopack cannot resolve peer dependencies
through the isolated `node_modules/.bun` layout.
