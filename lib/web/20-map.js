"use strict";
/* The map: graph.html's force layout, ported. Same simulation, same layout
   seeded from node ids so the same map draws the same way for everyone, same
   filters, same panel — drawn with the shell's components so the evidence
   under every edge is marked the way it is marked on every other view.

   Beyond graph.html: an edge-kind filter with the extracted/inferred split in
   its legend, a way from a node to its page on the Repos or Vendors view, and
   the corners — nodes with no edges and repos nothing points at — as a list,
   because a picture shows them in a second and a table never does.

   The page is one document with several views, so this one has to stop when
   it is left: the animation loop and the window listeners check that their
   section is still in the document and go quiet when it is not. */
(() => {
  const h = web.h;
  const KINDS = web.kinds;
  const RADIUS = { repo: 8, host: 6, tool: 5.5, service: 6, vendor: 6, lang: 4.5 };
  const bare = id => id.replace(/^[a-z-]+:/, "");

  /* Layout is seeded from the node id, not Math.random, so the same map draws
     the same way for everyone who opens it — a screenshot in a pull request
     matches what the next person sees. */
  function seeded(str) {
    let h = 2166136261 >>> 0;
    for (let i = 0; i < str.length; i++) { h ^= str.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; }
    return () => { h ^= h << 13; h >>>= 0; h ^= h >> 17; h ^= h << 5; h >>>= 0; return h / 4294967296; };
  }

  /* One instance per render. The previous one is left to notice its section
     is gone and stop. */
  let live = null;

  function render(el, view, all, route) {
    el.append(h("h2", {}, "Map"));
    el.append(web.freshness(view));

    const counts = view.counts || {};
    const byId = new Map();
    const nodes = (view.nodes || []).map((n, i) => {
      const r = seeded(n.id);
      const a = r() * Math.PI * 2, d = 120 + r() * 320;
      const node = { ...n, x: Math.cos(a) * d, y: Math.sin(a) * d, vx: 0, vy: 0,
                     deg: 0, r: RADIUS[n.kind] || 5, i };
      byId.set(n.id, node);
      return node;
    });
    const edges = (view.edges || []).filter(e => byId.has(e.from) && byId.has(e.to)).map(e => ({
      ...e, s: byId.get(e.from), t: byId.get(e.to),
    }));
    for (const e of edges) { e.s.deg++; e.t.deg++; }
    for (const n of nodes) n.r += Math.min(6, Math.sqrt(n.deg) * 1.4);

    const depthBy = new Map(((view.depth && view.depth.repos) || []).map(r => [r.name, r]));
    const liveBy = new Map();
    for (const d of ((view.live && view.live.deployments) || [])) {
      if (!liveBy.has(d.repo)) liveBy.set(d.repo, []);
      liveBy.get(d.repo).push(d);
    }

    /* --- state ---------------------------------------------------------- */
    const kindOn = Object.fromEntries(KINDS.map(k => [k, true]));
    const edgeKinds = (counts.edge_kinds || []).map(k => k.kind);
    const edgeKindOn = Object.fromEntries(edgeKinds.map(k => [k, true]));
    let showInferred = true, query = web.query();
    let viewport = { x: 0, y: 0, k: 1 }, dpr = 1, W = 0, H = 0;
    let hover = null, selected = null, dragging = null, panning = null;
    let userMoved = false, alpha = 1;
    const COLOR = {};
    let CSS_LINE = "#ccc", CSS_INK = "#222";

    const matches = n => !query || n.name.toLowerCase().includes(query) ||
      (n.description || "").toLowerCase().includes(query);
    const nodeVisible = n => kindOn[n.kind] !== false;
    const edgeVisible = e => nodeVisible(e.s) && nodeVisible(e.t) &&
      edgeKindOn[e.kind] !== false && (showInferred || e.confidence !== "inferred");

    /* --- the chrome ----------------------------------------------------- */
    const sub = h("p", { class: "map-counts muted" },
      [view.org, counts.repos + " repos", counts.edges + " edges",
       counts.extracted + " extracted, " + counts.inferred + " inferred"].filter(Boolean).join(" · "));
    el.append(sub);

    const chip = (label, count, color, pressed, onclick) => {
      const b = h("button", { type: "button", class: "chip", "aria-pressed": String(pressed), onclick });
      if (color) { b.style.color = color; b.append(h("span", { class: "dot" })); }
      b.append(h("span", { class: "chip-label" }, label, " ", h("span", { class: "muted" }, count)));
      return b;
    };

    const kindsEl = h("div", { class: "map-toggles", role: "group", "aria-label": "node kinds" });
    for (const k of KINDS) {
      const count = (counts.by_kind || {})[k] || 0;
      if (!count) continue;
      const b = chip(k, count, null, true, () => {
        kindOn[k] = !kindOn[k];
        b.classList.toggle("off", !kindOn[k]);
        b.setAttribute("aria-pressed", String(kindOn[k]));
        if (selected && !nodeVisible(selected)) show(null);
        alpha = Math.max(alpha, 0.4);
        if (!userMoved) fit();
        drawCorners();
      });
      b.dataset.kind = k;
      b.prepend(h("span", { class: "dot" }));
      kindsEl.append(b);
    }
    el.append(kindsEl);

    /* Edge kinds, each chip carrying the extracted/inferred split: the number
       of solid lines and the number of dashed ones it stands for. */
    const edgesEl = h("div", { class: "map-toggles", role: "group", "aria-label": "edge kinds" });
    for (const ek of (counts.edge_kinds || [])) {
      const b = h("button", { type: "button", class: "chip", "aria-pressed": "true", onclick: () => {
        edgeKindOn[ek.kind] = !edgeKindOn[ek.kind];
        b.classList.toggle("off", !edgeKindOn[ek.kind]);
        b.setAttribute("aria-pressed", String(edgeKindOn[ek.kind]));
        if (selected) show(selected);
      } });
      b.append(h("span", { class: "chip-label" }, ek.kind, " "));
      if (ek.extracted) b.append(h("span", { class: "key solid", title: ek.extracted + " extracted" }), h("span", { class: "muted" }, ek.extracted));
      if (ek.inferred) b.append(h("span", { class: "key dashed", title: ek.inferred + " inferred" }), h("span", { class: "muted" }, "~" + ek.inferred));
      edgesEl.append(b);
    }
    const infEl = h("button", { type: "button", class: "chip", "aria-pressed": "true", onclick: () => {
      showInferred = !showInferred;
      infEl.classList.toggle("off", !showInferred);
      infEl.setAttribute("aria-pressed", String(showInferred));
      if (selected) show(selected);
      drawCorners();
    } }, h("span", { class: "key dashed" }), "inferred edges ", h("span", { class: "muted" }, counts.inferred));
    edgesEl.append(infEl);
    el.append(edgesEl);

    const cv = h("canvas", { "aria-label": "the map", role: "img" });
    const stage = h("div", { class: "map-stage" }, cv);
    const panel = h("aside", { class: "map-panel", "aria-live": "polite", hidden: true });
    const wrap = h("div", { class: "map-wrap" }, stage, panel);
    el.append(wrap);
    el.append(h("p", { class: "map-key faint" },
      h("span", {}, h("span", { class: "key solid" }), " extracted — a line you can open"),
      h("span", {}, h("span", { class: "key dashed" }), " inferred — matched, not declared"),
      h("span", {}, "drag to move · scroll to zoom · click a node for its evidence")));

    const cornersEl = h("div", { class: "map-corners" });
    el.append(cornersEl);

    /* --- the simulation ---------------------------------------------------
       Plain repulsion, springs and a pull to the middle. A few hundred nodes
       do not need a quadtree, and the shape settles in well under a second. */
    const K_REPEL = 11000, K_SPRING = 0.022, LEN = 120, GRAVITY = 0.02, DAMP = 0.84;
    function tick() {
      for (let i = 0; i < nodes.length; i++) {
        const a = nodes[i];
        for (let j = i + 1; j < nodes.length; j++) {
          const b = nodes[j];
          let dx = b.x - a.x, dy = b.y - a.y;
          let d2 = dx * dx + dy * dy;
          if (d2 < 1) { d2 = 1; dx = (a.i - b.i) || 1; dy = 1; }
          const f = K_REPEL / d2, d = Math.sqrt(d2);
          const fx = (dx / d) * f, fy = (dy / d) * f;
          a.vx -= fx; a.vy -= fy; b.vx += fx; b.vy += fy;
        }
      }
      for (const e of edges) {
        const dx = e.t.x - e.s.x, dy = e.t.y - e.s.y;
        const d = Math.max(1, Math.hypot(dx, dy));
        const f = (d - LEN) * K_SPRING;
        const fx = (dx / d) * f, fy = (dy / d) * f;
        e.s.vx += fx; e.s.vy += fy; e.t.vx -= fx; e.t.vy -= fy;
      }
      for (const n of nodes) {
        n.vx -= n.x * GRAVITY; n.vy -= n.y * GRAVITY;
        if (n === dragging) { n.vx = n.vy = 0; continue; }
        n.vx *= DAMP; n.vy *= DAMP;
        n.x += n.vx * alpha; n.y += n.vy * alpha;
      }
      alpha = Math.max(0.03, alpha * 0.994);
    }

    /* Whatever shape the simulation settles into, put all of it on the
       screen. Cheaper than tuning constants that hold for one organization
       and not the next. */
    function fit() {
      const vis = nodes.filter(nodeVisible);
      if (!vis.length || !W || !H) return;
      let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
      for (const n of vis) {
        x0 = Math.min(x0, n.x); x1 = Math.max(x1, n.x);
        y0 = Math.min(y0, n.y); y1 = Math.max(y1, n.y);
      }
      const pad = 60;
      viewport.k = Math.min(2.2, Math.max(0.25,
        Math.min((W - pad * 2) / Math.max(1, x1 - x0), (H - pad * 2) / Math.max(1, y1 - y0))));
      viewport.x = -(x0 + x1) / 2;
      viewport.y = -(y0 + y1) / 2;
    }

    /* --- drawing -------------------------------------------------------- */
    const ctx = cv.getContext("2d");
    function resize() {
      dpr = window.devicePixelRatio || 1;
      W = cv.clientWidth; H = cv.clientHeight;
      cv.width = W * dpr; cv.height = H * dpr;
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    }
    const toScreen = n => ({ x: (n.x + viewport.x) * viewport.k + W / 2, y: (n.y + viewport.y) * viewport.k + H / 2 });
    const toWorld = (px, py) => ({ x: (px - W / 2) / viewport.k - viewport.x, y: (py - H / 2) / viewport.k - viewport.y });

    function readTheme() {
      const cs = getComputedStyle(document.documentElement);
      CSS_LINE = cs.getPropertyValue("--line").trim();
      CSS_INK = cs.getPropertyValue("--ink").trim();
      for (const k of KINDS) COLOR[k] = web.color(k);
      for (const b of kindsEl.children) b.style.color = COLOR[b.dataset.kind];
    }

    function draw() {
      ctx.clearRect(0, 0, W, H);
      const neighbours = new Set();
      if (selected) {
        neighbours.add(selected.id);
        for (const e of edges) {
          if (!edgeVisible(e)) continue;
          if (e.from === selected.id) neighbours.add(e.to);
          if (e.to === selected.id) neighbours.add(e.from);
        }
      }

      for (const e of edges) {
        if (!edgeVisible(e)) continue;
        const lit = selected && (e.from === selected.id || e.to === selected.id);
        const dim = (selected && !lit) || (query && !matches(e.s) && !matches(e.t));
        const a = toScreen(e.s), b = toScreen(e.t);
        ctx.beginPath();
        ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y);
        ctx.strokeStyle = lit ? COLOR[e.s.kind] : CSS_LINE;
        ctx.globalAlpha = dim ? 0.16 : (lit ? 0.85 : 0.5);
        ctx.lineWidth = lit ? 1.6 : 1;
        ctx.setLineDash(e.confidence === "inferred" ? [3, 3] : []);
        ctx.stroke();
      }
      ctx.setLineDash([]);
      ctx.globalAlpha = 1;

      const scale = Math.min(1.6, Math.max(0.7, viewport.k));
      for (const n of nodes) {
        if (!nodeVisible(n)) continue;
        const p = toScreen(n);
        const dim = (query && !matches(n)) || (selected && !neighbours.has(n.id));
        const rr = n.r * scale;
        ctx.globalAlpha = dim ? 0.2 : 1;
        ctx.beginPath();
        ctx.arc(p.x, p.y, rr, 0, Math.PI * 2);
        ctx.fillStyle = COLOR[n.kind] || "#888";
        ctx.fill();
        if (n === selected || n === hover) {
          ctx.lineWidth = 2;
          ctx.strokeStyle = COLOR[n.kind];
          ctx.globalAlpha = 0.45;
          ctx.beginPath(); ctx.arc(p.x, p.y, rr + 4, 0, Math.PI * 2); ctx.stroke();
        }
        ctx.globalAlpha = 1;
      }

      /* Labels last, and only where one fits. Two names drawn on top of each
         other are less readable than one name and a dot you can click, so a
         label that would collide with one already on the page is dropped —
         the important ones go first. Node discs are obstacles too. */
      const taken = [];
      for (const n of nodes) {
        if (!nodeVisible(n)) continue;
        const p = toScreen(n), rr = n.r * scale;
        taken.push({ x0: p.x - rr, x1: p.x + rr, y0: p.y - rr, y1: p.y + rr });
      }
      const wanted = nodes.filter(n => nodeVisible(n) &&
        !((query && !matches(n)) || (selected && !neighbours.has(n.id))) &&
        (n.kind === "repo" || viewport.k > 1.2 || (query && matches(n)) || n === hover || n === selected));
      /* Priority when there is not room for every name: whatever you asked
         for, then what you are pointing at, then the busiest nodes. */
      const rank = n => (n === selected || n === hover ? 3 : 0) + (query && matches(n) ? 2 : 0);
      wanted.sort((a, b) => rank(b) - rank(a) || b.deg - a.deg);
      for (const n of wanted) {
        const p = toScreen(n);
        if (p.x < -60 || p.x > W + 60 || p.y < -20 || p.y > H + 20) continue;
        const strong = n === selected || n === hover;
        ctx.font = (strong ? "600 " : "") + "11px ui-sans-serif, sans-serif";
        const w = ctx.measureText(n.name).width;
        const rr = n.r * scale;
        /* Above, below, right, left — a name pushed to one side still reads.
           Only when all four are blocked is the label worth losing. */
        const spots = [
          { dx: 0, dy: -rr - 10, align: "center" },
          { dx: 0, dy: rr + 14, align: "center" },
          { dx: rr + 6, dy: 4, align: "left" },
          { dx: -rr - 6, dy: 4, align: "right" },
        ];
        let placed = null;
        for (const sp of spots) {
          const cx = p.x + sp.dx, cy = p.y + sp.dy;
          const x0 = sp.align === "center" ? cx - w / 2 : sp.align === "left" ? cx : cx - w;
          const box = { x0: x0 - 2, x1: x0 + w + 2, y0: cy - 9, y1: cy + 3 };
          if (!taken.some(t => box.x0 < t.x1 && box.x1 > t.x0 && box.y0 < t.y1 && box.y1 > t.y0)) {
            placed = { box, cx, cy, align: sp.align };
            break;
          }
        }
        if (!placed) { if (!strong) continue; placed = { box: null, cx: p.x, cy: p.y - rr - 10, align: "center" }; }
        if (placed.box) taken.push(placed.box);
        ctx.textAlign = placed.align;
        ctx.fillStyle = CSS_INK;
        ctx.globalAlpha = strong ? 1 : (n.kind === "repo" ? 0.9 : 0.65);
        ctx.fillText(n.name, placed.cx, placed.cy);
      }
      ctx.textAlign = "center";
      ctx.globalAlpha = 1;
    }

    /* --- the panel ------------------------------------------------------ */
    const nodeButton = (n, cls) => h("button", { type: "button", class: "peer " + (cls || ""), onclick: () => { show(n); centre(n); } }, n.name);

    function show(node) {
      selected = node;
      if (!node) { panel.hidden = true; panel.replaceChildren(); resize(); if (!userMoved) fit(); return; }
      const groups = new Map();
      for (const e of edges) {
        if (e.from !== node.id && e.to !== node.id) continue;
        if (!edgeVisible(e)) continue;
        const out = e.from === node.id;
        const key = (out ? "" : "← ") + e.kind;
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push({ peer: byId.get(out ? e.to : e.from), e });
      }

      const d = depthBy.get(node.name), running = liveBy.get(node.name);
      const body = [];
      body.push(h("button", { type: "button", class: "close", title: "close", "aria-label": "close", onclick: () => show(null) }, "×"));
      body.push(h("h4", {}, node.name));
      body.push(h("div", { class: "kind" },
        [node.kind, node.language, node.private ? "private" : null].filter(Boolean).join(" · ")));
      if (node.description) body.push(h("p", { class: "desc muted" }, node.description));
      const links = [];
      if (node.url) links.push(h("a", { href: node.url, target: "_blank", rel: "noopener" }, "open on GitHub"));
      if (node.kind === "repo") links.push(h("a", { href: "#/repos/" + encodeURIComponent(node.name) }, "open in Repos"));
      if (node.kind === "vendor") links.push(h("a", { href: "#/vendors" }, "open in Vendors"));
      if (links.length) body.push(h("p", { class: "links" }, links));
      if (node.pushed) body.push(h("p", { class: "faint" }, "pushed " + web.day(node.pushed)));

      if (d) {
        body.push(h("h3", {}, "parsed"));
        body.push(h("div", {}, d.parsed + " files · " + d.symbol_count + " definitions · ",
          h("strong", {}, d.exported_count + " exported"), " · " + d.external_modules + " external packages"));
      }
      if (running && running.length) {
        body.push(h("h3", {}, "running now"));
        for (const x of running) {
          body.push(h("div", { class: "edge" },
            h("span", { class: "peer-name" }, x.provider + " " + x.name),
            h("span", { class: "ev-line" }, web.evidence({ kind: "reading", command: "orgami live", date: view.live && view.live.generated })),
            h("span", { class: "faint mono" }, [x.state, ...(x.urls || [])].filter(Boolean).join(" "))));
        }
      }

      if (!groups.size) {
        body.push(h("h3", {}, "edges"));
        body.push(h("p", { class: "empty" }, "Nothing in committed configuration links this to anything else — not found, which is not the same as not connected."));
      }
      for (const [kind, list] of groups) {
        body.push(h("h3", {}, kind));
        for (const { peer, e } of list) {
          /* The file an extracted edge names lives in the repo the edge
             leaves from; that is what turns file:line into a link. */
          const from = byId.get(e.from);
          const ev = e.confidence === "inferred"
            ? { kind: "inferred", at: e.evidence || "matched" }
            : { kind: "extracted", at: e.evidence || "", repo: from && from.kind === "repo" ? from.name : null };
          body.push(h("div", { class: "edge" },
            nodeButton(peer), h("span", { class: "tag kind-" + peer.kind }, peer.kind),
            h("span", { class: "ev-line" }, web.evidence(ev))));
        }
      }
      panel.replaceChildren(...body);
      panel.hidden = false;
      resize();
      if (!userMoved) fit();
    }

    function centre(n) {
      userMoved = true;
      viewport.x = -n.x; viewport.y = -n.y;
      viewport.k = Math.max(viewport.k, 1.1);
      alpha = Math.max(alpha, 0.3);
    }

    /* --- the corners ----------------------------------------------------
       Computed by jq (rule 3); the browser only picks which of the three
       lists to draw. With inferred edges off, the repos only inferred edges
       point at are unreferenced too, and are listed as such. */
    function drawCorners() {
      const c = view.corners || {};
      const list = ids => (ids || []).map(id => byId.get(id)).filter(n => n && nodeVisible(n));
      const section = (title, ns, note) => ns.length ? [h("h4", {}, title, " ", h("span", { class: "muted" }, ns.length)),
        note ? h("p", { class: "muted" }, note) : null,
        h("p", { class: "map-list" }, ns.map(n => nodeButton(n, "tag-like kind-" + n.kind)))] : null;
      const isolated = list(c.isolated);
      const unreferenced = list(c.unreferenced);
      const onlyInferred = list(c.only_inferred);
      const parts = [
        section("nothing links to these", isolated, "No edge in committed configuration touches them: not found, not \"not connected\"."),
        section("repos nothing points at", showInferred ? unreferenced : unreferenced.concat(onlyInferred),
          "No other repo references, imports, calls or shares configuration with them."),
        showInferred ? section("repos only inferred edges point at", onlyInferred,
          "What points at them was matched, not declared; switch inferred edges off and they join the list above.") : null,
      ].filter(Boolean);
      cornersEl.replaceChildren();
      if (!parts.length) return;
      cornersEl.append(h("h3", {}, "corners"), ...parts.flat());
    }

    /* --- input ---------------------------------------------------------- */
    function pick(px, py) {
      let best = null, bestD = 18 * 18;
      for (const n of nodes) {
        if (!nodeVisible(n)) continue;
        const p = toScreen(n);
        const d = (p.x - px) ** 2 + (p.y - py) ** 2;
        if (d < bestD) { bestD = d; best = n; }
      }
      return best;
    }
    const local = ev => { const r = cv.getBoundingClientRect(); return { px: ev.clientX - r.left, py: ev.clientY - r.top }; };

    cv.addEventListener("pointermove", ev => {
      const { px, py } = local(ev);
      if (dragging) {
        const w = toWorld(px, py);
        dragging.x = w.x; dragging.y = w.y; alpha = Math.max(alpha, 0.35);
        return;
      }
      if (panning) {
        userMoved = true;
        viewport.x += (px - panning.x) / viewport.k; viewport.y += (py - panning.y) / viewport.k;
        panning = { x: px, y: py };
        return;
      }
      const hv = pick(px, py);
      if (hv !== hover) { hover = hv; cv.style.cursor = hv ? "pointer" : "grab"; }
    });
    cv.addEventListener("pointerdown", ev => {
      const { px, py } = local(ev);
      const n = pick(px, py);
      cv.setPointerCapture(ev.pointerId);
      if (n) { dragging = n; show(n); } else { panning = { x: px, y: py }; cv.classList.add("dragging"); }
    });
    const release = () => { dragging = null; panning = null; cv.classList.remove("dragging"); };
    cv.addEventListener("pointerup", release);
    cv.addEventListener("pointercancel", release);
    cv.addEventListener("wheel", ev => {
      ev.preventDefault();
      userMoved = true;
      const { px, py } = local(ev);
      const before = toWorld(px, py);
      viewport.k = Math.min(4, Math.max(0.25, viewport.k * (ev.deltaY < 0 ? 1.1 : 1 / 1.1)));
      const after = toWorld(px, py);
      viewport.x += after.x - before.x; viewport.y += after.y - before.y;
    }, { passive: false });

    web.onSearch(q => { query = q; });

    /* The route can name a node: #/map/repo:web, or #/map/web for a repo. */
    const asked = route && route.parts && route.parts[0];
    const start = asked ? (byId.get(asked) || byId.get("repo:" + asked) ||
      nodes.find(n => n.name === asked)) : null;

    /* --- go ------------------------------------------------------------- */
    live = { el, tick: () => { readTheme(); resize(); if (!userMoved) fit(); }, close: () => show(null) };
    readTheme();
    resize();
    for (let i = 0; i < 420; i++) tick();   /* settle before the first paint */
    fit();
    drawCorners();
    if (start) { show(start); centre(start); }
    const me = live;
    const frame = () => {
      if (live !== me || !el.isConnected) return;   /* the view was left */
      tick(); draw(); requestAnimationFrame(frame);
    };
    requestAnimationFrame(frame);
  }

  /* One set of window listeners for whichever instance is on the page. */
  const alive = () => live && live.el.isConnected;
  window.addEventListener("resize", () => { if (alive()) live.tick(); });
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => { if (alive()) live.tick(); });
  document.addEventListener("keydown", ev => {
    if (ev.key === "Escape" && alive() && ev.target !== web.search) live.close();
  });

  web.register({
    id: "map", title: "Map",
    needs: ["map/graph.json", "map/depth.json", "map/live.json"],
    render,
  });
})();
