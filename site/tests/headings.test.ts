import { expect, test } from "bun:test";
import { parseHeadings, type Heading } from "@/lib/headings";
import { renderedHeadings, renderMdx } from "./render-mdx";

const fixtures = [
  "## `ARK_VOICE_SOCKET`\n\n### `--max_tokens`\n\n## `a*b_c`",
  "## **Bold** and _emphasis_ with `a_b` and literal_underlines\n\n### ~~Deleted~~ [a **link**](https://example.com)",
  "## Fish &amp; chips &#x26; salt\n\n### Escaped \\*stars\\* and \\_underscores\\_",
  "# Same\n\n## Same\n\n#### Same\n\n### Same\n\n## Same-1\n\n## Same",
  "## Café: 你好!\n\n### <code>inline_code</code> and **bold**\n\n## ![ignored alt](image.png) image",
  "## [Reference][ref]\n\n[ref]: https://example.com\n\nSetext **heading**\n------------------\n\n> ## Nested heading",
  "````md\n## Hidden\n```\n### Still hidden\n````\n\n~~~md\n## Hidden too\n```\n~~~\n\n    ## Indented heading\n\n## Visible\n\n### Visible ###",
];

test.each(fixtures)("heading text and ids match rendered MDX: %s", (source) => {
  expect(parseHeadings(source)).toEqual(renderedHeadings(renderMdx(source)));
});

test("preserves underscores inside inline identifiers", () => {
  expect(parseHeadings(fixtures[0])).toEqual([
    { id: "ark_voice_socket", text: "ARK_VOICE_SOCKET", depth: 2 },
    { id: "--max_tokens", text: "--max_tokens", depth: 3 },
    { id: "ab_c", text: "a*b_c", depth: 2 },
  ]);
});

test("skips code fences and follows MDX's indented heading syntax", () => {
  expect(parseHeadings(fixtures[6]).map((heading) => heading.text)).toEqual([
    "Indented heading",
    "Visible",
    "Visible",
  ]);
});

test("counts headings at every depth for duplicate ids and resets per document", () => {
  const source = "# Same\n\n## Same\n\n#### Same\n\n### Same";
  const expected: Heading[] = [
    { id: "same-1", text: "Same", depth: 2 },
    { id: "same-3", text: "Same", depth: 3 },
  ];
  expect(parseHeadings(source)).toEqual(expected);
  expect(parseHeadings(source)).toEqual(expected);
  expect(parseHeadings("No headings")).toEqual([]);
});
