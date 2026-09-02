"use strict";
/* Live: what the providers said is running against what the committed files
   declare, and what the DNS said the org has an account with. Two readings,
   two freshness lines, and nothing here is the map — every row says which
   provider or query it came from and when (rule 2, "reading"). The figures
   are jq's (lib/web/50-live.jq); this file only draws them and counts what
   the search box is currently filtering. */
web.register({
  id: "live",
  title: "Live",
  needs: ["map/live.json", "map/dns.json", "map/graph.json"],
  render(el, view, all) {
    const h = web.h;

    /* A reading goes stale on the reader's clock, never in the file: seven
       days for a provider, ninety for DNS — the thresholds lib/live.sh and
       lib/dns.sh use. */
    const withStale = r => {
      if (!r || r.missing || !r.generated || !r.stale_after_days) return r;
      const t = Date.parse(r.generated);
      const days = Number.isNaN(t) ? 0 : (Date.now() - t) / 86400000;
      return Object.assign({}, r, { stale: days >= r.stale_after_days });
    };
    const ageOf = r => (r && r.generated && web.age(r.generated)) || null;
    const link = u => h("a", { href: "https://" + u, target: "_blank", rel: "noopener", class: "mono" }, u);
    const urls = list => h("span", { class: "urls" }, (list || []).map(link));
    const repoLink = r => r ? h("a", { href: "#/repos/" + encodeURIComponent(r) }, r) : "";
    const vendorLink = v => h("a", { href: "#/vendors/" + encodeURIComponent(v.id) }, v.name);
    const tag = (text, cls) => h("span", { class: "tag " + (cls || "") }, text);

    /* A table the search box filters. `text(row)` is what a row is matched
       against; the count shown is the count on the page, not the org's. */
    const filtered = (cols, rows, text) => {
      const box = h("div", { class: "filtered" });
      const draw = q => {
        const list = q ? rows.filter(r => text(r).toLowerCase().includes(q)) : rows;
        box.replaceChildren(list.length
          ? web.table(cols, list)
          : h("p", { class: "empty" }, "nothing on this page matches “" + q + "”"));
        if (q && list.length !== rows.length) {
          box.append(h("p", { class: "faint count" }, list.length + " of " + rows.length + " rows shown"));
        }
      };
      draw(web.query());
      web.onSearch(draw);
      return box;
    };

    el.append(h("h2", {}, "Live"));
    el.append(h("p", { class: "muted lede" },
      "What the providers and the DNS answered, beside what the committed files declare. ",
      "A reading expires and cannot be opened at a line; the map can."));

    /* --- what is running ----------------------------------------------- */
    const live = withStale(view.live);
    el.append(h("h3", {}, "Deployed"));
    el.append(web.freshness(live));
    if (live && !live.missing) {
      const c = live.counts || {};
      const readAgo = ageOf(live);
      el.append(h("p", { class: "muted" },
        c.deployments + (c.deployments === 1 ? " deployment" : " deployments") + " tied to " +
        c.repos + (c.repos === 1 ? " repo" : " repos") + " across " +
        c.read + " of " + c.providers + (c.providers === 1 ? " provider" : " providers") + " asked · " +
        c.configured + " deploy target" + (c.configured === 1 ? "" : "s") + " in committed configuration · " +
        c.not_seen + " configured, not seen · " +
        c.not_configured + " seen, not in committed configuration"));

      for (const p of live.providers || []) {
        const head = h("h4", {}, p.provider, " ",
          h("span", { class: "faint" }, p.error ? "not read" : p.deployments.length + (p.deployments.length === 1 ? " deployment" : " deployments")));
        el.append(head);
        if (p.error) {
          el.append(h("div", { class: "panel warn" }, h("code", {}, p.provider), " could not be read: ", p.error,
            " — ", h("code", {}, "orgami live --provider " + p.provider)));
          continue;
        }
        if (!p.deployments.length) {
          el.append(h("p", { class: "empty" }, "no deployment tied to a repo was found on " + p.provider + " — the unattributed ones are below"));
          continue;
        }
        const hasRegion = p.deployments.some(d => d.region);
        const hasUpdated = p.deployments.some(d => d.updated);
        const cols = [
          { key: "repo", label: "repo", render: d => repoLink(d.repo) },
          { key: "name", label: "name", render: d => h("code", {}, d.name) },
          { key: "state", label: "state", render: d => d.state ? tag(d.state, "state") : "" },
          { key: "urls", label: "urls", render: d => urls(d.urls), sort: d => (d.urls || [])[0] || null },
        ];
        if (hasRegion) cols.push({ key: "region", label: "region" });
        if (hasUpdated) cols.push({ key: "updated", label: "updated", render: d => d.updated ? web.day(d.updated) : "", sort: d => d.updated });
        cols.push({ key: "account", label: "account", render: d => d.account ? h("span", { class: "faint" }, d.account) : "" });
        cols.push({ key: "evidence", label: "evidence", render: d => h("div", { class: "evs" },
          web.evidence({ kind: "reading", command: d.reading.command, date: live.generated }),
          h("span", { class: "faint" }, d.reading.text),
          d.declared ? web.evidence(d.declared) : h("span", { class: "faint" }, "no deploys-to edge names one of these hosts")),
          sort: d => d.match });
        el.append(filtered(cols, p.deployments, d => [d.repo, d.name, d.state, (d.urls || []).join(" "), d.account, d.region].join(" ")));
      }

      /* Errors for a provider that was asked but is not in the list of
         providers read, so nothing above drew it. */
      const orphanErrors = (live.errors || []).filter(e => !(live.providers || []).some(p => p.provider === e.provider));
      if (orphanErrors.length) {
        el.append(h("h4", {}, "not read"));
        el.append(h("ul", { class: "plain" }, orphanErrors.map(e =>
          h("li", {}, h("code", {}, e.provider), " — ", e.message, " · ", h("code", {}, "orgami live --provider " + e.provider)))));
      }

      /* --- the two diffs ------------------------------------------------- */
      if ((live.not_seen || []).length) {
        el.append(h("h3", {}, "Configured, not seen"));
        el.append(h("p", { class: "muted" },
          "A deploys-to edge in the committed files, and no deployment tied to that repo on that provider",
          readAgo ? " — the reading is " + readAgo + " old." : ".",
          " A provider that was not asked cannot have answered: those rows say so."));
        const read = (live.providers || []).map(p => p.provider);
        el.append(filtered([
          { key: "repo", label: "repo", render: r => repoLink(r.repo) },
          { key: "host", label: "host", render: r => h("code", {}, r.host) },
          { key: "provider", label: "provider", render: r => r.provider
              ? h("span", {}, r.provider, " ", r.provider_read ? tag("read", "ok") : tag("not read", "warn"))
              : h("span", { class: "faint" }, "not found in the file") },
          { key: "why", label: "reading", render: r => r.provider_read
              ? h("span", { class: "faint" }, "nothing on " + r.provider + " is tied to " + r.repo)
              : h("span", { class: "faint" }, (read.length ? "read: " + read.join(", ") : "no provider read") + (r.provider ? " — not " + r.provider : "")),
            sort: r => r.provider_read ? 0 : 1 },
          { key: "evidence", label: "evidence", render: r => web.evidence(r.evidence), sort: r => r.evidence.at },
        ], live.not_seen, r => [r.repo, r.host, r.provider, r.evidence.at].join(" ")));
      }

      if ((live.not_configured || []).length) {
        el.append(h("h3", {}, "Seen, not in committed configuration"));
        el.append(h("p", { class: "muted" },
          "Running on the account and tied to no repo: no deploys-to edge, no git link, no tag, no repo of exactly that name. ",
          "Usually a preview nobody cleaned up or a service nobody remembers owning."));
        el.append(filtered([
          { key: "provider", label: "provider" },
          { key: "name", label: "name", render: r => h("code", {}, r.name) },
          { key: "state", label: "state", render: r => r.state ? tag(r.state, "state") : "" },
          { key: "urls", label: "urls", render: r => urls(r.urls), sort: r => (r.urls || [])[0] || null },
          { key: "evidence", label: "evidence", render: r => web.evidence({ kind: "reading", command: r.source, date: live.generated }), sort: r => r.source },
        ], live.not_configured, r => [r.provider, r.name, r.state, (r.urls || []).join(" ")].join(" ")));
      }
    }

    /* --- DNS ------------------------------------------------------------- */
    const dns = withStale(view.dns);
    el.append(h("h3", {}, "DNS"));
    el.append(web.freshness(dns));
    if (!dns || dns.missing) return;

    const dc = dns.counts || {};
    el.append(h("p", { class: "muted" },
      "Read " + dc.records + " record" + (dc.records === 1 ? "" : "s") + " across " +
      dc.domains + " domain" + (dc.domains === 1 ? "" : "s") + " from " + dc.queries + " quer" + (dc.queries === 1 ? "y" : "ies") + " — " +
      dc.records_matched + " matched the catalogue and " + dc.records_unmatched + " matched nothing and were not recorded. ",
      dns.origin ? "Domains from " + dns.origin + ". " : "",
      "A vendor that does not appear was not found in this organization's public DNS, which is not the same fact as not being in use."));

    for (const k of dns.by_kind || []) {
      el.append(h("h4", {}, k.label, " ", h("span", { class: "faint" }, k.records.length + (k.records.length === 1 ? " record" : " records"))));
      el.append(filtered([
        { key: "domain", label: "domain", render: r => h("code", {}, r.domain) },
        { key: "vendors", label: "matched", render: r => h("span", { class: "vendors" }, r.vendors.map(v =>
            h("span", { class: "vendor" }, vendorLink(v), " ", tag(v.category, "kind-vendor")))),
          sort: r => r.vendors.map(v => v.name).join(", ") },
        { key: "at", label: "record", render: r => web.evidence({ kind: "reading",
            command: r.dig ? r.at.replace(" (dig " + r.dig + ")", "") : r.at, date: r.dig }), sort: r => r.at },
      ], k.records, r => [r.domain, r.at, r.vendors.map(v => v.name + " " + v.category).join(" ")].join(" ")));
    }
    if (dc.omitted > 0) {
      el.append(h("p", { class: "faint" }, dc.omitted + " more record" + (dc.omitted === 1 ? "" : "s") +
        " carried the same signals for the same vendors and " + (dc.omitted === 1 ? "is" : "are") + " counted, not repeated — three of each kind per domain are kept."));
    }

    if ((dns.read || []).length) {
      el.append(h("h4", {}, "Domains read"));
      el.append(web.table([
        { key: "domain", label: "domain", render: r => h("code", {}, r.domain) },
        { key: "records", label: "records", num: true },
        { key: "matched", label: "matched", num: true },
      ], dns.read));
    }
    if ((dns.skipped || []).length) {
      el.append(h("p", { class: "muted" }, "Not queried: ", dns.skipped.map((d, i) => [i ? ", " : "", h("code", {}, d)]),
        " — owned by a provider, or past the cap (", h("code", {}, "dns_max_domains"), ")."));
    }
    if ((dns.errors || []).length) {
      el.append(h("h4", {}, "not read"));
      el.append(h("ul", { class: "plain" }, dns.errors.map(e =>
        h("li", {}, h("code", {}, e.domain || e.provider || ""), " — ", e.message || String(e)))));
    }
  },
});
