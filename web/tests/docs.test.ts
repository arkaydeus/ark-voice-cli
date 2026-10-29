import { expect, mock, test } from "bun:test";
import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { renderedHeadings, renderMdx } from "./render-mdx";

// Next supplies this boundary marker in production; allow the server loader here.
mock.module("server-only", () => ({}));
const { allDocs, docsNav, getDoc, getHeadings, getSearchIndex } =
  await import("@/lib/docs");
const contentDir = path.join(process.cwd(), "content/docs");

test("unknown slugs have no document or headings", () => {
  for (const slug of ["missing-page", "", "../README", "toString"]) {
    expect(getDoc(slug)).toBeUndefined();
    expect(getHeadings(slug)).toEqual([]);
  }
});

test("navigation order defines previous and next, including both edges", () => {
  expect(allDocs).toEqual(
    docsNav.flatMap(({ title, pages }) =>
      pages.map((page) => ({ ...page, section: title })),
    ),
  );
  for (const [index, doc] of allDocs.entries()) {
    expect(getDoc(doc.slug)).toEqual({
      doc,
      previous: allDocs[index - 1],
      next: allDocs[index + 1],
    });
  }
});

test("navigation and content have exactly one entry for each page", () => {
  const slugs = allDocs.map(({ slug }) => slug);
  const files = readdirSync(contentDir)
    .filter((name) => name.endsWith(".mdx"))
    .map((name) => name.slice(0, -4));
  expect(new Set(slugs).size).toBe(slugs.length);
  expect([...slugs].sort()).toEqual(files.sort());
});

test("every search and TOC heading matches the rendered document", () => {
  const index = getSearchIndex();
  expect(index.map(({ headings, ...doc }) => doc)).toEqual(allDocs);
  for (const entry of index) {
    const source = readFileSync(
      path.join(contentDir, `${entry.slug}.mdx`),
      "utf8",
    );
    expect(entry.headings).toEqual(renderedHeadings(renderMdx(source)));
    expect(getHeadings(entry.slug)).toEqual(entry.headings);
  }
});

test("internal documentation links point to existing pages and rendered anchors", () => {
  const pages = new Map(
    allDocs.map(({ slug }) => [
      slug,
      renderMdx(readFileSync(path.join(contentDir, `${slug}.mdx`), "utf8")),
    ]),
  );
  let checked = 0;
  for (const [slug, page] of pages) {
    for (const link of page.querySelectorAll("a[href]")) {
      const href = link.getAttribute("href")!;
      if (!href.startsWith("/docs/") && !href.startsWith("#")) continue;
      const url = new URL(href, `https://docs.example/docs/${slug}`);
      const target = pages.get(
        url.pathname.slice("/docs/".length).replace(/\/$/, ""),
      );
      expect(target, `${slug}: ${href}`).toBeDefined();
      if (url.hash) {
        const ids = Array.from(
          target!.querySelectorAll("[id]"),
          (node) => node.id,
        );
        expect(ids, `${slug}: ${href}`).toContain(
          decodeURIComponent(url.hash.slice(1)),
        );
      }
      checked++;
    }
  }
  expect(checked).toBeGreaterThan(0);
});
