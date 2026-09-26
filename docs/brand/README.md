# Approved orgami logo

The folded elephant in `logo.png` is the approved logo, copied unchanged from
`/logo.png`. It is used in the README, landing page, social preview metadata,
and both generated HTML pages. `favicon.svg` embeds the same artwork on warm
paper so it remains visible in light and dark browser chrome.

The explorations below are historical, superseded by the supplied elephant.

# orgami mark — candidates

Four original proposals plus a refinement round for a new `.mark`, built
against `DESIGN.md`'s Crease system (warm paper, verdigris teal underside,
solid mountain crease = extracted, dashed valley crease = inferred). The
brief: keep the crease notation, but make the mark unmistakably origami *and*
unmistakably a map/graph of repos — the current mark reads as a generic
folded-corner document.

See `preview.html` (screenshots: `preview-light.png`, `preview-dark.png`) for
C2 plus the original four, each at 20/48/220px, on paper and on
`--fold-deep`, next to the current mark and the wordmark.

## Mark A — crane fold

A paper-crane head and neck built from two straight facets: the body (large
repo) and head (small repo) triangles, joined by a solid mountain crease that
doubles as the edge between them; the beak is a dashed, inferred crease.
Unmistakably a crane at a glance — the most purely *origami* candidate — but
the graph reading is the weaker of the two ideas here and needs the tagline
to land.

## Mark B — accordion map

Three vertical panels like a folded paper map, each panel one repo. A node
sits atop each panel and a line strings the three into a path graph, with the
fold lines between panels doing double duty as that path's edges. Reads
instantly as "a folded map with parts," close to the literal tagline, but at
20px the three panels compress into a plain striped square and lose the node
detail.

## Mark C — triangulated node sheet

One mountain diagonal (solid) and one valley diagonal (dashed) quarter a
square sheet into four triangular facets — four repos — crossing at a centre
node, the org. The two creases *are* the graph's edges, radiating from a hub;
nothing is decorative. It's the only original candidate where the fold
reading and the graph reading are the same lines — but the first review round
found the flaw: at 20px the crease crossing (four thin arms plus three node
dots) collapses into a plain "+", and the node dots on every candidate read
as a stats/plot icon rather than paper. See C2 below for the fix.

## Mark D — waterbomb pinwheel

The opening of a real origami waterbomb base — four triangular flaps folding
toward a centre hub, one caught lifted to show its teal underside. Each flap
tip is a repo node, the four spokes are crease-edges radiating from the org
hub: a 4-spoke star, which is honestly the shape a small org's dependency map
usually takes. Truest to an actual fold sequence of the four, but it carries
the most linework, and at 20px the six thin spokes are the first thing to
blur together.

## Mark C2 — quartered sheet, lifted corner (recommended)

A refinement of C, not a new idea: same two creases meeting at one centre
node, but redrawn so the **silhouette** carries the read at small sizes
instead of the crease lines or node dots. Every node but the centre is
removed. The four quarters are drawn as full triangles pinwheeling around the
centre — three paper tones, the lower-right one teal — so the shape reads as
"a quartered square with one teal corner" from the colour blocks alone, even
if every stroke below disappears into a single pixel row. The creases are
drawn **short**, stopping at a seam around the teal quarter rather than
running corner-to-corner, so they can no longer out-compete the quadrants and
flatten into a free-standing cross. The lift is the seam itself — a sliver of
bare paper between the teal quarter and its two neighbours — not a shadow.
Verified at 20px explicitly (see `preview-light.png`/`preview-dark.png` and
the zoomed 20px crop taken during review): the teal quarter and the pinwheel
outline read immediately; the crease crossing reads as a secondary detail,
never as a "+" on its own.

`mono-c2.svg` is the single-colour variant (the teal quarter becomes the
darkest opacity step of `currentColor`; creases and the centre node stay
solid). `favicon.svg` is a 32-viewBox reduction with proportionally thicker
creases and a larger centre node, tuned for the smaller real sizes a favicon
is actually shown at.

## Recommendation

**Mark C2.** It keeps everything that made C the right *idea* — the two
creases are the graph's edges, not decoration, and removing either the fold
or the graph reading breaks the other — while fixing the two concrete
legibility failures the first round surfaced: no more node dots reading as a
stats icon, and no more crease crossing collapsing into a "+" once you're at
nav scale. It's also the only candidate in the set (original four included)
that was pixel-checked at true 20px, at both 1x and 2x screenshot scale, and
still reads correctly monochrome.

### Dropping mark-c2.svg into `docs/index.html`

Full inline HTML + CSS for all three `.mark` sizes is in
**`mark-c2.snippet.html`** in this directory — copy it directly rather than
re-deriving coordinates. Summary:

- **Which layer is the flap:** the lower-right quarter square (`.mark__flap`,
  `var(--fold)`) is the flap — same role as today's clipped lower-right
  triangle, just a square clip-path instead of a corner-to-corner triangle.
  It sits over an inline SVG drawing the other three quarters (paper-tone
  triangles at two opacity steps, replacing the old nine-square `.grid`) plus
  the two creases and the one remaining node (centre only); the flap covers
  the SVG's own unfilled fourth quadrant so the two layers tile exactly at
  rest.
- **What the animation sweeps:** `@keyframes fold` animates `.mark__flap`'s
  `clip-path` from a 4-vertex polygon collapsed onto the centre node (all
  four points at `48px 48px`, the flap pinned shut at the crease crossing) to
  the full flap square (`48,48 / 88.15,48 / 88.15,88.15 / 48,88.15` in the
  96-unit grid the existing markup uses). Vertex count stays 4 throughout —
  the constant-vertex-count rule the brief asks for — so it interpolates in
  every engine exactly like the original 3-vertex sweep did. The visual read
  is the lower-right facet swinging *out of* the centre crossing along the
  two creases, rather than a diagonal wipe.
- **Crease weight:** `.mark .mountain` / `.mark .valley` go from the old 1px
  hairline to 3.5px, and stop at the seam instead of running corner-to-corner
  — both changes are load-bearing for the 20px legibility fix; don't thin or
  lengthen them back without re-testing at 20px.
- No new CSS custom properties are needed — `--ink`, `--paper-2`, `--paper`,
  `--crease`, and `--fold` already cover every colour the new markup uses.

## What shipped (2026-09-13)

None of the four candidates or C2 went in as drawn. C had the right idea (the
creases are the edges, the facets are the repos) but the node dots read as a
chart icon, and C2 lost the origami read entirely. The mark now in
`docs/index.html` keeps the existing sheet, half-fold and `clip-path` sweep,
and replaces the nine-square grid with two ink-tint facets split by the solid
mountain crease, the dashed valley running just inside the fold edge. The same
drawing is the page's favicon. `DESIGN.md` "The mark" describes it; the files
here stay as the record of what was tried.
