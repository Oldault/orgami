"use strict";
/* The overview: the org at a glance. Everything drawn here is a figure
   lib/web/10-overview.jq computed, and every figure carries, in its title
   attribute, the file it came from — hover a number to see where it is from.
   The view counts nothing; it draws bars from counts it was handed. */
web.register({
  id: "overview",
  title: "Overview",
  needs: ["map/graph.json", "map/repos.json", "map/live.json", "map/dns.json",
          "map/advise.json", "map/coupling.json", "map/depth.json",
          "reports/<week>.md", "reports/daily/<date>.md", "cache/prs/<week>.json"],
  render(el, view) {
    const h = web.h;

    /* A figure, with the file it came from in its title (rule 2). */
    const num = (n, file, cls) => h("span", { class: "n" + (cls ? " " + cls : ""), title: file }, n == null ? "—" : String(n));
    const word = (n, one) => n === 1 ? one : one + "s";
    const plural = (n, one) => n + " " + word(n, one);

    /* Rows of small bars: label, bar, count. Widths are relative to the
       largest row on the page, which is a comparison of what is drawn, not
       an org-level figure. `segments(row)` returns [{cls, value}] for a
       stacked bar; without it the bar is one solid piece. */
    function bars(rows, file, opts) {
      opts = opts || {};
      const max = Math.max(1, ...rows.map(r => r.count || 0));
      const list = h("div", { class: "bars", role: "list" });
      for (const r of rows) {
        const bar = h("div", { class: "bar", title: file });
        const segs = opts.segments ? opts.segments(r) : [{ cls: "", value: r.count }];
        for (const s of segs) {
          if (!s.value) continue;
          bar.append(h("i", { class: s.cls || null, style: "width:" + (100 * s.value / max).toFixed(2) + "%" + (s.color ? ";background:" + s.color : "") }));
        }
        list.append(h("div", { class: "row", role: "listitem" },
          h("span", { class: "label" }, opts.label ? opts.label(r) : r.name),
          bar,
          num(r.count, file)));
      }
      return list;
    }

    /* --- the org --------------------------------------------------------- */
    const org = view.org || {};
    el.append(h("h2", {}, org.name || web.data.company || "orgami"));
    const line = h("p", { class: "orgline muted" });
    if (org.slug) line.append(h("span", { class: "mono", title: "config.json" }, org.slug));
    if (org.docs_repo) {
      const path = org.docs_path ? " /" + org.docs_path : "";
      line.append(h("span", { title: "config.json" }, "docs: ",
        /^https?:\/\//.test(org.docs_repo)
          ? h("a", { href: org.docs_repo, target: "_blank", rel: "noopener" }, org.docs_repo.replace(/^https?:\/\/(www\.)?/, ""))
          : h("span", { class: "mono" }, org.docs_repo),
        path));
    }
    if (org.mapped) line.append(h("span", { title: org.file }, "mapped ", web.day(org.mapped)));
    el.append(line);
    el.append(web.freshness(view));

    /* --- readings: every file orgami writes, present or not (rule 4) ----- */
    const readings = view.readings || [];
    if (readings.length) {
      el.append(h("h3", {}, "Readings"));
      el.append(web.table([
        { key: "label", label: "reading", render: r => h("span", {}, r.label) },
        { key: "file", label: "file", render: r => h("code", { class: r.present ? null : "faint" }, r.file) },
        { key: "generated", label: "age", sort: r => r.generated || "", render: r => {
          if (!r.present) return h("span", { class: "muted" }, "not run yet");
          if (!r.generated) return h("span", { class: "muted" }, "no date on this reading");
          const a = web.age(r.generated);
          const cell = h("span", { title: r.file },
            a ? "read " + a + " ago" : r.generated,
            h("span", { class: "faint" }, " " + web.day(r.generated)));
          if (r.stale) cell.append(h("span", { class: "stale", title: "older than the map" }, " stale"));
          return cell;
        } },
        { key: "command", label: "refresh", render: r => h("code", {}, r.command) },
      ], readings));
    }

    /* --- counts ----------------------------------------------------------- */
    const c = view.counts || {};
    const gfile = c.file || "map/graph.json";
    const panels = [];

    if (c.repos && c.repos.total) {
      panels.push(h("div", { class: "panel" },
        h("h4", {}, num(c.repos.total, gfile, "big"), " ", word(c.repos.total, "repo")),
        h("div", { class: "faint small" }, "by language"),
        bars(c.repos.by_language || [], gfile, { segments: r => [{ value: r.count, color: web.color("repo") }] })));
    }
    if (c.nodes && c.nodes.total) {
      panels.push(h("div", { class: "panel" },
        h("h4", {}, num(c.nodes.total, gfile, "big"), " ", word(c.nodes.total, "node")),
        h("div", { class: "faint small" }, "by kind"),
        bars(c.nodes.by_kind || [], gfile, {
          label: r => h("span", { class: "tag kind-" + r.name }, r.name),
          segments: r => [{ value: r.count, color: web.color(r.name) }],
        })));
    }
    if (c.edges && c.edges.total) {
      panels.push(h("div", { class: "panel" },
        h("h4", {}, num(c.edges.total, gfile, "big"), " ", word(c.edges.total, "edge")),
        h("div", { class: "faint small" },
          num(c.edges.extracted, gfile), " extracted · ", num(c.edges.inferred, gfile), " inferred"),
        bars(c.edges.by_kind || [], gfile, {
          segments: r => [{ cls: "extracted", value: r.extracted }, { cls: "inferred", value: r.inferred }],
        }),
        h("div", { class: "key faint small" },
          web.evidence({ kind: "extracted", at: "file:line" }), web.evidence({ kind: "inferred", at: "matched" }))));
    }
    if (c.vendors && c.vendors.total) {
      panels.push(h("div", { class: "panel" },
        h("h4", {}, num(c.vendors.total, gfile, "big"), " ", word(c.vendors.total, "vendor")),
        h("div", { class: "faint small" }, "by category, from committed configuration"),
        bars(c.vendors.by_category || [], gfile, { segments: r => [{ value: r.count, color: web.color("vendor") }] })));
    }
    const small = h("div", { class: "panel tiles" });
    if (c.hosts && c.hosts.total) {
      small.append(h("div", { class: "tile" }, num(c.hosts.total, gfile, "big"), h("span", { class: "muted" }, word(c.hosts.total, "host"))));
    }
    if (c.live) {
      const lf = c.live.file || "map/live.json";
      small.append(h("div", { class: "tile" }, num(c.live.matched, lf, "big"),
        h("span", { class: "muted" }, "deployment" + (c.live.matched === 1 ? "" : "s") + " seen live, matched to a repo")));
      if (c.live.unmatched) {
        small.append(h("div", { class: "tile" }, num(c.live.unmatched, lf, "big"),
          h("span", { class: "muted" }, "seen live, not matched to any repo")));
      }
      if (c.live.providers && c.live.providers.length) {
        small.append(h("div", { class: "tile wide" },
          h("span", { class: "muted" }, "asked: "),
          web.evidence({ kind: "reading", command: "orgami live — " + c.live.providers.join(", "), date: c.live.generated })));
      }
    }
    if (small.childElementCount) panels.push(small);
    if (panels.length) {
      el.append(h("h3", {}, "Counts"));
      el.append(h("div", { class: "grid" }, panels));
    }

    /* --- this week: the newest cache week, through stats.jq -------------- */
    const w = view.week;
    if (w && w.figures) {
      const f = w.figures;
      const href = "#/activity/" + encodeURIComponent(w.week);
      const head = h("h3", {}, "This week");
      el.append(head);
      const meta = h("p", { class: "muted small" },
        h("a", { href }, w.week), " · ", web.day(w.since), " to ", web.day(w.until),
        " · figures from ", h("code", {}, "lib/stats.jq"), " over ", h("code", {}, w.file));
      if (w.report) meta.append(" · recap: ", h("a", { href }, w.report));
      el.append(meta);
      const tile = (n, label, cls) => h("a", { class: "tile", href }, num(n, w.file, "big " + (cls || "")), h("span", { class: "muted" }, label));
      const tiles = h("div", { class: "panel tiles" },
        tile(f.merged, "merged pull request" + (f.merged === 1 ? "" : "s") + " by people"),
        tile(f.merged_by_bots, "by bots"),
        tile(f.authors, "author" + (f.authors === 1 ? "" : "s")),
        tile(f.repos_touched, "repo" + (f.repos_touched === 1 ? "" : "s") + " touched"),
        tile(f.median_hours_to_merge, "median hours to merge"),
        tile(f.merged_without_review, "merged without review", f.merged_without_review ? "warn" : ""));
      if (f.lines_added != null) {
        tiles.append(h("a", { class: "tile", href },
          h("span", { class: "n big", title: w.file }, "+" + f.lines_added, h("span", { class: "faint" }, " / "), "−" + f.lines_removed),
          h("span", { class: "muted" }, "lines added / removed")));
      }
      el.append(tiles);
    }

    /* --- what advise ranks first ------------------------------------------ */
    const a = view.advise;
    if (a && a.top && a.top.length) {
      const af = a.file || "map/advise.json";
      el.append(h("h3", {}, "What advise ranks first"));
      el.append(h("p", { class: "muted small" },
        num(a.proposals, af), " open proposal" + (a.proposals === 1 ? "" : "s"),
        a.suppressed ? [", ", num(a.suppressed, af), " answered"] : null,
        " · ranked by confidence, then blast radius · no invoice has been seen · ",
        h("a", { href: "#/vendors" }, "all of them")));
      const ol = h("ol", { class: "top" });
      for (const p of a.top) {
        const vendor = p.candidate || (p.vendors && p.vendors[0]) || null;
        const href = vendor ? "#/vendors/" + encodeURIComponent(vendor) : "#/vendors";
        const radius = [plural(p.repo_count, "repo")];
        if (p.domain_count) radius.push(plural(p.domain_count, "domain"));
        ol.append(h("li", { class: "panel" },
          h("div", { class: "head" },
            h("a", { href, class: "mono" }, p.id),
            h("span", { class: "tag conf-" + p.confidence, title: af }, p.confidence),
            h("span", { class: "tag", title: af }, p.kind)),
          h("p", { class: "claim" }, p.claim),
          h("div", { class: "faint small" }, "blast radius: ",
            h("span", { title: af }, radius.join(", ")))));
      }
      el.append(ol);
    }

    /* --- what the scan cannot see ---------------------------------------- */
    /* The standing sentence from docs/map.md, kept word for word (rule 5). */
    el.append(h("p", { class: "cannot muted" },
      "What the scan cannot see, it does not invent. Services wired together by runtime " +
      "environment variables, a service mesh, or a shared gateway leave no trace in a " +
      "repository, so a missing edge means “not found in committed configuration” and " +
      "never “not connected”."));
  },
});
