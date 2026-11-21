// Fills the download links, version and release notes from the GitHub repo set in config.js.
// Used by both pages: the home page (download button + version line) and releases.html (the notes).
(function () {
  const repo = (window.TELENOTCH_REPO || "").trim();
  const $all = (sel) => Array.from(document.querySelectorAll(sel));
  const list = document.querySelector("[data-releases]");
  const setList = (html) => { if (list) list.innerHTML = html; };

  if (!repo) {
    setText("[data-version-long]", "Coming soon.");
    setList('<p class="muted">No releases yet.</p>');
    return;
  }

  const latestZip = `https://github.com/${repo}/releases/latest/download/TeleNotch.zip`;
  $all("[data-download]").forEach((a) => (a.href = latestZip));
  $all("[data-repo-link]").forEach((a) => (a.href = `https://github.com/${repo}`));

  fetch(`https://api.github.com/repos/${repo}/releases?per_page=20`, { headers: { Accept: "application/vnd.github+json" } })
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error(r.status))))
    .then((releases) => {
      releases = releases.filter((r) => !r.draft && !r.prerelease);
      if (!releases.length) {
        setText("[data-version-long]", "Coming soon.");
        setList('<p class="muted">No releases yet.</p>');
        return;
      }
      const latest = releases[0];
      const v = latest.tag_name.replace(/^v/, "");
      setText("[data-version]", `Version ${v} · Free · macOS 26 or later · Uses your own Anthropic API key`);
      setText("[data-version-long]", `Latest: version ${v}, released ${fmtDate(latest.published_at)}.`);
      setList(releases.map((r, i) => renderRelease(r, i === 0)).join(""));
    })
    .catch(() => {
      setText("[data-version-long]", "");
      setList(`<p class="muted">Couldn't load release notes. <a href="https://github.com/${repo}/releases">See them on GitHub</a>.</p>`);
    });

  function setText(sel, text) { $all(sel).forEach((el) => (el.textContent = text)); }

  function fmtDate(iso) {
    return new Date(iso).toLocaleDateString(undefined, { year: "numeric", month: "long", day: "numeric" });
  }

  function renderRelease(r, isLatest) {
    const zip = (r.assets || []).find((a) => a.name.endsWith(".zip"));
    return `<article class="release">
      <header>
        <h3>${esc(r.name || r.tag_name)}</h3>
        ${isLatest ? '<span class="latest">Latest</span>' : ""}
        <span class="date">${fmtDate(r.published_at)}</span>
      </header>
      <div class="body">${markdown(r.body || "")}</div>
      ${zip ? `<a class="dl" href="${esc(zip.browser_download_url)}">Download this version</a>` : ""}
    </article>`;
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  }

  // Small Markdown subset for release notes: headings, bullet lists, paragraphs, **bold**, `code`, [links](url).
  function inline(s) {
    return esc(s)
      .replace(/\*\*(.+?)\*\*/g, "<b>$1</b>")
      .replace(/`(.+?)`/g, "<kbd>$1</kbd>")
      .replace(/\[(.+?)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2">$1</a>');
  }
  function markdown(md) {
    const out = [];
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
})();
