import createMDX from "@next/mdx";
import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  cacheComponents: true,
  partialPrefetching: true,
  pageExtensions: ["ts", "tsx", "mdx"],
  turbopack: {
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

// Turbopack runs the MDX pipeline in Rust, so plugins are named by string and
// their options must be plain JSON.
const withMDX = createMDX({
  options: {
    remarkPlugins: ["remark-gfm"],
    rehypePlugins: [
      "rehype-slug",
      [
        "rehype-pretty-code",
        {
          theme: { light: "github-light", dark: "github-dark-dimmed" },
          keepBackground: false,
          defaultLang: { block: "text" },
        },
      ],
    ],
  },
});

export default withMDX(nextConfig);
