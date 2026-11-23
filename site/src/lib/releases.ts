// Site-wide settings and the GitHub releases, fetched once at build time.
// The Pages workflow rebuilds the site whenever a release is published, so these stay current.
export const REPO = "himTresor1/tele-notch";
export const GITHUB = `https://github.com/${REPO}`;
export const DMG = `${GITHUB}/releases/latest/download/TeleNotch.dmg`;

export type Release = {
  version: string;
  date: string; // ISO
  body: string;
  download?: string;
};

let cache: Promise<Release[]> | undefined;

export function getReleases(): Promise<Release[]> {
  cache ??= load();
  return cache;
}

async function load(): Promise<Release[]> {
  const headers: Record<string, string> = { Accept: "application/vnd.github+json" };
  if (process.env.GITHUB_TOKEN) headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  try {
    const r = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=100`, { headers });
    if (!r.ok) throw new Error(`GitHub API ${r.status}`);
    const all = (await r.json()) as any[];
    return all
      .filter((x) => !x.draft && !x.prerelease)
      .map((x) => {
        const assets = (x.assets ?? []) as any[];
        const file = assets.find((a) => a.name.endsWith(".dmg")) ?? assets.find((a) => a.name.endsWith(".zip"));
        return {
          version: String(x.tag_name).replace(/^v/, ""),
          date: x.published_at,
          body: x.body ?? "",
          download: file?.browser_download_url,
        };
      });
  } catch (e) {
    console.warn(`[releases] couldn't load releases: ${e}`);
    return [];
  }
}

export const longDate = (iso: string) =>
  new Date(iso).toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric", timeZone: "UTC" });
export const shortDate = (iso: string) =>
  new Date(iso).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" });

// Small Markdown subset for release notes: headings, bullet lists, paragraphs, **bold**, `code`, [links](url).
const esc = (s: string) =>
  s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);
const inline = (s: string) =>
  esc(s)
    .replace(/\*\*(.+?)\*\*/g, "<b>$1</b>")
    .replace(/`(.+?)`/g, "<code>$1</code>")
    .replace(/\[(.+?)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2">$1</a>');

export function markdown(md: string): string {
  const out: string[] = [];
  let inList = false;
  for (const raw of md.replace(/\r/g, "").split("\n")) {
    const line = raw.trim();
    const item = line.match(/^[-*]\s+(.*)/);
    if (item) {
      if (!inList) { out.push("<ul>"); inList = true; }
      out.push(`<li>${inline(item[1])}</li>`);
      continue;
    }
    if (inList) { out.push("</ul>"); inList = false; }
    const h = line.match(/^#{1,6}\s+(.*)/);
    if (h) out.push(`<h4>${inline(h[1])}</h4>`);
    else if (line) out.push(`<p>${inline(line)}</p>`);
  }
  if (inList) out.push("</ul>");
  return out.join("");
}
