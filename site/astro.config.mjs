import { defineConfig } from "astro/config";
import mdx from "@astrojs/mdx";

// Static site for GitHub Pages: every page becomes a folder (/docs/installation/), so URLs have no .html.
export default defineConfig({
  site: "https://notch.tresoramizero.com",
  trailingSlash: "ignore",
  build: { format: "directory" },
  integrations: [mdx()],
  devToolbar: { enabled: false },
});
