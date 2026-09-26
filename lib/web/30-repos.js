"use strict";
/* The repos view. Two screens under one id:
     #/repos          one row per repo, sortable by header, filtered by search
     #/repos/<name>   the repo's page — what lib/card.sh prints for
                      `orgami context`, as sections that disappear when empty
   Every figure shown as the org's comes from 30-repos.jq; the page only
   counts the rows it is filtering. The one clock used is the reader's, for
   "pushed 3 days ago" and for calling a live reading stale. */
(() => {
  const { h } = web;

  /* What an edge is called, seen from the repo: [outbound, inbound]. Every
     kind graph.json can hold is here, so a kind the page has no word for
     cannot slip through as a blank. */
  const LABEL = {
    "calls":         ["calls", "called by"],
    "imports":       ["imports from", "imported by"],
    "references":    ["references", "referenced by"],
    "shares-config": ["shares config with", "shares config with"],
    "depends-on":    ["depends on", "depended on by"],
    "reaches":       ["reaches", "reached by"],
    "uses":          ["uses", "used by"],
    "written-in":    ["written in", "written in"],
    "deploys-to":    ["deploys to", "deployed to by"],
    "changes-with":  ["changes with", "changes with"],
  };
  /* The order the groups are drawn in under "what it talks to". deploys-to
     is drawn under "where it ships" and changes-with under "who it changes
     with", so neither is listed here. */
  const TALK_ORDER = ["calls", "imports", "references", "shares-config", "depends-on", "reaches", "uses", "written-in"];
  /* A live reading older than this is a rumour — lib/live.sh LIVE_STALE_DAYS. */
  const STALE_DAYS = 7;

  const enc = s => encodeURIComponent(s);
  const repoHref = name => "#/repos/" + enc(name);
  const isStale = iso => {
    const t = Date.parse(iso);
    return !Number.isNaN(t) && (Date.now() - t) > STALE_DAYS * 86400000;
  };
  const kindTag = kind => h("span", { class: "tag kind-" + kind }, kind);
  const peerEl = e => e.peer_kind === "repo"
    ? h("a", { href: repoHref(e.peer) }, e.peer)
    : h("span", {}, e.peer, " ", kindTag(e.peer_kind));
  /* The evidence line under an edge. An outbound edge's file is in this
     repo; an inbound one's is in the peer. */
  const edgeEvidence = (e, name) => web.evidence({
    kind: e.confidence === "inferred" ? "inferred" : "extracted",
    at: e.evidence,
    repo: e.dir === "out" ? name : (e.peer_kind === "repo" ? e.peer : null),
  });

  /* A section: heading and body, or nothing when the body is empty. */
  function section(title, ...body) {
    const kids = body.flat().filter(Boolean);
    if (!kids.length) return web.empty();
    return h("div", { class: "section" }, h("h3", {}, title), kids);
  }

  /* --- a small markdown reader --------------------------------------------
     Runbooks and playbooks are markdown under map/. Headings, lists, fenced
     code, quotes, pipe tables, rules, and the inline forms those files use:
     code, bold, italic, links, <sub>. Built as DOM, never as HTML text, so
     nothing in a file can become markup. */
  function inline(text) {
    const out = [];
    const re = /(`[^`]+`)|(\*\*[^*]+\*\*)|(\*[^*\s][^*]*\*)|(\[[^\]]+\]\([^)\s]+\))|(<https?:\/\/[^>\s]+>)|(<sub>[\s\S]*?<\/sub>)/g;
    let last = 0, m;
    while ((m = re.exec(text))) {
      if (m.index > last) out.push(text.slice(last, m.index));
      const s = m[0];
      if (m[1]) out.push(h("code", {}, s.slice(1, -1)));
      else if (m[2]) out.push(h("strong", {}, s.slice(2, -2)));
      else if (m[3]) out.push(h("em", {}, s.slice(1, -1)));
      else if (m[4]) {
        const lm = /^\[([^\]]+)\]\(([^)]+)\)$/.exec(s);
        if (/^https?:\/\//.test(lm[2])) out.push(h("a", { href: lm[2], target: "_blank", rel: "noopener" }, lm[1]));
        else out.push(lm[1], " ", h("code", {}, lm[2]));
      }
      else if (m[5]) { const u = s.slice(1, -1); out.push(h("a", { href: u, target: "_blank", rel: "noopener" }, u)); }
      else if (m[6]) out.push(h("span", { class: "faint" }, inline(s.slice(5, -6))));
      last = m.index + s.length;
    }
    if (last < text.length) out.push(text.slice(last));
    return out;
  }

  function markdown(text) {
    const root = h("div", { class: "md" });
    const lines = String(text || "").split("\n");
    let i = 0, para = [];
    const flush = () => {
      if (para.length) { root.append(h("p", {}, inline(para.join(" ")))); para = []; }
    };
    while (i < lines.length) {
      const line = lines[i];
      let m;
      if (/^\s*```/.test(line)) {
        flush();
        const code = [];
        i++;
        while (i < lines.length && !/^\s*```/.test(lines[i])) code.push(lines[i++]);
        i++;
        root.append(h("pre", {}, h("code", {}, code.join("\n"))));
      } else if ((m = /^(#{1,6})\s+(.*)$/.exec(line))) {
        flush();
        root.append(h(m[1].length <= 2 ? "h4" : "h5", {}, inline(m[2])));
        i++;
      } else if (/^\s*---+\s*$/.test(line)) {
        flush(); root.append(h("hr")); i++;
      } else if (/^\s*>/.test(line)) {
        flush();
        const q = [];
        while (i < lines.length && /^\s*>/.test(lines[i])) q.push(lines[i++].replace(/^\s*>\s?/, ""));
        root.append(h("blockquote", {}, [...markdown(q.join("\n")).childNodes]));
      } else if (/^\s*[-*]\s+/.test(line) || /^\s*\d+[.)]\s+/.test(line)) {
        flush();
        const ordered = /^\s*\d+[.)]\s+/.test(line);
        const list = h(ordered ? "ol" : "ul");
        while (i < lines.length && (ordered ? /^\s*\d+[.)]\s+/ : /^\s*[-*]\s+/).test(lines[i])) {
          let item = lines[i++].replace(ordered ? /^\s*\d+[.)]\s+/ : /^\s*[-*]\s+/, "");
          while (i < lines.length && /^\s{2,}\S/.test(lines[i]) && !/^\s*[-*]\s+/.test(lines[i])) item += " " + lines[i++].trim();
          list.append(h("li", {}, inline(item)));
        }
        root.append(list);
      } else if (/^\s*\|/.test(line)) {
        flush();
        const rows = [];
        while (i < lines.length && /^\s*\|/.test(lines[i])) rows.push(lines[i++]);
        const cells = r => r.trim().replace(/^\||\|$/g, "").split("|").map(c => c.trim());
        const t = h("table", { class: "t" });
        const body = rows.filter(r => !/^\s*\|?\s*:?-{2,}/.test(r));
        if (body.length) {
          t.append(h("thead", {}, h("tr", {}, cells(body[0]).map(c => h("th", { scope: "col" }, inline(c))))));
          t.append(h("tbody", {}, body.slice(1).map(r => h("tr", {}, cells(r).map(c => h("td", {}, inline(c)))))));
        }
        root.append(h("div", { class: "scroll" }, t));
      } else if (/^\s*$/.test(line)) {
        flush(); i++;
      } else {
        para.push(line.trim()); i++;
      }
    }
    flush();
    return root;
  }

  /* --- the table ---------------------------------------------------------- */
  function drawTable(el, view) {
    const c = view.counts || {};
    el.append(h("p", { class: "count" },
      c.repos + " repos", c.private ? " · " + c.private + " private" : null,
      " · " + c.edges + " edges", " · " + c.deployed + " seen live", " · " + c.notes + " notes"));

    const cols = [
      { key: "name", label: "repo", render: r => h("span", { class: "name" },
          h("a", { href: repoHref(r.name) }, r.name),
          r.private ? h("span", { class: "tag" }, "private") : null) },
      { key: "language", label: "language" },
      { key: "frameworks", label: "framework", render: r => r.frameworks.join(", "), sort: r => r.frameworks.join(", ") || null },
      { key: "runtime", label: "runtime" },
      { key: "package_manager", label: "package manager" },
      { key: "edge_count", label: "edges", num: true },
      { key: "pushed_at", label: "last push", render: r => r.pushed_at ? h("span", { title: web.day(r.pushed_at) }, web.age(r.pushed_at) + " ago") : "",
        sort: r => r.pushed_at ? -Date.parse(r.pushed_at) : null },
      { key: "deploys_to", label: "deploys to", render: r => r.deploys_to.map(d => d.peer).join(", "), sort: r => r.deploys_to.map(d => d.peer).join(", ") || null },
      { key: "live", label: "live", render: r => r.live.map(d => h("span", { class: "live" }, d.provider + " ", h("span", { class: "muted" }, d.state || "seen"))),
        sort: r => r.live.map(d => d.provider + " " + (d.state || "")).join(", ") || null },
      { key: "note_count", label: "notes", num: true },
    ];

    const holder = h("div");
    let shown = h("p", { class: "count faint shown" });
    el.append(shown, holder);
    const hay = r => [r.name, r.description, r.language, r.frameworks.join(" "), r.runtime, r.package_manager,
      r.topics.join(" "), r.deploys_to.map(d => d.peer).join(" "), r.live.map(d => d.provider + " " + d.name).join(" ")]
      .filter(Boolean).join(" ").toLowerCase();

    /* Redrawing for a search keeps the sort the reader chose: the table
       reports every change and is given it back on the next draw. */
    let sort = null;
    const draw = q => {
      const rows = q ? view.repos.filter(r => hay(r).includes(q)) : view.repos;
      const t = web.table(cols, rows, { sort, onSort: s => { sort = s; }, label: "repos" });
      holder.replaceChildren(rows.length ? t : h("p", { class: "empty" }, "no repo matches — nothing found for ", h("code", {}, q)));
      shown.replaceWith(shown = web.shownLine(rows.length, view.repos.length, !!q, () => web.clearSearch()));
    };
    draw(web.query());
    web.onSearch(draw);
  }

  /* --- the page ------------------------------------------------------------ */
  function drawRepo(el, view, all, name) {
    const r = view.repos.find(x => x.name === name);
    el.append(h("p", { class: "crumb" }, h("a", { href: "#/repos" }, "repos"), " / ", name));
    if (!r) {
      el.append(h("h2", {}, name), h("p", { class: "muted" }, "No repo called ", h("code", {}, name), " in the map."));
      return;
    }
    el.append(h("h2", {}, r.name, r.private ? h("span", { class: "tag" }, "private") : null));
    el.append(h("div", { class: "head" },
      r.language ? h("span", {}, r.language) : null,
      r.frameworks.length ? h("span", {}, r.frameworks.join(", ")) : null,
      r.pushed_at ? h("span", { title: r.pushed_at }, "pushed " + web.day(r.pushed_at)) : null,
      r.url ? h("a", { href: r.url, target: "_blank", rel: "noopener" }, "open on GitHub") : null));
    el.append(web.freshness(view));

    /* what it is */
    el.append(section("What it is",
      r.description ? h("p", {}, r.description) : null,
      r.topics.length ? h("p", { class: "muted" }, "topics: ", r.topics.join(", ")) : null,
      r.agent_docs.length ? h("p", {}, "already written for agents: ",
        r.agent_docs.map((d, i) => [i ? ", " : null,
          r.url ? h("a", { href: r.url + "/blob/" + r.default_branch + "/" + d, target: "_blank", rel: "noopener", class: "mono" }, d) : h("code", {}, d)])) : null));

    /* how to run it */
    const runLine = [r.runtime, r.package_manager, r.procfile.length ? "Procfile: " + r.procfile.join(", ") : null].filter(Boolean);
    el.append(section("How to run it",
      runLine.length ? h("p", { class: "muted" }, runLine.join(" · ")) : null,
      r.scripts.length ? h("ul", { class: "kv" }, r.scripts.map(s => h("li", {}, h("code", { class: "k" }, s.name), h("code", {}, s.command)))) : null));

    /* what it serves */
    el.append(section("What it serves",
      r.serves.length ? h("p", {}, r.serves.map((s, i) => [i ? ", " : null, h("code", {}, s)])) : null,
      r.routes.length ? h("ul", { class: "links" }, r.routes.map(x => h("li", {},
        h("span", { class: "peer mono" }, x.route),
        x.at ? web.evidence({ kind: "extracted", at: x.at, repo: r.name }) : null))) : null));

    /* what it reads */
    el.append(section("What it reads",
      r.env.length ? h("ul", { class: "env" }, r.env.map(v => h("li", {},
        h("code", {}, v.name),
        v.shared_with.length ? h("span", { class: "faint" }, "also read by ",
          v.shared_with.map((p, i) => [i ? ", " : null, h("a", { href: repoHref(p) }, p)]), " ",
          h("span", { class: "tag inferred" }, "shares-config")) : null))) : null));

    /* what it talks to — both directions of every edge, grouped by kind, with
       the inferred ones switchable off (rule 2). */
    const talk = r.edges.filter(e => TALK_ORDER.includes(e.kind));
    if (talk.length) {
      const hasInferred = talk.some(e => e.confidence === "inferred");
      const list = h("ul", { class: "links" });
      const toggle = h("button", { type: "button", class: "chip", "aria-pressed": "true", onclick: () => {
        const on = toggle.getAttribute("aria-pressed") !== "true";
        toggle.setAttribute("aria-pressed", on ? "true" : "false");
        toggle.classList.toggle("off", !on);
        for (const li of list.querySelectorAll("li[data-inferred]")) li.hidden = !on;
      } }, h("span", { class: "dot" }), "show inferred");
      for (const kind of TALK_ORDER) {
        for (const dir of ["out", "in"]) {
          const group = talk.filter(e => e.kind === kind && e.dir === dir);
          if (!group.length) continue;
          const label = LABEL[kind] ? LABEL[kind][dir === "out" ? 0 : 1] : kind;
          for (const e of group) {
            list.append(h("li", { dataset: e.confidence === "inferred" ? { inferred: "" } : null },
              h("span", { class: "peer" }, h("span", { class: "muted" }, label + " "), peerEl(e),
                e.signal ? h("span", { class: "faint" }, " via " + e.signal) : null),
              edgeEvidence(e, r.name)));
          }
        }
      }
      el.append(section("What it talks to",
        hasInferred ? h("div", { class: "controls" }, toggle) : null,
        list,
        h("p", { class: "muted small" }, "What is not here was not found in committed configuration. That is not proof it stands alone — runtime wiring leaves no trace in a repository.")));
    } else {
      el.append(section("What it talks to",
        h("p", { class: "muted" }, "Nothing links this repo to another in committed configuration. That is not proof it stands alone — runtime wiring leaves no trace in a repository.")));
    }

    /* where it ships */
    const live = view.sources && view.sources.live || {};
    const stale = live.generated && isStale(live.generated);
    const deployWorkflows = r.workflows.filter(w => w.deploys);
    el.append(section("Where it ships",
      r.deploys_to.length ? h("ul", { class: "links" }, r.deploys_to.map(e => h("li", {},
        h("span", { class: "peer" }, h("span", { class: "muted" }, "deploys to "), peerEl(e)),
        edgeEvidence(e, r.name)))) : null,
      deployWorkflows.length ? h("ul", { class: "links" }, deployWorkflows.map(w => h("li", {},
        h("span", { class: "peer" }, h("span", { class: "muted" }, "workflow "), w.name || w.file,
          w.on && w.on.length ? h("span", { class: "faint" }, " on " + w.on.join(", ")) : null,
          w.environment ? h("span", { class: "faint" }, " · " + w.environment) : null),
        web.evidence({ kind: "extracted", at: w.file, repo: r.name })))) : null,
      r.live.length ? h("ul", { class: "links" }, r.live.map(d => h("li", {},
        h("span", { class: "peer" }, h("span", { class: "muted" }, "seen on "), d.provider + " ", h("code", {}, d.name),
          d.state ? h("span", { class: stale ? "stale" : "muted" }, " · " + d.state + (stale ? " (read " + web.age(live.generated) + " ago, not since)" : "")) : null,
          d.account ? h("span", { class: "faint" }, " · " + d.account) : null),
        (d.urls || []).length ? h("span", { class: "urls" }, d.urls.map((u, i) => [i ? " " : null, h("a", { href: "https://" + u, target: "_blank", rel: "noopener" }, u)])) : null,
        web.evidence({ kind: "reading", command: d.source || "orgami live", date: d.updated || live.generated })))) : null,
      r.live.length ? h("p", { class: "muted small" }, "Read from the providers, not from the code — it expires.") : null));

    /* who it changes with */
    if (r.coupling.length) {
      const coupling = view.sources && view.sources.coupling || {};
      el.append(section("Who it changes with",
        h("p", { class: "muted small" }, "Correlation, not dependency: counted out of merged pull requests",
          coupling.weeks_observed ? " over " + coupling.weeks_observed + " weeks" : null,
          coupling.generated ? " (read " + web.day(coupling.generated) + ")" : null, ". A hint about blast radius."),
        web.table([
          { key: "other", label: "repo", render: p => h("a", { href: repoHref(p.other) }, p.other) },
          { key: "weeks", label: "same week", num: true },
          { key: "days", label: "same day", num: true },
          { key: "authors", label: "by", render: p => p.authors.join(", "), sort: p => p.authors.join(", ") },
          { key: "ev", label: "", render: () => web.evidence({ kind: "inferred", at: "merged pull requests" }) },
        ], r.coupling)));
    }

    /* the team's notes */
    if (r.notes.length) {
      el.append(section("Notes",
        h("ul", { class: "notes" }, r.notes.map(n => h("li", { class: n.archived || n.superseded_by ? "old" : null },
          h("div", { class: "body" }, String(n.body || "").replace(/<!--[\s\S]*?-->/g, "").trim().split(/\n{2,}/).map(p => h("p", {}, inline(p.replace(/\n/g, " "))))),
          h("div", { class: "meta" },
            web.evidence({ kind: "human", author: n.author, date: n.date }),
            n.date ? h("span", { class: "faint" }, web.age(n.date) + " ago") : null,
            (n.tags || []).map(t => h("span", { class: "tag" }, t)),
            n.topic ? h("span", { class: "faint" }, "topic " + n.topic) : null,
            n.superseded_by ? h("span", { class: "faint" }, "superseded by ", h("code", {}, n.superseded_by)) : null,
            n.supersedes ? h("span", { class: "faint" }, "supersedes ", h("code", {}, n.supersedes)) : null,
            n.archived ? h("span", { class: "tag" }, "archived") : null))))));
    }

    /* runbook */
    if (r.runbook) {
      el.append(section("Runbook",
        h("p", { class: "muted small" }, h("code", {}, "map/runbooks/" + r.name + ".md"), " — derived from the scan; nothing in it was written by a model."),
        h("div", { class: "doc" }, markdown(r.runbook))));
    }

    /* playbooks */
    if (r.playbooks.length) {
      el.append(section("Playbooks", r.playbooks.map(p => h("div", { class: "playbook" },
        h("h4", {}, p.topic.replace(/-/g, " ")),
        h("p", { class: "muted small" }, web.evidence({ kind: "model" }), " ",
          h("code", {}, "orgami playbook " + r.name + " --topic " + p.topic), " rewrites it."),
        h("div", { class: "doc" }, markdown(p.text))))));
    }

    /* write a note */
    el.append(section("Write a note",
      h("pre", {}, "orgami note --repo " + r.name + ' "…"'),
      h("p", { class: "muted small" }, "The page changes nothing; that line does, and the next render shows it here.")));
  }

  web.register({
    id: "repos",
    title: "Repos",
    needs: ["map/repos.json", "map/graph.json", "map/coupling.json", "map/live.json", "notes/", "map/runbooks/", "map/playbooks/"],
    render(el, view, all, route) {
      if (route.parts.length) { drawRepo(el, view, all, route.parts[0]); return; }
      el.append(h("h2", {}, "Repos"));
      el.append(web.freshness(view));
      drawTable(el, view);
    },
  });
})();
