"use strict";
/* The shell: nav, hash router, the view registry, and the components every
   view draws with so the page reads as one thing. A view is a file beside this
   one that calls web.register(); nothing here knows any view by name.

   Nothing in this file touches the network, and nothing in it draws a number
   the page presents as the org's: the figures come from the payload, computed
   by jq. The one clock used is for "read <age> ago", which is the reader's
   clock at the moment they look, not something written into the file. */
const web = (() => {
  const DATA = JSON.parse(document.getElementById("data").textContent);
  DATA.views = DATA.views || {};
  DATA.repos = DATA.repos || {};

  const KINDS = ["repo", "host", "tool", "service", "vendor", "lang"];
  const EVIDENCE = ["extracted", "inferred", "reading", "human", "model"];
  const views = [];
  const byId = new Map();
  let booted = false;
  let searchListeners = [];

  /* --- tiny DOM helpers ------------------------------------------------ */
  const esc = s => String(s ?? "");
  function h(tag, attrs, ...kids) {
    const el = document.createElement(tag);
    if (attrs) {
      for (const [k, v] of Object.entries(attrs)) {
        if (v == null || v === false) continue;
        if (k === "class") el.className = v;
        else if (k === "text") el.textContent = v;
        else if (k.startsWith("on") && typeof v === "function") el.addEventListener(k.slice(2), v);
        else if (k === "dataset") Object.assign(el.dataset, v);
        else el.setAttribute(k, v === true ? "" : v);
      }
    }
    append(el, kids);
    return el;
  }
  function append(el, kids) {
    for (const k of kids) {
      if (k == null || k === false) continue;
      if (Array.isArray(k)) { append(el, k); continue; }
      el.append(k instanceof Node ? k : document.createTextNode(String(k)));
    }
    return el;
  }
  const frag = () => document.createDocumentFragment();

  /* --- time --------------------------------------------------------------
     A reading's age is relative to whoever is looking, so it is computed
     here and never written into the file. */
  function age(iso) {
    const t = Date.parse(iso);
    if (Number.isNaN(t)) return null;
    const s = Math.max(0, (Date.now() - t) / 1000);
    const units = [["year", 31536000], ["month", 2592000], ["week", 604800],
                   ["day", 86400], ["hour", 3600], ["minute", 60]];
    for (const [name, secs] of units) {
      const n = Math.floor(s / secs);
      if (n >= 1) return n + " " + name + (n === 1 ? "" : "s");
    }
    return "moments";
  }
  const day = iso => (iso || "").slice(0, 10);

  /* --- shared components ------------------------------------------------ */

  /* The line every view opens with (rule 4): how old the reading is, or which
     command produces it. `view` is the object a view's .jq emitted, or any
     object with `generated`, `missing`, optionally `stale` and `command`. */
  function freshness(view) {
    if (!view || view.missing) {
      const cmd = (view && view.missing) || "orgami scan";
      return h("div", { class: "fresh missing", role: "status" },
        "not run yet — ", h("code", {}, cmd));
    }
    if (!view.generated) {
      return h("div", { class: "fresh missing", role: "status" }, "no date on this reading");
    }
    const a = age(view.generated);
    const el = h("div", { class: "fresh", role: "status" },
      h("span", {}, a ? "read " + a + " ago" : "read " + view.generated),
      h("span", { class: "faint" }, day(view.generated)));
    if (view.stale) el.append(h("span", { class: "stale" }, "stale"));
    if (view.command) el.append(h("span", {}, "refresh: ", h("code", {}, view.command)));
    return el;
  }

  /* Nothing. A section with nothing in it is not drawn (rule 4). */
  function empty() { return frag(); }

  /* Evidence, one of five kinds (rule 2), marked the same way everywhere:
       extracted  {at: "file:line", repo}       a line you can open — a GitHub
                                                blob link when the repo has a url
       inferred   {at}                          matched, not declared
       reading    {at | command, date}          an answer a provider or DNS gave
       human      {author, date, text?}         a note, a rejection, a cost
       model      {text?}                       prose written by a model
     `url` overrides the repo lookup. Anything else in `e` is ignored. */
  function evidence(e) {
    e = e || {};
    const kind = EVIDENCE.includes(e.kind) ? e.kind : "extracted";
    const el = h("span", { class: "ev " + kind });
    if (kind === "extracted") {
      const at = esc(e.at);
      const m = /^([^\s:]+):(\d+)$/.exec(at);
      const repo = e.repo && DATA.repos[e.repo];
      const base = e.url || (repo && repo.url) || null;
      if (m && base) {
        el.append(h("a", { href: base + "/blob/HEAD/" + m[1] + "#L" + m[2], target: "_blank", rel: "noopener", class: "mono" }, at));
      } else if (at) {
        el.append(h("code", {}, at));
      }
      if (e.repo && !m) el.append(h("span", { class: "faint" }, e.repo));
    } else if (kind === "inferred") {
      el.append(h("code", {}, "~ " + esc(e.at)));
    } else if (kind === "reading") {
      el.append(h("code", {}, esc(e.command || e.at)));
      if (e.date) el.append(h("span", { class: "faint" }, day(e.date)));
    } else if (kind === "human") {
      if (e.text) el.append(h("span", {}, esc(e.text)));
      el.append(h("span", { class: "faint" }, [esc(e.author), day(e.date)].filter(Boolean).join(", ")));
    } else {
      el.append(h("span", {}, esc(e.text || "written by a model from the evidence beneath")));
    }
    el.append(h("span", { class: "tag " + kind }, kind));
    return el;
  }

  /* A table. cols: ["key", …] or [{key, label, num, render(row), sort(row)}];
     rows: objects. Click a header to sort what is on the page — the browser
     may order and count what it shows; it derives no org-level figure. */
  function table(cols, rows) {
    cols = cols.map(c => typeof c === "string" ? { key: c, label: c } : c);
    rows = rows || [];
    const wrap = h("div", { class: "scroll" });
    const t = h("table", { class: "t" });
    const thead = h("thead"), tr = h("tr");
    const tbody = h("tbody");
    let sortKey = null, dir = 1;
    const cell = (c, r) => {
      const v = c.render ? c.render(r) : r[c.key];
      return h("td", { class: c.num ? "num" : null }, v == null ? "" : v);
    };
    const draw = () => {
      let list = rows.slice();
      if (sortKey) {
        const c = cols.find(x => x.key === sortKey);
        const val = r => c.sort ? c.sort(r) : r[c.key];
        list.sort((a, b) => {
          const x = val(a), y = val(b);
          if (x == null && y == null) return 0;
          if (x == null) return 1;
          if (y == null) return -1;
          return (typeof x === "number" && typeof y === "number" ? x - y : String(x).localeCompare(String(y))) * dir;
        });
      }
      tbody.replaceChildren(...list.map(r => h("tr", {}, cols.map(c => cell(c, r)))));
    };
    for (const c of cols) {
      const b = h("button", { type: "button", onclick: () => {
        if (sortKey === c.key) dir = -dir; else { sortKey = c.key; dir = 1; }
        for (const x of tr.querySelectorAll("button")) x.removeAttribute("aria-sort");
        b.setAttribute("aria-sort", dir === 1 ? "ascending" : "descending");
        draw();
      } }, c.label ?? c.key);
      tr.append(h("th", { class: c.num ? "num" : null, scope: "col" }, b));
    }
    thead.append(tr);
    t.append(thead, tbody);
    draw();
    wrap.append(t);
    return wrap;
  }

  /* --- registry, nav, router -------------------------------------------- */
  const main = document.getElementById("main");
  const nav = document.getElementById("nav");
  const sub = document.getElementById("sub");
  const foot = document.getElementById("foot");
  const search = document.getElementById("q");

  /* web.register({id, title, needs: ["map/graph.json", …], render(el, view, all, route)}).
     `needs` names the source files the view reads, for the panel drawn when
     its payload is missing. Registration order is file order, which is nav
     order. */
  function register(v) {
    if (!v || !v.id || typeof v.render !== "function") return;
    if (byId.has(v.id)) return;
    views.push(v);
    byId.set(v.id, v);
    if (booted) { drawNav(); route(); }
  }

  function parseHash() {
    const raw = location.hash.replace(/^#\/?/, "");
    const parts = raw.split("/").filter(Boolean).map(p => { try { return decodeURIComponent(p); } catch (_) { return p; } });
    return { id: parts[0] || "", rest: parts.slice(1).join("/"), parts: parts.slice(1) };
  }
  let current = parseHash();
  const route = () => { current = parseHash(); render(); };

  function drawNav() {
    nav.replaceChildren(...views.map(v => h("a", { href: "#/" + v.id, "aria-current": current.id === v.id ? "page" : null }, v.title || v.id)));
  }

  function mapLine() {
    const m = DATA.map || {};
    const bits = [DATA.org];
    if (m.generated) bits.push("mapped " + day(m.generated));
    else bits.push("not mapped yet");
    return bits.filter(Boolean).join(" · ");
  }

  function home() {
    const el = h("section", { class: "view", dataset: { view: "home" } });
    el.append(h("h2", {}, DATA.org || DATA.company || "orgami"));
    el.append(freshness(DATA.map));
    if (views.length) {
      el.append(h("p", { class: "muted" }, "Pick a view above."));
    } else {
      el.append(h("p", { class: "muted" }, "No view is registered. A view is one file each under lib/web/ — see docs/web.md."));
    }
    return el;
  }

  function render() {
    searchListeners = [];
    drawNav();
    sub.textContent = mapLine();
    main.replaceChildren();
    const r = current;
    if (!r.id) {
      if (views.length) { location.replace("#/" + views[0].id); return; }
      main.append(home());
      return;
    }
    const v = byId.get(r.id);
    if (!v) {
      main.append(h("section", { class: "view" }, h("h2", {}, r.id), h("p", { class: "muted" }, "No view is registered under that name.")));
      return;
    }
    const data = DATA.views[v.id];
    const el = h("section", { class: "view", dataset: { view: v.id } });
    main.append(el);
    if (!data || data.missing) {
      /* A view whose payload is missing shows the freshness panel only. */
      el.append(h("h2", {}, v.title || v.id));
      el.append(freshness(data || { missing: (v.needs && v.needs.length ? "orgami scan — for " + v.needs.join(", ") : "orgami scan") }));
      return;
    }
    try {
      v.render(el, data, DATA, r);
    } catch (err) {
      el.append(h("div", { class: "error" }, "the " + v.id + " view did not draw: " + (err && err.message ? err.message : String(err))));
    }
  }

  /* --- search ------------------------------------------------------------- */
  const query = () => search.value.trim().toLowerCase();
  const onSearch = fn => { searchListeners.push(fn); };
  search.addEventListener("input", () => {
    const q = query();
    for (const fn of searchListeners) fn(q);
    document.dispatchEvent(new CustomEvent("web:search", { detail: q }));
  });
  document.addEventListener("keydown", ev => {
    const typing = ev.target && (ev.target.tagName === "INPUT" || ev.target.tagName === "TEXTAREA");
    if (ev.key === "/" && !typing) { ev.preventDefault(); search.focus(); search.select(); }
    else if (ev.key === "Escape" && ev.target === search) { search.value = ""; search.dispatchEvent(new Event("input")); search.blur(); }
  });

  /* --- the key ---------------------------------------------------------- */
  foot.replaceChildren(
    evidence({ kind: "extracted", at: "file:line" }),
    evidence({ kind: "inferred", at: "matched" }),
    evidence({ kind: "reading", command: "provider or dns", date: null }),
    evidence({ kind: "human", author: "author", date: "date" }),
    evidence({ kind: "model", text: "written by a model" }),
    h("span", {}, "/ search · tab moves · esc clears"));

  function boot() {
    booted = true;
    window.addEventListener("hashchange", route);
    route();
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();

  return {
    data: DATA, kinds: KINDS, evidenceKinds: EVIDENCE,
    register, route: () => current, views: () => views.slice(),
    h, frag, esc, age, day,
    freshness, empty, evidence, table,
    search, query, onSearch,
    color: k => getComputedStyle(document.documentElement).getPropertyValue("--" + k).trim() || "#888",
  };
})();
