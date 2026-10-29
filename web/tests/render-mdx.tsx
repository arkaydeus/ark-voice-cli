import { evaluateSync } from "@mdx-js/mdx";
import type { ReactNode } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import * as runtime from "react/jsx-runtime";
import rehypeSlug from "rehype-slug";
import remarkGfm from "remark-gfm";
import type { Heading } from "@/lib/headings";

/** Exercise the real MDX compiler and rehype-slug independently of our parser. */
export function renderMdx(source: string) {
  const { default: Content } = evaluateSync(source, {
    ...runtime,
    remarkPlugins: [remarkGfm],
    rehypePlugins: [rehypeSlug],
  });
  const container = document.createElement("div");
  container.innerHTML = renderToStaticMarkup(
    <Content
      components={{
        Callout: ({ children }: { children: ReactNode }) => (
          <aside>{children}</aside>
        ),
      }}
    />,
  );
  return container;
}

export function renderedHeadings(container: HTMLElement): Heading[] {
  return Array.from(container.querySelectorAll("h2, h3"), (node) => ({
    id: node.id,
    text: node.textContent ?? "",
    depth: node.tagName === "H2" ? 2 : 3,
  }));
}
