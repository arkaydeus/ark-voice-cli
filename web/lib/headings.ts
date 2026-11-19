import { toString } from "hast-util-to-string";
import rehypeSlug from "rehype-slug";
import remarkGfm from "remark-gfm";
import remarkMdx from "remark-mdx";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import { unified } from "unified";
import { visit } from "unist-util-visit";

export type Heading = { id: string; text: string; depth: 2 | 3 };

// Match MDX's Markdown-to-HAST pipeline and the plugins in next.config.ts.
// Keep MDX nodes intact so expressions are not mistaken for literal text.
const processor = unified()
  .use(remarkParse)
  .use(remarkMdx)
  .use(remarkGfm)
  .use(remarkRehype, {
    passThrough: [
      "mdxFlowExpression",
      "mdxJsxFlowElement",
      "mdxJsxTextElement",
      "mdxTextExpression",
      "mdxjsEsm",
    ],
  })
  .use(rehypeSlug);

/** Extract static heading text and ids exactly as rehype-slug sees them. */
export function parseHeadings(source: string): Heading[] {
  const tree = processor.runSync(processor.parse(source));
  const headings: Heading[] = [];
  visit(tree, "element", (node) => {
    if (node.tagName === "h2" || node.tagName === "h3") {
      headings.push({
        id: String(node.properties.id),
        text: toString(node),
        depth: node.tagName === "h2" ? 2 : 3,
      });
    }
  });
  return headings;
}
