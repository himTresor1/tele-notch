// TeleNotch docs: draws the sidebar, top bar and "On this page" around each page's <article>,
// and fills the Changelog from the GitHub releases (the same notes the app's update window shows).
(function () {
  const repo = (window.TELENOTCH_REPO || "").trim();
  const page = document.body.dataset.page;

  const icon = {
    intro: '<path d="M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18Zm0-11v6m0-9h.01"/>',
    install: '<path d="M12 3v12m0 0-4.5-4.5M12 15l4.5-4.5M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2"/>',
    usage: '<path d="M4 6h16M4 12h10M4 18h7"/><circle cx="18" cy="16.5" r="2.5"/>',
    changelog: '<path d="M3 12a9 9 0 1 0 3-6.7L3 8m0-5v5h5m4-1v5l3 2"/>',
    book: '<path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v16H6.5A2.5 2.5 0 0 0 4 21.5zM4 5.5v16"/>',
    download: '<path d="M12 3v12m0 0-4.5-4.5M12 15l4.5-4.5M5 20h14"/>',
    toc: '<path d="M4 6h16M4 12h12M4 18h8"/>',
    menu: '<path d="M4 7h16M4 12h16M4 17h16"/>',
    info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5m0-8h.01"/>',
  };
  const svg = (name) =>
    `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${icon[name]}</svg>`;

  const pages = [
    { group: "Get started", id: "intro", title: "Introduction", href: "./", icon: "intro" },
    { group: "Get started", id: "install", title: "Installation", href: "installation.html", icon: "install" },
    { group: "Guides", id: "usage", title: "How to Use", href: "usage.html", icon: "usage" },
    { group: "Updates", id: "changelog", title: "Changelog", href: "changelog.html", icon: "changelog" },
  ];
  const dmg = repo ? `https://github.com/${repo}/releases/latest/download/TeleNotch.dmg` : "installation.html";
  const gh = repo ? `https://github.com/${repo}` : "#";

  // ---- Sidebar ----
  let nav = "", last = "";
  for (const p of pages) {
    if (p.group !== last) { nav += `<div class="group">${p.group}</div>`; last = p.group; }
    nav += `<a href="${p.href}"${p.id === page ? ' aria-current="page"' : ""}>${svg(p.icon)}${p.title}</a>`;
  }
  const side = document.createElement("aside");
  side.className = "side";
  side.innerHTML = `
    <a class="brand" href="../"><img src="../logo.svg" alt="">TeleNotch <span class="badge">Docs</span></a>
    <nav aria-label="Documentation">${nav}</nav>
    <div class="foot">
      <a href="${dmg}">Download for Mac <span>↓</span></a>
      <a href="../">TeleNotch home <span>↗</span></a>
      <a href="${gh}">GitHub <span>↗</span></a>
    </div>`;

  // ---- Top bar ----
  const top = document.createElement("header");
  top.className = "top";
  top.innerHTML = `
    <button class="menu" aria-label="Open menu">${svg("menu")}</button>
    <a class="mbrand" href="./"><img src="../logo.svg" alt="">TeleNotch <span class="badge">Docs</span></a>
    <nav class="tabs" aria-label="Sections">
      <a href="./"${page !== "changelog" ? ' class="on"' : ""}>${svg("book")}Docs</a>
      <a href="changelog.html"${page === "changelog" ? ' class="on"' : ""}>${svg("changelog")}Changelog</a>
    </nav>
    <span class="spacer"></span>
    <a class="dl" href="${dmg}">${svg("download")}Download</a>`;

  document.body.prepend(side, top);
  top.querySelector(".menu").addEventListener("click", () => document.body.classList.toggle("nav-open"));
  document.addEventListener("click", (e) => {
    if (document.body.classList.contains("nav-open") && !side.contains(e.target) && !top.querySelector(".menu").contains(e.target))
      document.body.classList.remove("nav-open");
  });

  // ---- Prev / next ----
  const article = document.querySelector("article");
  const i = pages.findIndex((p) => p.id === page);
  if (article && i >= 0) {
    const prev = pages[i - 1], next = pages[i + 1];
    const pager = document.createElement("nav");
    pager.className = "pager";
    pager.innerHTML =
      (prev ? `<a href="${prev.href}"><small>← Previous</small><b>${prev.title}</b></a>` : "") +
      (next ? `<a class="next" href="${next.href}"><small>Next →</small><b>${next.title}</b></a>` : "");
    article.append(pager);
  }

  // Callout icons and copy buttons
  document.querySelectorAll(".note").forEach((n) => n.insertAdjacentHTML("afterbegin", svg("info")));
  document.querySelectorAll("pre").forEach((pre) => {
    const b = document.createElement("button");
    b.className = "copy"; b.textContent = "Copy";
    b.onclick = () => navigator.clipboard.writeText(pre.innerText.replace(/Copy(ied)?$/, "").trim())
      .then(() => { b.textContent = "Copied"; setTimeout(() => (b.textContent = "Copy"), 1500); });
    pre.append(b);
  });

  if (page === "changelog") loadChangelog().then(buildToc);
  else buildToc();

  // ---- On this page ----
  function buildToc() {
    const toc = document.querySelector(".toc");
    if (!toc || !article) return;
    const heads = Array.from(article.querySelectorAll("h2, h3")).filter((h) => !h.closest(".pager"));
    heads.forEach((h) => {
      if (!h.id) h.id = slug(h.textContent);
      if (!h.querySelector(".anchor")) h.insertAdjacentHTML("afterbegin", `<a class="anchor" href="#${h.id}" aria-hidden="true">#</a>`);
    });
    const label = (h) => h.dataset.toc || h.textContent.replace(/^#/, "").trim();
    toc.innerHTML = `<p class="title">${svg("toc")}On this page</p><ul>${heads
      .map((h) => `<li><a href="#${h.id}"${h.tagName === "H3" ? ' class="sub"' : ""}>${esc(label(h))}</a></li>`)
      .join("")}</ul>`;
    const links = Array.from(toc.querySelectorAll("a"));
    const mark = () => {
      let cur = heads[0];
      for (const h of heads) if (h.getBoundingClientRect().top < 140) cur = h;
      if (window.innerHeight + window.scrollY >= document.body.scrollHeight - 4) cur = heads[heads.length - 1];
      links.forEach((a) => a.classList.toggle("on", cur && a.getAttribute("href") === "#" + cur.id));
    };
    addEventListener("scroll", mark, { passive: true });
    mark();
    if (location.hash) document.getElementById(location.hash.slice(1))?.scrollIntoView();
  }

  // ---- Changelog ----
  function loadChangelog() {
    const list = document.querySelector("[data-releases]");
    const fail = (msg) => { list.innerHTML = `<p>${msg}</p>`; };
    if (!repo) { fail("No releases yet."); return Promise.resolve(); }
    return fetch(`https://api.github.com/repos/${repo}/releases?per_page=50`, { headers: { Accept: "application/vnd.github+json" } })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(r.status))))
      .then((rels) => {
        rels = rels.filter((r) => !r.draft && !r.prerelease);
        if (!rels.length) return fail("No releases yet.");
        list.innerHTML = rels.map((r, n) => {
          const v = r.tag_name.replace(/^v/, "");
          const dmgAsset = (r.assets || []).find((a) => a.name.endsWith(".dmg")) || (r.assets || []).find((a) => a.name.endsWith(".zip"));
          return `<section class="release">
            <h2 id="v${v.replace(/\./g, "-")}" data-toc="${esc(`${v} · ${shortDate(r.published_at)}`)}">${esc(fmtDate(r.published_at))}</h2>
            <div class="ver">Version ${esc(v)}${n === 0 ? '<span class="latest">Latest</span>' : ""}</div>
            <div class="body">${markdown(r.body || "")}</div>
            ${dmgAsset ? `<a class="dlv" href="${esc(dmgAsset.browser_download_url)}">Download version ${esc(v)} →</a>` : ""}
          </section>`;
        }).join("");
      })
      .catch(() => fail(`Couldn't load the changelog right now. <a href="https://github.com/${repo}/releases">See every release on GitHub</a>.`));
  }

  function fmtDate(iso) {
    return new Date(iso).toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" });
  }
  function shortDate(iso) {
    return new Date(iso).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric" });
  }
  function slug(s) {
    return s.toLowerCase().replace(/^#/, "").trim().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  }
  function esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  }
  // Small Markdown subset for release notes: headings, bullet lists, paragraphs, **bold**, `code`, [links](url).
  function inline(s) {
    return esc(s)
      .replace(/\*\*(.+?)\*\*/g, "<b>$1</b>")
      .replace(/`(.+?)`/g, "<code>$1</code>")
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
