"use strict";
/* The memory view: what the team knows. Four tabs under one id:
     #/memory                     the notes, newest first
     #/memory/notes[/<id>]        the same, with one note opened
     #/memory/decisions           one section per week, each bullet's pull
                                  request a link only where it is one
     #/memory/playbooks[/<file>]  one row per playbook; the page draws the
                                  procedure as what a model wrote and the
                                  evidence beneath it, holes highlighted
     #/memory/runbooks[/<repo>]   the index; the page with the note tags as
                                  anchors where the section exists
   Every figure shown as the org's comes from 70-memory.jq; the page only
   counts the rows it is filtering. Nothing here reads a clock but web.age,
   which is the reader's, for "3 weeks ago". */
(() => {
  const { h } = web;
  const enc = s => encodeURIComponent(s);
  const TABS = [
    { id: "notes", title: "Notes" },
    { id: "decisions", title: "Decisions" },
    { id: "playbooks", title: "Playbooks" },
    { id: "runbooks", title: "Runbooks" },
  ];
  const href = (...parts) => "#/memory" + parts.map(p => "/" + enc(p)).join("");

  /* A section: heading and body, or nothing when the body is empty. */
  function section(title, ...body) {
    const kids = body.flat().filter(Boolean);
    if (!kids.length) return web.empty();
    return h("div", { class: "section" }, h("h3", {}, title), kids);
  }

  /* --- a small markdown reader --------------------------------------------
     Notes, playbooks and runbooks are markdown under notes/ and map/. The
     forms those files use: headings, lists, fenced code, quotes, pipe
     tables, rules, and inline code, bold, italic, links and <sub>. Built as
     DOM, never as HTML text, so nothing in a file can become markup. A
     heading gets an id from its text, which is what a runbook anchor jumps
     to; a line that is a hole the playbook left is marked, not hidden. */
  const slug = s => String(s).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  const TODO = /TODO — the evidence does not say how/;

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

  function markdown(text, opts) {
    opts = opts || {};
    const root = h("div", { class: "md" });
    const lines = String(text || "").split("\n");
    let i = 0, para = [];
    const block = (tag, kids, src) => {
      const attrs = {};
      if (opts.holes && TODO.test(src)) attrs.class = "todo";
      return h(tag, attrs, kids);
    };
    const flush = () => {
      if (para.length) { const src = para.join(" "); root.append(block("p", inline(src), src)); para = []; }
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
        const attrs = opts.ids ? { id: opts.ids + slug(m[2]) } : {};
        root.append(h(m[1].length <= 2 ? "h4" : "h5", attrs, inline(m[2])));
        i++;
      } else if (/^\s*---+\s*$/.test(line)) {
        flush(); root.append(h("hr")); i++;
      } else if (/^\s*>/.test(line)) {
        flush();
        const q = [];
        while (i < lines.length && /^\s*>/.test(lines[i])) q.push(lines[i++].replace(/^\s*>\s?/, ""));
        root.append(h("blockquote", {}, [...markdown(q.join("\n"), opts).childNodes]));
      } else if (/^\s*[-*]\s+/.test(line) || /^\s*\d+[.)]\s+/.test(line)) {
        flush();
        const ordered = /^\s*\d+[.)]\s+/.test(line);
        const list = h(ordered ? "ol" : "ul");
        while (i < lines.length && (ordered ? /^\s*\d+[.)]\s+/ : /^\s*[-*]\s+/).test(lines[i])) {
          let item = lines[i++].replace(ordered ? /^\s*\d+[.)]\s+/ : /^\s*[-*]\s+/, "");
          while (i < lines.length && /^\s{2,}\S/.test(lines[i]) && !/^\s*[-*]\s+/.test(lines[i])) item += " " + lines[i++].trim();
          list.append(block("li", inline(item), item));
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

  /* A note's body: paragraphs, with the inline forms notes use. */
  const body = text => h("div", { class: "body" },
    String(text || "").trim().split(/\n{2,}/).map(p => h("p", {}, inline(p.replace(/\n/g, " ")))));

  /* A copyable command, and the line every action on this page comes down
     to: the page changes nothing, that line does (rule 8). */
  const command = (cmd, note) => h("div", { class: "cmd" }, h("pre", {}, cmd), note ? h("p", { class: "muted small" }, note) : null);

  /* --- tabs ------------------------------------------------------------------ */
  function drawTabs(el, view, current) {
    const counts = view.counts || {};
    const nav = h("nav", { class: "tabs", "aria-label": "memory" });
    for (const t of TABS) {
      const src = view.sources && view.sources[t.id];
      /* A tab with nothing behind it is not drawn; its route still answers,
         with the command that fills it. */
      if (!src || src.missing) continue;
      nav.append(h("a", { href: href(t.id), "aria-current": current === t.id ? "page" : null },
        t.title, " ", h("span", { class: "n" }, String(counts[t.id] ?? ""))));
    }
    el.append(nav);
  }

  /* The rule-4 line for one of the four sources, drawn under the tab. */
  const fresh = (view, id) => web.freshness(view.sources && view.sources[id] || { missing: "orgami " + id });

  /* --- notes ------------------------------------------------------------------ */
  function noteItem(n, opened, depth) {
    const li = h("li", { class: "note" + (depth ? " old" : "") + (opened === n.id ? " opened" : ""), id: depth ? null : "note-" + n.id, dataset: { id: n.id } });
    li.append(body(n.body));
    const meta = h("div", { class: "meta" },
      web.evidence({ kind: "human", author: n.author, date: n.date }),
      n.date ? h("span", { class: "faint", title: n.date }, web.age(n.date) + " ago") : null,
      n.repo ? h("a", { class: "repo", href: "#/repos/" + enc(n.repo) }, n.repo) : null,
      (n.tags || []).map(t => h("span", { class: "tag" }, t)),
      n.topic ? h("span", { class: "faint" }, "topic ", h("code", {}, n.topic)) : null,
      n.answers ? h("span", { class: "faint" }, "answers ", h("a", { href: "#/vendors", class: "mono" }, n.answers)) : null,
      n.archived ? h("span", { class: "tag" }, "archived") : null,
      depth ? h("span", { class: "faint" }, "superseded") : null,
      !depth ? h("a", { class: "faint id", href: href("notes", n.id), title: n.id }, "#") : null);
    li.append(meta);
    /* What this note replaced, folded under it: the chain, newest first,
       each one under the one that superseded it. */
    if (n.replaced && n.replaced.length) {
      const d = h("details", { class: "replaced", open: opened === n.id ? true : null },
        h("summary", {}, "replaced " + n.replaced.length + (n.replaced.length === 1 ? " note" : " notes")),
        h("ul", { class: "notes" }, n.replaced.map(r => noteItem(r, opened, (depth || 0) + 1))));
      li.append(d);
    }
    if (!depth) li.append(command(n.supersede_command));
    return li;
  }

  function drawNotes(el, view, opened) {
    const N = view.notes;
    el.append(fresh(view, "notes"));
    if (!N) return;
    const c = N.counts || {};
    el.append(h("p", { class: "count" },
      c.listed + (c.listed === 1 ? " note" : " notes"),
      c.replaced ? " · " + c.replaced + " replaced, folded under what replaced " + (c.replaced === 1 ? "it" : "them") : null,
      c.archived ? " · " + c.archived + " archived" : null,
      c.answers ? " · " + c.answers + (c.answers === 1 ? " answers" : " answer") + " an advisory" : null));

    /* Filters: one chip per tag and per repo, counted in jq over the notes
       listed; archived notes are reachable through their own chip and never
       counted into the tallies. */
    const state = { tag: null, repo: null, archived: false };
    const chip = (label, count, get, set) => web.chip(label, count, false, () => { set(get() ? null : label); redraw(); });
    const tagChips = (N.tags || []).map(t => chip(t.tag, t.count, () => state.tag === t.tag, v => { state.tag = v; }));
    const repoChips = (N.repos || []).map(r => chip(r.repo, r.count, () => state.repo === r.repo, v => { state.repo = v; }));
    const archChip = c.archived ? web.chip("archived", c.archived, false, () => { state.archived = !state.archived; redraw(); }) : null;
    const controls = h("div", { class: "controls" },
      tagChips.length ? h("div", { class: "row" }, h("span", { class: "label" }, "tag"), tagChips) : null,
      repoChips.length ? h("div", { class: "row" }, h("span", { class: "label" }, "repo"), repoChips) : null,
      archChip ? h("div", { class: "row" }, h("span", { class: "label" }, "also"), archChip) : null);
    el.append(controls);

    let shown = h("p", { class: "count faint shown" });
    const list = h("ul", { class: "notes top" });
    const arch = h("div", { class: "archived" });
    el.append(shown, list, arch);

    const hay = n => [n.body, n.author, n.repo, (n.tags || []).join(" "), n.topic, n.id,
      ...(n.replaced || []).map(r => r.body + " " + r.author)].filter(Boolean).join(" ").toLowerCase();
    const matches = (n, q) => (!state.tag || (n.tags || []).includes(state.tag)) &&
      (!state.repo || n.repo === state.repo) && (!q || hay(n).includes(q));

    const redraw = () => {
      const q = web.query();
      for (const b of tagChips) b.setAttribute("aria-pressed", state.tag === b.dataset.label ? "true" : "false");
      for (const b of repoChips) b.setAttribute("aria-pressed", state.repo === b.dataset.label ? "true" : "false");
      if (archChip) archChip.setAttribute("aria-pressed", state.archived ? "true" : "false");
      const rows = N.list.filter(n => matches(n, q));
      list.replaceChildren(...rows.map(n => noteItem(n, opened, 0)));
      if (!rows.length) list.append(h("li", { class: "empty" }, h("p", { class: "empty" }, "no note matches", q ? [" — nothing found for ", h("code", {}, q)] : null)));
      const filtered = !!(q || state.tag || state.repo);
      shown.replaceWith(shown = web.shownLine(rows.length, N.list.length, filtered, () => { state.tag = null; state.repo = null; web.clearSearch(); redraw(); }));
      arch.replaceChildren();
      if (state.archived && N.archived.length) {
        const arows = N.archived.filter(n => matches(n, q));
        arch.append(h("h3", {}, "Archived"),
          h("p", { class: "muted small" }, "Moved out of the shared repository by ", h("code", {}, "orgami prune"), ". Kept on disk, listed here only when asked."),
          h("ul", { class: "notes top" }, arows.map(n => noteItem(n, opened, 0))));
        if (!arows.length) arch.append(h("p", { class: "empty" }, "no archived note matches"));
      }
    };
    /* A note opened by its id is listed even when it is archived. */
    if (opened && N.archived.some(n => n.id === opened)) state.archived = true;
    redraw();
    web.onSearch(redraw);
    if (opened) {
      const target = el.querySelector("#note-" + CSS.escape(opened));
      if (target) target.scrollIntoView({ block: "start" });
      else el.append(h("p", { class: "muted" }, "No note called ", h("code", {}, opened), " is on disk."));
    }

    el.append(section("Write a note",
      command(N.note_command, "The page changes nothing; that line does, and the next render shows it here."),
      h("p", { class: "muted small" }, "What is here is what was written and screened at the time: nothing from ", h("code", {}, "notes/draft/"), " is on this page.")));
  }

  /* --- decisions ---------------------------------------------------------------- */
  function drawDecisions(el, view) {
    const D = view.decisions;
    el.append(fresh(view, "decisions"));
    if (!D) return;
    const c = D.counts || {};
    el.append(h("p", { class: "count" },
      c.decisions + (c.decisions === 1 ? " decision" : " decisions"), " in ", c.weeks + (c.weeks === 1 ? " week" : " weeks"),
      " · " + c.linked + " with a pull request to open"));
    el.append(h("p", { class: "muted small" },
      web.evidence({ kind: "model" }),
      " Pulled out of merged pull requests by a model, one fragment per week. A reference is a link only where the repository is in the map; check the pull request before relying on the sentence."));

    const holder = h("div");
    const shown = h("p", { class: "count faint" });
    el.append(shown, holder);
    const draw = q => {
      holder.replaceChildren();
      let n = 0, all = 0;
      for (const w of D.weeks) {
        const bullets = w.bullets.filter(b => { all++; return !q || b.text.toLowerCase().includes(q); });
        n += bullets.length;
        if (!bullets.length) continue;
        holder.append(h("div", { class: "week", id: "week-" + w.week },
          h("h3", {}, w.week, h("span", { class: "faint" }, " · ", h("code", {}, w.file)),
            w.generated ? h("span", { class: "faint" }, " · week ending " + web.day(w.generated)) : null),
          h("ul", { class: "decisions" }, bullets.map(b => h("li", {},
            b.parts.map(p => p.url
              ? h("a", { href: p.url, target: "_blank", rel: "noopener", class: "pr" }, p.text)
              : inline(p.text)))))));
      }
      if (!n) holder.append(h("p", { class: "empty" }, "no decision matches", q ? [" — nothing found for ", h("code", {}, q)] : null));
      shown.textContent = q ? n + " of " + all + " shown" : "";
    };
    draw(web.query());
    web.onSearch(draw);
    el.append(section("The record",
      h("p", { class: "muted small" }, D.page ? [h("code", {}, D.page), " holds every week, newest first, assembled by "] : ["The weeks are assembled into ", h("code", {}, "map/DECISIONS.md"), " by "],
        h("code", {}, "orgami doc"), ". A week's fragment is written by ", h("code", {}, "orgami report"), " and only ever added to.")));
  }

  /* --- playbooks --------------------------------------------------------------- */
  function drawPlaybooks(el, view, opened) {
    const P = view.playbooks;
    el.append(fresh(view, "playbooks"));
    if (!P) return;
    if (opened) { drawPlaybook(el, P, opened); return; }
    const c = P.counts || {};
    el.append(h("p", { class: "count" },
      c.playbooks + (c.playbooks === 1 ? " playbook" : " playbooks"), " in ", c.repos + (c.repos === 1 ? " repo" : " repos"),
      P.index && !P.index.missing ? " · " + c.instances + " recorded instances" : null,
      c.todos ? " · " + c.todos + (c.todos === 1 ? " hole" : " holes") + " the evidence does not fill" : null));
    if (P.index && P.index.missing) {
      el.append(h("p", { class: "muted small" }, "No ", h("code", {}, "map/PLAYBOOKS.md"), " — the instance counts come from that index, and ", h("code", {}, P.index.missing), " writes it."));
    }
    const cols = [
      { key: "repo", label: "repo", render: p => h("a", { href: "#/repos/" + enc(p.repo) }, p.repo) },
      { key: "title", label: "topic", render: p => h("a", { class: "open", href: href("playbooks", p.repo + "--" + p.topic) }, p.title) },
      { key: "instances", label: "instances", num: true, render: p => p.instances == null ? h("span", { class: "faint" }, "not indexed") : String(p.instances) },
      { key: "written", label: "written", render: p => p.written ? h("span", { title: p.written }, web.day(p.written)) : "" },
      { key: "model", label: "by", render: p => p.model ? h("span", {}, h("code", {}, p.model), " ", h("span", { class: "tag model" }, "model")) : "" },
      { key: "todos", label: "holes", num: true },
    ];
    const holder = h("div");
    const shown = h("p", { class: "count faint" });
    el.append(shown, holder);
    const hay = p => [p.repo, p.title, p.topic, p.prose].filter(Boolean).join(" ").toLowerCase();
    const draw = q => {
      const rows = q ? P.list.filter(p => hay(p).includes(q)) : P.list;
      holder.replaceChildren(rows.length ? web.table(cols, rows) : h("p", { class: "empty" }, "no playbook matches", q ? [" — nothing found for ", h("code", {}, q)] : null));
      shown.textContent = q ? rows.length + " of " + P.list.length + " shown" : "";
    };
    draw(web.query());
    web.onSearch(draw);
    el.append(section("Record an instance",
      command('orgami note --repo <repo> --tag pattern --topic <topic> "what the shape was, and what worked"',
        "Two instances under one topic write the playbook; every one after rewrites it.")));
  }

  function drawPlaybook(el, P, key) {
    const p = P.list.find(x => x.repo + "--" + x.topic === key || x.file === "map/playbooks/" + key + ".md");
    el.append(h("p", { class: "crumb" }, h("a", { href: href("playbooks") }, "playbooks"), " / ", key));
    if (!p) { el.append(h("p", { class: "muted" }, "No playbook called ", h("code", {}, key), " under map/playbooks/.")); return; }
    el.append(h("h3", { class: "title" }, h("a", { href: "#/repos/" + enc(p.repo) }, p.repo), " — ", p.title));
    el.append(h("div", { class: "head" },
      web.evidence({ kind: "model" }),
      p.model ? h("span", {}, "by ", h("code", {}, p.model)) : null,
      p.written ? h("span", {}, "on " + p.written) : null,
      p.instances != null ? h("span", {}, p.instances + (p.instances === 1 ? " instance" : " instances") + " in the index") : h("span", { class: "faint" }, "not in map/PLAYBOOKS.md"),
      p.written_from != null && p.written_from !== p.instances ? h("span", { class: "stale" }, "written from " + p.written_from + " — an instance landed since; ", h("code", {}, p.rewrite_command), " rewrites it") : null,
      p.todos ? h("span", { class: "hole" }, p.todos + (p.todos === 1 ? " hole" : " holes") + " left open, marked below") : null));
    el.append(h("p", { class: "muted small" }, "Unlike the rest of the map the prose was not derived: the evidence it was written from is printed beneath, and disagreement between the two means the evidence is right. A line reading ", h("code", {}, "TODO — the evidence does not say how"), " is a hole the model left on purpose, shown as one."));
    el.append(h("div", { class: "doc prose" }, markdown(p.prose, { holes: true, ids: "pb-" })));
    if (p.evidence) {
      el.append(section("What this was written from",
        h("p", { class: "muted small" }, "Printed in full, as the model was handed it: the instances, the standing notes on the same repository, the pull requests that look like the same work, and the commands the repository has."),
        h("pre", { class: "evidence" }, p.evidence)));
    } else {
      el.append(section("What this was written from",
        h("p", { class: "empty" }, "This file carries no evidence block — nothing beneath the prose to check it against.")));
    }
    el.append(section("Wrong, or out of date?",
      command(p.record_command, "records the next instance, and"),
      command(p.rewrite_command, "rewrites this from what is on disk.")));
  }

  /* --- runbooks ----------------------------------------------------------------- */
  function drawRunbooks(el, view, opened) {
    const R = view.runbooks;
    el.append(fresh(view, "runbooks"));
    if (!R) return;
    if (opened) { drawRunbook(el, R, opened); return; }
    const c = R.counts || {};
    el.append(h("p", { class: "count" },
      c.runbooks + (c.runbooks === 1 ? " runbook" : " runbooks"),
      " · " + c.with_notes + " with a section the team wrote"));
    el.append(h("p", { class: "muted small" }, "Derived from the scan and quoted from the notes; no model writes any of it. A note tagged ",
      R.tags.map((t, i) => [i ? ", " : null, h("code", {}, t.tag)]), " lands under its own heading, and those headings are the anchors on the right."));
    const cols = [
      { key: "repo", label: "repo", render: r => h("span", { class: "name" },
          h("a", { class: "open", href: href("runbooks", r.repo) }, r.repo),
          !r.in_map ? h("span", { class: "tag" }, "not in the map") : null) },
      { key: "summary", label: "what it is", render: r => r.summary || "" },
      { key: "scan", label: "scan of", render: r => r.scan ? h("span", { title: r.scan }, r.scan) : "" },
      { key: "sections", label: "sections", num: true, render: r => String(r.sections.length), sort: r => r.sections.length },
      { key: "anchors", label: "from the team", render: r => r.anchors.map(a => h("a", { class: "chip anchor", href: href("runbooks", r.repo) + "#" + a.tag }, a.tag)),
        sort: r => r.anchors.map(a => a.tag).join(",") || null },
    ];
    const holder = h("div");
    const shown = h("p", { class: "count faint" });
    el.append(shown, holder);
    const hay = r => [r.repo, r.summary, r.text].filter(Boolean).join(" ").toLowerCase();
    const draw = q => {
      const rows = q ? R.list.filter(r => hay(r).includes(q)) : R.list;
      holder.replaceChildren(rows.length ? web.table(cols, rows) : h("p", { class: "empty" }, "no runbook matches", q ? [" — nothing found for ", h("code", {}, q)] : null));
      shown.textContent = q ? rows.length + " of " + R.list.length + " shown" : "";
    };
    draw(web.query());
    web.onSearch(draw);
    if (R.org_page) el.append(h("p", { class: "muted small" }, "The org's own page, ", h("code", {}, R.org_page), ", is beside these under map/."));
    el.append(section("Add to one",
      command('orgami note --repo <repo> --tag <setup|deploy|rollback|incident|alert|gotcha|oncall> "…"',
        "A tagged note is quoted into the runbook's section on the next orgami doc, with its author and date.")));
  }

  function drawRunbook(el, R, key) {
    /* "<repo>#<tag>" opens the page scrolled to that tag's section. */
    const [repo, tag] = key.split("#");
    const r = R.list.find(x => x.repo === repo);
    el.append(h("p", { class: "crumb" }, h("a", { href: href("runbooks") }, "runbooks"), " / ", repo));
    if (!r) { el.append(h("p", { class: "muted" }, "No runbook for ", h("code", {}, repo), " under map/runbooks/.")); return; }
    const idOf = a => "rb-" + slug(a.heading);
    const jump = a => ev => {
      ev.preventDefault();
      const t = el.querySelector("#" + idOf(a));
      if (t) { t.scrollIntoView({ block: "start" }); t.setAttribute("tabindex", "-1"); t.focus(); }
    };
    el.append(h("div", { class: "head" },
      web.evidence({ kind: "extracted", at: r.file }),
      r.scan ? h("span", {}, "derived from the scan of " + r.scan + "; nothing here was written by a model") : null,
      r.in_map ? h("a", { href: "#/repos/" + enc(r.repo) }, "the repo's page") : h("span", { class: "tag" }, "not in the map")));
    if (r.anchors.length) {
      el.append(h("div", { class: "anchors", role: "navigation", "aria-label": "sections the team wrote" },
        h("span", { class: "label" }, "from the team"),
        r.anchors.map(a => h("a", { class: "chip anchor", href: href("runbooks", r.repo) + "#" + a.tag, onclick: jump(a) }, a.tag, h("span", { class: "faint" }, a.heading)))));
    } else {
      el.append(h("p", { class: "muted small" }, "No section here was written by the team yet — a note tagged ",
        R.tags.map((t, i) => [i ? ", " : null, h("code", {}, t.tag)]), " on ", h("code", {}, r.repo), " would be quoted into one."));
    }
    el.append(h("div", { class: "doc" }, markdown(r.text, { ids: "rb-" })));
    if (tag) {
      const a = r.anchors.find(x => x.tag === tag);
      const t = a && el.querySelector("#" + idOf(a));
      if (t) t.scrollIntoView({ block: "start" });
    }
  }

  web.register({
    id: "memory",
    title: "Memory",
    needs: ["notes/", "map/decisions/", "map/playbooks/", "map/runbooks/", "map/PLAYBOOKS.md"],
    render(el, view, all, route) {
      const tab = TABS.some(t => t.id === route.parts[0]) ? route.parts[0] : "notes";
      const rest = route.parts.slice(1).join("/");
      el.append(h("h2", {}, "Memory"));
      el.append(web.freshness(view));
      drawTabs(el, view, tab);
      const pane = h("div", { class: "pane", dataset: { tab } });
      el.append(pane);
      if (tab === "notes") drawNotes(pane, view, rest || null);
      else if (tab === "decisions") drawDecisions(pane, view);
      else if (tab === "playbooks") drawPlaybooks(pane, view, rest || null);
      else drawRunbooks(pane, view, rest || null);
    },
  });
})();
