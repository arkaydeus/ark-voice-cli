# ark-voice site

The landing page and documentation for ark-voice: Next.js (App Router, MDX), Tailwind CSS and
shadcn/ui, with Bun as the package manager and runtime.

Tasks run through [mise](https://mise.jdx.dev), from anywhere in the repository:

```sh
mise install            # the pinned Bun
mise run web:install   # bun install
mise run web:dev       # dev server on http://localhost:3000
mise run web:fmt       # bun fmt
mise run web:check     # bun fmt --check, next typegen, bun check
mise run web:test      # loader, heading, search and clipboard tests
mise run web:build     # production build
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

Run tests from `web/` with `bun run test`, or from anywhere in the repository with
`mise run web:test`. Tests use Bun's per-file isolation and Happy DOM. Only the Next.js router
and the `server-only` boundary marker are mocked; search uses the real command and dialog
components. Heading tests compare against compiled, rendered MDX, and check every docs page's
navigation entry, search headings, and internal links.
