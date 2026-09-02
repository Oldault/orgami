"use strict";
/* Vendors: what the organization pays for, as far as files can tell.

   Everything drawn here is in views.vendors, computed by lib/web/40-vendors.jq
   from the graph's vendor nodes and edges, the DNS reading, advise.json and
   the notes. This file lays it out; it derives no figure of its own beyond
   counting the rows a search leaves on the page (rule 3).

   Money is on this page only where a person typed it (rule 6): the figures
   in map/costs.json, each drawn as human evidence with who and when. Nothing
   under ~/.orgami has seen an invoice, the header says so, and the proposals
   stay in the order `orgami advise` ranks them: confidence first, blast
   radius second, a figure beside the reach where one exists. A category
   total is drawn only where the payload computed one — every vendor costed,
   one currency — otherwise "n of m vendors costed" and no sum (rule 5). The
   page changes nothing — where an answer makes sense it shows the command to
   copy (rule 8). Never write a closing tag in a string here: this file is
   inlined into the page's own script block. */
(() => {
  const h = web.h;

  const KIND_WORDS = {
    "duplicate-category": "two vendors doing the same job",
    "single-repo-vendor": "a vendor in one repository",
    "orphan-vendor": "a vendor wired into a repository nobody touches",
    "dns-only-vendor": "an account nothing in the code accounts for",
    "ghost-env-var": "a variable declared for an SDK that was never wired",
  };
  const SOURCE_WORDS = { code: "code", dns: "dns", both: "code + dns", none: "not found" };

  /* --- wording, from docs/map.md and docs/advise.md (rule 5) ---------------- */
  const NOT_IN_CODE = "not found in committed configuration";
  const NOT_IN_DNS = "not found in public DNS";
  const DNS_ONLY = "a vendor public DNS names and no repository does — a subscription no repository was ever going to mention";

  const plural = (n, one, many) => n + " " + (n === 1 ? one : (many || one + "s"));
  const vendorHref = id => "#/vendors/" + encodeURIComponent(id);
  const repoHref = name => "#/repos/" + encodeURIComponent(name);

  const tag = (text, cls) => h("span", { class: "tag " + (cls || "") }, text);
  const sourceTag = s => tag(SOURCE_WORDS[s] || s, "src src-" + s);
  const confTag = c => tag(c, "conf conf-" + c);
  const kindTag = k => h("span", { class: "tag kind", title: KIND_WORDS[k] || "" }, k);

  const substTag = v => {
    if (v === true) return tag("substitutable", "subst");
    if (v === false) return tag("coexist by design", "coexist");
    return tag("substitutability unknown until orgami advise", "unknown");
  };

  /* A DNS record as `orgami dns` wrote it already ends in the date it was
     dug; the reading's own date is added only when a record does not carry
     one, so the date is there once (rule 2). */
  function reading(at, view) {
    return web.evidence({ kind: "reading", at: at, date: /\(dig [0-9-]+\)\s*$/.test(at || "") ? null : view.sources.dns.generated });
  }

  /* One piece of evidence from a proposal row or a vendor row, through the
     shell so it is marked the same way everywhere (rule 2). */
  function ev(e, view) {
    if (e.kind === "reading") return reading(e.at, view);
    return web.evidence({ kind: e.kind || "extracted", at: e.at, repo: e.repo });
  }

  /* The proposal's evidence, one row per piece, the vendor and the repo or
     domain in front of the file:line or the record. */
  function evidenceList(rows, view, byId) {
    if (!rows || !rows.length) return web.empty();
    return h("ul", { class: "evlist" }, rows.map(r =>
      h("li", {},
        r.vendor ? h("a", { href: vendorHref(r.vendor), class: "vname" }, (byId[r.vendor] || {}).name || r.vendor) : null,
        r.repo ? h("a", { href: repoHref(r.repo), class: "mono rname" }, r.repo) : null,
        r.domain ? h("span", { class: "mono rname" }, r.domain) : null,
        ev(r, view))));
  }

  const reach = p => {
    const bits = [];
    if (p.repo_count > 0) bits.push(plural(p.repo_count, "repo"));
    if (p.domains && p.domains.length) bits.push(plural(p.domains.length, "domain"));
    if (p.days_since_push != null) bits.push("last push " + p.last_push + ", " + plural(p.days_since_push, "day") + " ago");
    return bits.join(" · ");
  };

  /* --- money, as a person typed it (rule 6) ---------------------------------- */
  /* The figure is formatted, never computed: the amount is the payload's. */
  const money = (amount, currency, period) =>
    amount.toLocaleString("en-US") + " " + currency + " / " + period;
  const costCommand = id => "orgami cost " + id + " <amount> [--per month|year] [--currency EUR]";

  /* One typed figure, marked human with who and when, the same mark a note
     carries (rule 2). */
  function figure(c, name) {
    return web.evidence({ kind: "human", text: (name ? name + " " : "") + money(c.amount, c.currency, c.period), author: c.who, date: c.when });
  }

  /* Under a category's table: the total where the payload computed one,
     otherwise how many of the vendors have a figure and why there is no sum. */
  function categoryCosts(cat) {
    if (!cat.costed) return web.empty();
    const n = cat.vendors.length;
    if (cat.total) {
      const t = cat.total;
      const line = h("p", { class: "total" },
        h("b", {}, "total " + money(t.amount, t.currency, t.period)),
        h("span", { class: "faint" }, " · every vendor in the category has a figure" +
          (t.mixed_periods ? " · per month figures × 12, since the periods differ" : "")),
        h("span", { class: "from" }, t.from.map(f => h("span", { class: "faint" }, f.vendor + ": " + f.who + ", " + web.day(f.when)))));
      return line;
    }
    const why = cat.currencies.length > 1
      ? "in " + cat.currencies.length + " currencies — no total until they agree"
      : "no total until every one has a figure — a partial sum is a lie";
    return h("p", { class: "total faint" }, cat.costed + " of " + plural(n, "vendor") + " costed · " + why);
  }

  /* --- the header (rules 4 and 6) ------------------------------------------- */
  function header(view) {
    const s = view.sources;
    const panel = h("div", { class: "panel intro" });
    if (view.counts.costed) {
      panel.append(h("p", {},
        "No invoice has been seen. Every amount on this page was typed by a person with ", h("code", {}, "orgami cost"),
        " and carries who typed it and when; nothing here is priced by the tool. Proposals stay ranked by confidence first and blast radius ",
        "second — how many repositories an answer would touch — exactly as ", h("code", {}, "orgami advise"),
        " ranks them: a figure is a human's claim, not the tool's, so it is shown beside the reach and does not move the rank."));
    } else {
      panel.append(h("p", {},
        "No invoice has been seen. Nothing under the company directory knows what anything costs, ",
        "so there is no amount on this page: proposals are ranked by confidence first and blast radius ",
        "second — how many repositories an answer would touch — exactly as ", h("code", {}, "orgami advise"), " ranks them. ",
        "A figure a person knows goes in with ", h("code", {}, "orgami cost <vendor> <amount>"), ", with their name and the date beside it."));
    }
    const srcs = h("div", { class: "srcs" });
    for (const [label, src] of [["map", s.graph], ["dns", s.dns], ["advise", s.advise], ["costs", s.costs]]) {
      srcs.append(h("div", { class: "srcrow" }, h("span", { class: "srclabel" }, label), web.freshness(src)));
    }
    panel.append(srcs);
    if (s.dns.missing) {
      panel.append(h("p", { class: "muted" },
        "No DNS reading. Run ", h("code", {}, "orgami dns"), " before reading this and the picture gets larger and more honest: ",
        "a vendor's absence means different things depending on whether public DNS has been asked."));
    }
    return panel;
  }

  function countsLine(c) {
    const bits = [plural(c.vendors, "vendor") + " in " + plural(c.categories, "category", "categories")];
    const from = [];
    if (c.from_code) from.push(c.from_code + " from code");
    if (c.from_dns) from.push(c.from_dns + " from dns");
    if (c.from_both) from.push(c.from_both + " from both");
    if (from.length) bits.push(from.join(", "));
    if (c.repos) bits.push(plural(c.repos, "repo") + " name one");
    if (c.not_found) bits.push(c.not_found + " in the map but " + NOT_IN_CODE + " and " + NOT_IN_DNS);
    if (c.costed) bits.push(c.costed + " with a figure a person typed");
    return h("p", { class: "muted counts" }, bits.join(" · "));
  }

  /* --- the matrix: vendor × repo, by category ------------------------------- */
  function matrix(view, byId, searchable) {
    const wrap = h("div");
    const hasDns = !view.sources.dns.missing;
    for (const cat of view.categories) {
      const rows = cat.vendors.map(id => byId[id]).filter(Boolean);
      if (!rows.length) continue;
      const block = h("div", { class: "cat" });
      block.append(h("h4", {}, cat.category || "no category", substTag(cat.substitutable)));
      const cols = [
        { key: "name", label: "vendor", render: r => h("a", { href: vendorHref(r.id) }, r.name), sort: r => r.name.toLowerCase() },
        { key: "source", label: "source", render: r => sourceTag(r.source) },
      ];
      /* Only the repos that name a vendor in this category get a column, so a
         category with one vendor in one repo is one cell wide, not nine. */
      const repos = view.repos.filter(rp => rows.some(r => r.repos.includes(rp)));
      for (const rp of repos) {
        cols.push({ key: "repo:" + rp, label: rp,
          render: r => h("div", { class: "cell" }, r.code.filter(c => c.repo === rp).map(c => web.evidence({ kind: c.confidence, at: c.at, repo: rp }))),
          sort: r => r.repos.includes(rp) ? 0 : 1 });
      }
      if (hasDns) {
        cols.push({ key: "dns", label: "public dns",
          render: r => r.dns.length
            ? h("div", { class: "cell dnscell" }, r.dns.map(d => reading(d.at, view)))
            : h("span", { class: "faint" }, NOT_IN_DNS),
          sort: r => r.dns.length ? 0 : 1 });
      }
      /* An amount column only where a row exists for a vendor in this
         category (rule 6): a figure is human evidence with who and when, and
         a vendor without one says so rather than showing a zero. */
      if (cat.costed) {
        cols.push({ key: "cost", label: "amount", num: true,
          render: r => r.cost ? h("div", { class: "cell money" }, figure(r.cost)) : h("span", { class: "faint" }, "no figure typed"),
          sort: r => r.cost ? -r.cost.amount : 1 });
      }
      block.append(web.table(cols, rows));
      block.append(categoryCosts(cat));
      /* A row with no repo cell at all is not an empty row: it is the one kind
         of vendor the code was never going to find, and it is worded the way
         docs/advise.md words it. */
      for (const r of rows) {
        if (r.source === "dns") block.append(h("p", { class: "faint note" }, h("b", {}, r.name), ": ", NOT_IN_CODE, " — ", DNS_ONLY, "."));
        if (r.source === "none") block.append(h("p", { class: "faint note" }, h("b", {}, r.name), ": in the map, but ", NOT_IN_CODE, " and ", NOT_IN_DNS, "."));
      }
      searchable.push([block, rows.map(r => [r.name, r.id, r.category, r.repos.join(" "), r.domains.join(" ")].join(" ")).join(" ")]);
      wrap.append(block);
    }
    wrap.append(h("p", { class: "faint" }, "An empty cell is ", NOT_IN_CODE, ", never “not used”: a subscription paid on a card, or wired through a dashboard, leaves no file to match."));
    return wrap;
  }

  /* --- one proposal ----------------------------------------------------------- */
  function proposal(p, view, byId) {
    const li = h("li", { class: "prop", id: "p-" + p.id });
    li.append(h("div", { class: "prophead" },
      h("span", { class: "rank mono" }, p.rank != null ? "#" + p.rank : ""),
      kindTag(p.kind), confTag(p.confidence),
      h("code", { class: "pid" }, p.id),
      h("span", { class: "faint" }, reach(p)),
      /* Beside the blast radius, never ahead of it: the rank is advise's. */
      (p.costs || []).map(c => h("span", { class: "money" }, figure(c, (byId[c.vendor] || {}).name || c.vendor)))));
    li.append(h("p", { class: "claim" }, p.claim));
    li.append(evidenceList(p.evidence, view, byId));
    li.append(h("pre", { class: "cmd", tabindex: "0", "aria-label": "command to reject this proposal" }, p.command));
    return li;
  }

  /* --- one answer: the note, its author, and the chain ------------------------ */
  function answered(a, view, byId) {
    const li = h("li", { class: "prop answered", id: "a-" + a.id });
    const head = h("div", { class: "prophead" });
    if (a.proposal) head.append(kindTag(a.proposal.kind), confTag(a.proposal.confidence));
    head.append(h("code", { class: "pid" }, a.id));
    if (!a.proposed) head.append(h("span", { class: "faint" }, "no longer proposed — the situation it answered is not in the map now"));
    li.append(head);
    if (a.proposal) li.append(h("p", { class: "claim faint" }, a.proposal.claim));
    li.append(h("div", { class: "answer" }, web.evidence({ kind: "human", text: a.reason, author: a.author, date: a.date })));
    const where = h("p", { class: "faint" }, "note ", h("code", {}, a.note.id));
    if (a.note.repo) where.append(" · filed against ", h("a", { href: repoHref(a.note.repo), class: "mono" }, a.note.repo));
    if (a.supersedes) where.append(" · supersedes ", h("code", {}, a.supersedes));
    li.append(where);
    if (a.superseded_by && a.superseded_by.length) {
      li.append(h("p", { class: "faint" }, "superseded since — the answer that stands is the last one:"));
      li.append(h("ol", { class: "chain" }, a.superseded_by.map(n =>
        h("li", {}, web.evidence({ kind: "human", text: n.body, author: n.author, date: n.date }),
          h("span", { class: "faint" }, " note ", h("code", {}, n.id), n.archived ? " (archived)" : "")))));
    }
    if (a.evidence && a.evidence.length) {
      li.append(h("details", {}, h("summary", { class: "faint" }, "the evidence the proposal rested on"), evidenceList(a.evidence, view, byId)));
    }
    return li;
  }

  /* --- not proposed, on purpose ----------------------------------------------- */
  function excluded(ex, byId) {
    const wrap = h("div");
    wrap.append(h("p", { class: "muted" },
      "Two rules do not fire everywhere they match, and both restraints are written down here rather than left as an absence. ",
      "A reader who disagrees can see what was withheld and where the policy that withheld it lives."));
    const ul = h("ul", { class: "excl" });
    for (const d of ex.duplicate_category || []) {
      ul.append(h("li", {},
        h("b", {}, d.category), " — ",
        (d.vendors || []).map((v, i) => [i ? ", " : null, h("a", { href: vendorHref(v) }, (byId[v] || {}).name || v)]),
        d.repo_count != null ? h("span", { class: "faint" }, " · " + plural(d.repo_count, "repo")) : null,
        " · ", h("code", { class: "pid" }, d.id),
        h("div", { class: "faint" }, d.reason)));
    }
    for (const g of ex.ghost_env_var || []) {
      ul.append(h("li", {},
        h("a", { href: vendorHref(g.vendor) }, g.name || g.vendor), " in ",
        h("a", { href: repoHref(g.repo), class: "mono" }, g.repo),
        " · ", h("code", { class: "pid" }, g.id),
        h("div", { class: "faint" }, g.reason)));
    }
    wrap.append(ul);
    const subst = ex.substitutable_categories || [];
    if (subst.length) {
      wrap.append(h("p", { class: "faint" }, "Categories whose vendors are substitutes, and so the only ones a duplicate is called in: ",
        subst.map((c, i) => [i ? ", " : null, h("code", {}, c)]), "."));
    }
    if (ex.policy) wrap.append(h("p", { class: "faint" }, "policy: ", h("code", {}, ex.policy)));
    return wrap;
  }

  /* --- the index ---------------------------------------------------------------- */
  function index(el, view, byId) {
    el.append(h("h2", {}, "Vendors"));
    el.append(web.freshness(view));
    el.append(header(view));
    el.append(countsLine(view.counts));

    /* Search hides the blocks and proposals that do not mention the query.
       Counting what is left is the one figure the browser derives. */
    const searchable = [];
    const status = h("p", { class: "faint", role: "status", hidden: true });
    el.append(status);

    if (view.vendors.length) {
      el.append(h("h3", {}, "Vendor × repo"));
      el.append(matrix(view, byId, searchable));
    } else {
      el.append(h("p", { class: "empty" }, "No vendor in the map: none ", NOT_IN_CODE, ", and ",
        view.sources.dns.missing ? "no DNS reading has been taken" : "none " + NOT_IN_DNS, "."));
    }

    el.append(h("h3", {}, "Proposals"));
    if (view.advise.missing) {
      el.append(web.freshness(view.sources.advise));
    } else if (view.proposals.length) {
      el.append(h("p", { class: "muted" },
        plural(view.counts.proposals, "proposal") + " — " + view.counts.high + " high, " + view.counts.medium + " medium. ",
        "Confidence first, blast radius second, id last. Each id is stable, so an answer to it sticks: copy the command under a proposal, give the reason, and it is gone from the next run."));
      const ol = h("ol", { class: "props" });
      for (const p of view.proposals) {
        const li = proposal(p, view, byId);
        searchable.push([li, [p.id, p.kind, p.claim, (p.vendors || []).join(" "), (p.repos || []).join(" ")].join(" ")]);
        ol.append(li);
      }
      el.append(ol);
    } else {
      el.append(h("p", { class: "empty" }, "Nothing proposed. ", view.counts.answered ? "What the team already answered is below." : ""));
    }

    if (view.answered.length) {
      el.append(h("h3", {}, "Answered"));
      el.append(h("p", { class: "muted" }, "Answered already — kept here so the answer is not lost with the proposal. To change one, supersede the note: ",
        h("code", {}, "orgami note --supersede <note-id> --repo <repo> \"<reason>\""), "."));
      const ul = h("ul", { class: "props" });
      for (const a of view.answered) {
        const li = answered(a, view, byId);
        searchable.push([li, [a.id, a.reason, a.author, a.note.id].join(" ")]);
        ul.append(li);
      }
      el.append(ul);
    }

    if (view.excluded && ((view.excluded.duplicate_category || []).length || (view.excluded.ghost_env_var || []).length)) {
      el.append(h("h3", {}, "Not proposed, on purpose"));
      el.append(excluded(view.excluded, byId));
    }

    web.onSearch(q => {
      let shown = 0;
      for (const [node, text] of searchable) {
        const hit = !q || text.toLowerCase().includes(q);
        node.hidden = !hit;
        if (hit) shown++;
      }
      status.hidden = !q;
      status.textContent = q ? shown + " of " + searchable.length + " blocks mention “" + q + "”" : "";
    });
  }

  /* --- one vendor: #/vendors/<id> ---------------------------------------------- */
  function page(el, view, byId, id) {
    const v = byId[id];
    el.append(h("p", { class: "crumb" }, h("a", { href: "#/vendors" }, "Vendors"), " / ", v ? v.name : id));
    if (!v) {
      el.append(h("h2", {}, id));
      el.append(web.freshness(view));
      el.append(h("p", { class: "empty" }, "No vendor under that name in the map: ", NOT_IN_CODE, ", ",
        view.sources.dns.missing ? "and no DNS reading has been taken" : "and " + NOT_IN_DNS, "."));
      return;
    }
    el.append(h("h2", {}, v.name, " ", tag(v.category || "no category", "kind-vendor"), sourceTag(v.source), substTag(v.substitutable),
      (v.flags || []).map(f => tag(f, "flag"))));
    el.append(web.freshness(view));
    if (v.portal) el.append(h("p", { class: "faint" }, "billing portal: ", h("a", { href: v.portal, target: "_blank", rel: "noopener" }, v.portal)));

    el.append(h("h3", {}, "Repositories"));
    if (v.code.length) {
      el.append(web.table([
        { key: "repo", label: "repo", render: r => h("a", { href: repoHref(r.repo), class: "mono" }, r.repo) },
        { key: "signal", label: "matched by", render: r => r.signal ? h("code", {}, r.signal) : "" },
        { key: "at", label: "evidence", render: r => web.evidence({ kind: r.confidence, at: r.at, repo: r.repo }) },
      ], v.code));
      el.append(h("p", { class: "faint" }, plural(v.repos.length, "repository", "repositories") + " name " + v.name + ". Any other repository: " + NOT_IN_CODE + "."));
    } else {
      el.append(h("p", { class: "empty" }, "No repository names " + v.name + ": " + NOT_IN_CODE + ".",
        v.source === "dns" ? " " + DNS_ONLY.charAt(0).toUpperCase() + DNS_ONLY.slice(1) + "." : ""));
    }

    el.append(h("h3", {}, "Cost"));
    if (v.cost) {
      el.append(h("p", { class: "money" }, figure(v.cost)));
      if (v.cost.note) el.append(h("p", { class: "faint" }, v.cost.note));
      el.append(h("p", { class: "faint" }, "Typed, not read from an invoice. To change it: ",
        h("code", {}, "orgami cost " + v.id + " <amount>"), " · to drop it: ", h("code", {}, "orgami cost --remove " + v.id), "."));
    } else {
      el.append(h("p", { class: "empty" }, "No figure typed for " + v.name + ". Nothing under the company directory knows what it costs; a person who does can record it:"));
      el.append(h("pre", { class: "cmd", tabindex: "0", "aria-label": "command to record what this vendor costs" }, costCommand(v.id)));
    }

    el.append(h("h3", {}, "Public DNS"));
    if (view.sources.dns.missing) {
      el.append(web.freshness(view.sources.dns));
    } else if (v.dns.length) {
      el.append(web.table([
        { key: "domain", label: "domain", render: r => h("span", { class: "mono" }, r.domain) },
        { key: "signal", label: "record", render: r => r.signal ? h("code", {}, r.signal) : "" },
        { key: "at", label: "evidence", render: r => reading(r.at, view) },
      ], v.dns));
    } else {
      el.append(h("p", { class: "empty" }, v.name + " " + NOT_IN_DNS + " of " + ((view.sources.dns.domains || []).join(", ") || "the configured domains") + "."));
    }

    el.append(h("h3", {}, "What advise says"));
    if (view.advise.missing) {
      el.append(web.freshness(view.sources.advise));
    } else {
      const a = v.advise;
      const any = a.proposals.length || a.answered.length || a.excluded.length;
      if (!any) {
        el.append(h("p", { class: "empty" }, "Nothing. No proposal names " + v.name + ", none was answered, and none was held back."));
      } else {
        const ul = h("ul", { class: "says" });
        for (const p of a.proposals) {
          const full = view.proposals.find(x => x.id === p.id);
          ul.append(h("li", {}, h("a", { href: "#/vendors", class: "mono" }, "#" + p.rank), " ",
            kindTag(p.kind), confTag(p.confidence), h("code", { class: "pid" }, p.id),
            full ? h("p", { class: "claim" }, full.claim) : null));
        }
        for (const s of a.answered) {
          const full = view.answered.find(x => x.id === s.id);
          ul.append(h("li", {}, tag("answered", "ans"), kindTag(s.kind), h("code", { class: "pid" }, s.id),
            full ? h("div", { class: "answer" }, web.evidence({ kind: "human", text: full.reason, author: full.author, date: full.date })) : null));
        }
        for (const x of a.excluded) {
          ul.append(h("li", {}, tag("not proposed, on purpose", "excl"), kindTag(x.kind), h("code", { class: "pid" }, x.id),
            h("div", { class: "faint" }, x.reason)));
        }
        el.append(ul);
      }
    }
  }

  web.register({
    id: "vendors",
    title: "Vendors",
    needs: ["map/graph.json", "map/dns.json", "map/advise.json", "map/costs.json", "notes/"],
    render(el, view, all, route) {
      const byId = {};
      for (const v of view.vendors || []) byId[v.id] = v;
      if (route.parts.length) page(el, view, byId, route.parts[0]);
      else index(el, view, byId);
    },
  });
})();
