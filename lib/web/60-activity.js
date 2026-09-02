"use strict";
/* Activity: the weeks, the days, and the coupling.

   Nothing here counts. Every figure drawn is one lib/stats.jq or lib/daily.jq
   computed and lib/web/60-activity.jq handed over, and the one arithmetic the
   browser does is a bar's height as a share of the tallest. The recaps and
   digests are model prose, marked so, with the figures they were written from
   printed beneath. Coupling is correlation counted out of merged pull requests
   and is drawn as inferred, with a switch to hide it. */
(() => {
  const { h, frag, evidence, freshness, table, day } = web;

  const WEEK = /^\d{4}-W\d{2}$/;
  const DATE = /^\d{4}-\d{2}-\d{2}$/;
  const label = k => String(k).replace(/_/g, " ");
  const num = v => typeof v === "number" ? v.toLocaleString("en-US") : String(v ?? "");
  const repoLink = name => h("a", { href: "#/repos/" + encodeURIComponent(name) }, name);
  const weekHref = w => "#/activity/" + encodeURIComponent(w);

  /* --- markdown, the little the recaps and digests use -------------------
     Headings, lists, links, code, bold, rules. Built as DOM, never as HTML:
     an HTML tag in the text is dropped, a comment is dropped, and a link is
     kept only when it is http(s). A recap's own footer is text like any other. */
  function inline(s) {
    const out = frag();
    const re = /(`[^`]*`)|\[([^\]]+)\]\(([^)\s]+)\)|\*\*([^*]+)\*\*/g;
    let last = 0, m;
    const text = t => t.replace(/<\/?[a-z][^>]*>/gi, "");
    while ((m = re.exec(s))) {
      if (m.index > last) out.append(text(s.slice(last, m.index)));
      if (m[1]) out.append(h("code", {}, m[1].slice(1, -1)));
      else if (m[2]) {
        if (/^https?:\/\//.test(m[3])) out.append(h("a", { href: m[3], target: "_blank", rel: "noopener" }, m[2]));
        else out.append(text(m[2]));
      } else out.append(h("strong", {}, text(m[4])));
      last = re.lastIndex;
    }
    if (last < s.length) out.append(text(s.slice(last)));
    return out;
  }
  function markdown(src) {
    const root = h("div", { class: "md" });
    const lines = String(src || "").replace(/<!--[\s\S]*?-->/g, "").split("\n");
    let i = 0, para = [];
    const flush = () => { if (para.length) { root.append(h("p", {}, inline(para.join(" ")))); para = []; } };
    while (i < lines.length) {
      const l = lines[i];
      if (/^```/.test(l)) {
        flush();
        const code = [];
        i++;
        while (i < lines.length && !/^```/.test(lines[i])) code.push(lines[i++]);
        i++;
        root.append(h("pre", {}, h("code", {}, code.join("\n"))));
        continue;
      }
      let m;
      if ((m = /^(#{1,6})\s+(.*)$/.exec(l))) {
        flush();
        root.append(h("h" + Math.min(6, m[1].length + 3), {}, inline(m[2])));
      } else if (/^\s*(-{3,}|\*{3,})\s*$/.test(l)) {
        flush();
        root.append(h("hr"));
      } else if (/^\s*[-*]\s+/.test(l) || /^\s*\d+[.)]\s+/.test(l)) {
        flush();
        const ordered = /^\s*\d+[.)]\s+/.test(l);
        const list = h(ordered ? "ol" : "ul");
        while (i < lines.length && (ordered ? /^\s*\d+[.)]\s+/ : /^\s*[-*]\s+/).test(lines[i])) {
          list.append(h("li", {}, inline(lines[i].replace(ordered ? /^\s*\d+[.)]\s+/ : /^\s*[-*]\s+/, ""))));
          i++;
        }
        root.append(list);
        continue;
      } else if (l.trim() === "") {
        flush();
      } else {
        para.push(l.trim());
      }
      i++;
    }
    flush();
    return root;
  }

  /* A model-written text with its marker above and its figures beneath (rule 2). */
  function prose(text, figuresEl) {
    return h("div", { class: "prose" },
      h("div", { class: "by" }, evidence({ kind: "model", text: "written by a model from the figures beneath" })),
      markdown(text),
      figuresEl);
  }

  /* --- the figures as a table, whatever the jq emitted ---------------------
     Scalars in one table; a tally ({name: count}) as its own small table; a
     list of objects as a table with their keys; the largest pull request as
     one line. Generic, so a figure added to stats.jq shows up unasked. */
  function figures(stats, skip) {
    const out = frag();
    if (!stats) return out;
    const scalars = [], tallies = [], lists = [], objects = [];
    for (const [k, v] of Object.entries(stats)) {
      if (skip.includes(k) || v == null) continue;
      if (typeof v !== "object") scalars.push({ k, v });
      else if (Array.isArray(v)) { if (v.length) lists.push({ k, v }); }
      else if (Object.values(v).every(x => typeof x === "number")) { if (Object.keys(v).length) tallies.push({ k, v }); }
      else objects.push({ k, v });
    }
    if (scalars.length) {
      out.append(h("div", { class: "scalars" }, scalars.map(({ k, v }) =>
        h("div", { class: "scalar" }, h("span", { class: "k" }, label(k)), h("span", { class: "v" }, num(v))))));
    }
    for (const { k, v } of objects) {
      const parts = [];
      if (v.repo && v.number != null) {
        const url = web.data.repos[v.repo] && web.data.repos[v.repo].url;
        const ref = v.repo + "#" + v.number;
        parts.push(url ? h("a", { href: url + "/pull/" + v.number, target: "_blank", rel: "noopener" }, ref) : ref);
      }
      if (v.title) parts.push(" ", v.title);
      if (v.lines != null) parts.push(" ", h("span", { class: "faint" }, num(v.lines) + " lines"));
      if (!parts.length) parts.push(JSON.stringify(v));
      out.append(h("p", { class: "one" }, h("span", { class: "k" }, label(k)), " ", parts));
    }
    if (tallies.length) {
      out.append(h("div", { class: "tallies" }, tallies.map(({ k, v }) => h("div", {},
        h("h4", {}, label(k)),
        table([{ key: "name", label: k === "by_repo" ? "repo" : "", render: r => k === "by_repo" ? repoLink(r.name) : r.name },
               { key: "n", label: "count", num: true }],
              Object.entries(v).map(([name, n]) => ({ name, n })))))));
    }
    for (const { k, v } of lists) {
      out.append(h("h4", {}, label(k)));
      if (v.every(x => typeof x !== "object")) { out.append(h("p", {}, v.map(String).join(", "))); continue; }
      const keys = [...new Set(v.flatMap(x => Object.keys(x)))];
      out.append(table(keys.map(key => ({ key, label: label(key), num: v.every(x => typeof x[key] === "number"),
                                          render: r => key === "repo" && r[key] ? repoLink(r[key]) : (r[key] == null ? "" : num(r[key])) })), v));
    }
    return out;
  }

  /* --- weeks ----------------------------------------------------------------- */
  const weekFigures = w => figures(w.stats, ["week", "since", "until", "merged_by_people"]);

  function multiples(view) {
    const weeks = view.list || [];
    const grid = h("div", { class: "multiples" });
    for (const f of view.figures || []) {
      const latest = weeks.find(w => w.stats && typeof w.stats[f.key] === "number");
      const bars = h("div", { class: "bars", "aria-hidden": "true" });
      for (const w of weeks) {
        const v = w.stats ? w.stats[f.key] : null;
        const known = typeof v === "number";
        const pct = known && f.max > 0 ? Math.max(2, Math.round(v / f.max * 100)) : (known ? 2 : 0);
        bars.append(h("span", { class: "bar" + (known ? "" : " na"), style: "height:" + pct + "%",
                                title: w.week + (known ? " · " + num(v) : " · not read") }));
      }
      grid.append(h("div", { class: "multiple", title: label(f.key) },
        h("div", { class: "head" }, h("span", { class: "k" }, f.label),
          h("span", { class: "v" }, latest ? num(latest.stats[f.key]) : "")),
        bars,
        h("div", { class: "axis faint" }, weeks.length > 1 ? [weeks[0].week, h("span", {}, weeks[weeks.length - 1].week)] : weeks.length === 1 ? weeks[0].week : "")));
    }
    return grid;
  }

  const recapCmd = w => "orgami report --week " + w.week;

  function weeksTable(view, q) {
    const s = (w, k) => w.stats && typeof w.stats[k] === "number" ? w.stats[k] : null;
    const rows = (view.list || []).filter(w => !q || [w.week, w.since, w.until,
      ...Object.keys((w.stats && w.stats.by_repo) || {}), ...Object.keys((w.stats && w.stats.by_author) || {})]
      .join(" ").toLowerCase().includes(q));
    if (!rows.length) return h("p", { class: "empty" }, "no week matches");
    return table([
      { key: "week", render: w => h("a", { href: weekHref(w.week) }, w.week) },
      { key: "span", label: "days", render: w => (w.since || "") + " to " + (w.until || ""), sort: w => w.since },
      { key: "merged", label: "merged", num: true, render: w => s(w, "merged") == null ? h("span", { class: "faint" }, "not read") : num(s(w, "merged")), sort: w => s(w, "merged") },
      { key: "bots", label: "by bots", num: true, render: w => num(s(w, "merged_by_bots") ?? ""), sort: w => s(w, "merged_by_bots") },
      { key: "repos", label: "repos", num: true, render: w => num(s(w, "repos_touched") ?? ""), sort: w => s(w, "repos_touched") },
      { key: "authors", label: "authors", num: true, render: w => num(s(w, "authors") ?? ""), sort: w => s(w, "authors") },
      { key: "review", label: "without review", num: true, render: w => num(s(w, "merged_without_review") ?? ""), sort: w => s(w, "merged_without_review") },
      { key: "median", label: "median h to merge", num: true, render: w => num(s(w, "median_hours_to_merge") ?? ""), sort: w => s(w, "median_hours_to_merge") },
      { key: "recap", label: "recap", render: w => w.recap ? h("a", { href: weekHref(w.week) }, "recap")
                                                      : h("span", { class: "faint" }, "none — ", h("code", {}, recapCmd(w))), sort: w => w.recap ? 0 : 1 },
    ], rows);
  }

  function weeksSection(el, view) {
    el.append(h("h3", {}, "Weeks"));
    if (!view.weeks || view.weeks.missing) { el.append(freshness(view.weeks)); return; }
    el.append(h("p", { class: "src muted" },
      "one row per cache/prs/<week>.json, the figures lib/stats.jq computes ",
      evidence({ kind: "reading", command: view.weeks.command, date: view.weeks.generated })));
    el.append(multiples(view));
    const box = h("div");
    const draw = q => box.replaceChildren(weeksTable(view, q));
    draw(web.query());
    web.onSearch(draw);
    el.append(box);
  }

  function weekPage(el, view, week) {
    const w = (view.list || []).find(x => x.week === week);
    el.append(h("h2", {}, week, " ", h("a", { class: "up", href: "#/activity" }, "all weeks")));
    if (!w) { el.append(h("p", { class: "muted" }, "no cache/prs/" + week + ".json — ", h("code", {}, "orgami pull"))); return; }
    el.append(freshness({ generated: w.until, command: view.weeks && view.weeks.command }));
    el.append(h("p", { class: "muted" }, (w.since || "") + " to " + (w.until || "") + " · ", h("code", {}, w.file)));

    el.append(h("h3", {}, "Recap"));
    const figs = h("div", { class: "beneath" },
      h("h4", {}, "The figures ", evidence({ kind: "reading", command: "orgami pull", date: w.until })),
      w.stats ? weekFigures(w) : h("p", { class: "muted" }, "stats.jq could not read this week's cache"));
    if (w.recap) el.append(prose(w.recap, figs));
    else el.append(h("p", { class: "muted" }, "no recap for this week — ", h("code", {}, recapCmd(w))), figs);

    if (w.prs && w.prs.length) {
      el.append(h("h3", {}, "Merged pull requests"));
      el.append(table([
        { key: "ref", label: "pull request", render: p => p.url ? h("a", { href: p.url, target: "_blank", rel: "noopener" }, p.repo + "#" + p.number) : p.repo + "#" + p.number, sort: p => p.repo + "#" + p.number },
        { key: "title" },
        { key: "repo", render: p => repoLink(p.repo) },
        { key: "author", render: p => [p.author, p.bot ? h("span", { class: "tag" }, "bot") : null] },
        { key: "mergedAt", label: "merged", render: p => day(p.mergedAt) },
        { key: "lines", num: true, render: p => num(p.lines) },
        { key: "reviewed", render: p => p.reviewed ? "reviewed" : h("span", { class: "faint" }, "no review"), sort: p => p.reviewed ? 0 : 1 },
      ], w.prs));
    }
  }

  /* --- days ----------------------------------------------------------------- */
  const dayHref = d => "#/activity/" + d;
  const digestCmd = d => "orgami daily --date " + d.date;

  function dayLine(d) {
    const s = d.stats || {};
    const bits = [];
    if (s.merged != null) bits.push(num(s.merged) + " merged" + (s.merged_by_bots ? " (+" + num(s.merged_by_bots) + " by bots)" : ""));
    if (s.opened != null) bits.push(num(s.opened) + " opened");
    if (s.commits_outside_prs) bits.push(num(s.commits_outside_prs) + " commit" + (s.commits_outside_prs === 1 ? "" : "s") + " outside a pull request");
    if (s.repos_touched != null) bits.push(num(s.repos_touched) + " repos");
    if (s.authors != null) bits.push(num(s.authors) + " people");
    if (s.waiting && s.waiting.length) bits.push(num(s.waiting.length) + " waiting on review");
    return h("p", { class: "line" }, bits.join(" · "), " ", evidence({ kind: "reading", command: "orgami daily", date: d.date }));
  }

  function dayFigures(d) { return figures(d.stats, ["date", "org"]); }

  function dayPanel(d, full) {
    const art = h("article", { class: "day panel" });
    art.append(h("h4", {}, h("a", { href: dayHref(d.date) }, d.date)));
    const beneath = h("div", { class: "beneath" }, full ? [h("h4", {}, "The figures"), dayFigures(d)] : dayLine(d));
    if (d.digest) art.append(prose(d.digest, beneath));
    else art.append(h("p", { class: "muted" }, "no digest — ", h("code", {}, digestCmd(d))), beneath);
    return art;
  }

  function daysSection(el, view) {
    el.append(h("h3", {}, "Days"));
    if (!view.days || view.days.missing) { el.append(freshness(view.days)); return; }
    el.append(h("p", { class: "src muted" },
      "the last " + (view.days.count === 1 ? "day" : num(view.days.count) + " days") + " with something in it, the figures lib/daily.jq computes; quiet days are left out ",
      evidence({ kind: "reading", command: view.days.command, date: view.days.generated })));
    const box = h("div", { class: "days" });
    const draw = q => {
      const list = (view.days.list || []).filter(d => !q || (d.date + " " + (d.digest || "") + " " + Object.keys((d.stats && d.stats.by_repo) || {}).join(" ")).toLowerCase().includes(q));
      box.replaceChildren(...(list.length ? list.map(d => dayPanel(d, false)) : [h("p", { class: "empty" }, "no day matches")]));
    };
    draw(web.query());
    web.onSearch(draw);
    el.append(box);
  }

  function dayPage(el, view, date) {
    const d = view.days && view.days.list ? view.days.list.find(x => x.date === date) : null;
    el.append(h("h2", {}, date, " ", h("a", { class: "up", href: "#/activity" }, "all days")));
    if (!d) { el.append(h("p", { class: "muted" }, "no cache/daily/" + date + ".json among the last fourteen days with something in them — ", h("code", {}, "orgami daily --date " + date))); return; }
    el.append(freshness({ generated: d.date, command: view.days.command }));
    el.append(h("p", { class: "muted" }, h("code", {}, d.file)));
    el.append(dayPanel(d, true));
  }

  /* --- coupling --------------------------------------------------------------- */
  function couplingSection(el, view) {
    const c = view.coupling;
    el.append(h("h3", {}, "Coupling — correlation, not dependency"));
    if (!c || c.missing) { el.append(freshness(c)); return; }
    const pairs = c.pairs || [];
    if (!pairs.length) { el.append(freshness(c)); el.append(h("p", { class: "muted" }, "no two repos changed together in the " + num(c.weeks_observed) + " weeks of cached pull requests")); return; }

    let on = true;
    const chip = h("button", { type: "button", class: "chip", "aria-pressed": "true", onclick: () => {
      on = !on; chip.setAttribute("aria-pressed", String(on)); chip.classList.toggle("off", !on); body.hidden = !on; }
    }, h("span", { class: "dot" }), "inferred");
    el.append(h("p", { class: "src muted" },
      "counted out of " + num(c.weeks_observed) + " weeks of merged pull requests: the same person merging in two repos in the same week, and in the same day; bots left out, as lib/coupling.sh leaves them. Nobody declared these. ",
      evidence({ kind: "inferred", at: "same author, same week" }), " ",
      evidence({ kind: "reading", command: c.command, date: c.generated }), " ", chip));

    const body = h("div");
    const byKey = new Map(pairs.map(p => [p.a + "|" + p.b, p]));
    const pair = (x, y) => byKey.get(x < y ? x + "|" + y : y + "|" + x);
    const maxW = (c.max && c.max.weeks) || 1;

    const draw = q => {
      const repos = (c.repos || []).filter(r => !q || r.toLowerCase().includes(q) || pairs.some(p => (p.a === r || p.b === r) && (p.a + " " + p.b).toLowerCase().includes(q)));
      body.replaceChildren();
      if (!repos.length) { body.append(h("p", { class: "empty" }, "no repo matches")); return; }
      const t = h("table", { class: "matrix" });
      t.append(h("thead", {}, h("tr", {}, h("th", { scope: "col" }, h("span", { class: "faint" }, "weeks / days")),
        repos.map(r => h("th", { scope: "col" }, h("span", { class: "col" }, repoLink(r)))))));
      const tb = h("tbody");
      for (const r of repos) {
        const tr = h("tr", {}, h("th", { scope: "row" }, repoLink(r)));
        for (const s of repos) {
          if (r === s) { tr.append(h("td", { class: "self" })); continue; }
          const p = pair(r, s);
          if (!p) { tr.append(h("td", { class: "none" })); continue; }
          const strong = p.weeks > 1 || p.days > 1;
          tr.append(h("td", { class: "pair" + (strong ? "" : " once"), style: "--w:" + (p.weeks / maxW).toFixed(2) },
            h("a", { href: "#/repos/" + encodeURIComponent(s), title: r + " and " + s + ": " + num(p.weeks) + " weeks, " + num(p.days) + " days, " + p.authors.join(", ") },
              num(p.weeks), h("span", { class: "sep" }, " / "), num(p.days))));
        }
        tb.append(tr);
      }
      t.append(tb);
      body.append(h("div", { class: "scroll" }, t));
      body.append(h("p", { class: "muted small" }, "a cell is the row repo and the column repo, and opens the column repo; the row heading opens the row repo. Faded cells were seen in one week and on one day only, which the graph leaves out."));
      body.append(h("h4", {}, "Pairs"));
      body.append(table([
        { key: "a", label: "repo", render: p => repoLink(p.a) },
        { key: "b", label: "and", render: p => repoLink(p.b) },
        { key: "weeks", num: true, render: p => num(p.weeks) },
        { key: "days", num: true, render: p => num(p.days) },
        { key: "authors", render: p => p.authors.join(", "), sort: p => p.authors.join(", ") },
      ], pairs.filter(p => repos.includes(p.a) && repos.includes(p.b))));
    };
    draw(web.query());
    web.onSearch(draw);
    el.append(body);
  }

  /* --- the view ---------------------------------------------------------------- */
  web.register({
    id: "activity",
    title: "Activity",
    needs: ["cache/prs/<week>.json", "cache/daily/<date>.json", "reports/<week>.md", "reports/daily/<date>.md", "map/coupling.json"],
    render(el, view, all, route) {
      const rest = route.parts[0] || "";
      if (WEEK.test(rest)) return weekPage(el, view, rest);
      if (DATE.test(rest)) return dayPage(el, view, rest);
      el.append(h("h2", {}, "Activity"));
      el.append(freshness(view));
      if (rest) el.append(h("p", { class: "muted" }, "nothing under activity is called " + rest + "; weeks are 2026-W33, days are 2026-08-12"));
      weeksSection(el, view);
      daysSection(el, view);
      couplingSection(el, view);
    },
  });
})();
