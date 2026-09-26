# Design — orgami landing page

Locked design system for `docs/index.html` (GitHub Pages). Future design
passes read this file first and defer to it. Amend it on purpose; the file is
the rule. It does not govern `lib/web/` (the product's own web view), which
keeps its own tokens in `lib/web/00-shell.css`.

This file replaces the "Cobalt" system of 2026-09-13 (cool white, electric
blue, sticky nav, ⌘K palette), which itself replaced the editorial "Almanac"
page of 2026-09-12. Cobalt converted but had no soul; the brief for this
rebuild was a page with one memorable element that is the product's own idea.

## What the page is

A developer-tool landing page for engineering leads on 5–15 person teams, and
the coding agents they run. One action: copy the install line. It reads as a
tool, not a journal, because every section except one carries something a
machine said, set on the exact ground of the real recording.

A second reader arrives by forwarded link: the founder or CEO a lead sends the
page to before asking for time. `#who` is written for them. It names the
problem and what it costs the company (onboarding, departures, agents that
guess) in words that need no engineering, and states no figure until tester
interviews supply one. Everything below `#who` stays written for engineers;
the page does not split by audience.

## System — Crease

A sheet of paper, white or GitHub black, that is contribution-graph green on
the reverse. Green is an accent and never a ground. Behind the hero, and only
there, a living ground: an animated Bayer-dithered grid of green cells (the
"Dither Grid" gradient) on a canvas that dissolves into the paper before the
first section. Wherever the page
folds, a corner turns over and shows the colour underneath; wherever a corner
is cut, the grid shows through it. The crease
notation — solid line = mountain fold = extracted, dashed line = valley fold =
inferred — is the product's own evidence vocabulary drawn as origami.

- Macrostructure · Workbench (folded): the recording and real transcripts are
  the content; copy is captions around them
- Enrichment · E1: the real recording on a green backing sheet, plus the folded
  mark, all of it over the dithered ground
- Nav · N1a: wordmark with the static mark, three text links, not sticky, no
  border, no button
- Footer · Ft2 inline, under the closing sheet, the only middle-dot line
- One all-type pause section (`#who`: the problem, its costs as a `dl`, then
  the command index), one full-bleed dark band (`#agents`)

## Tokens

The `:root` block in `docs/index.html` is the source of truth; copy it, do
not retype it. Light is the default on bare `:root`; dark answers both
`prefers-color-scheme: dark` (guarded with `:root:not([data-theme="light"])`)
and `:root[data-theme="dark"]`, same values in both blocks. Both grounds are
neutral: white, or GitHub's `#0d1117`. Every green is GitHub's contribution
palette and is used only as an accent or in the hero grid.

```css
:root {
  color-scheme: light;
  --paper: #ffffff; --paper-2: #f6f8fa; --crease: #d0d7de;    /* GitHub light: ground, second sheet, hairlines */
  --ink: #1f2328; --ink-2: #59636e;
  --fold:      #1a7f37;   /* copy square, links, focus ring, tile A, turned corners */
  --fold-deep: #0d1117;   /* the paper turned fully over: the #agents band and the closing sheet are black */
  --fold-tint: #dafbe1;   /* tile C, copied-state background */
  --fold-lit:  #3fb950;   /* green ONLY on dark surfaces ($ prompt, section words, cursor) */
  --on-fold: #ffffff; --on-dark: #e6edf3; --on-dark-2: #8b949e;
  --ear-fold: color-mix(in oklch, var(--fold), var(--ink) 28%); --ear-deep: var(--fold-lit); --ear-paper: var(--fold);
  --copied: var(--fold-tint);
  --fold-hover: color-mix(in oklch, var(--fold), var(--ink) 14%); --fold-press: color-mix(in oklch, var(--fold), var(--ink) 28%);
  --deep-bar: var(--term); --deep-bar-ink: var(--on-dark); --deep-prompt: var(--fold-lit);
  --deep-bar-edge: color-mix(in oklch, var(--on-dark) 20%, transparent);
  /* the hero ground: the contribution graph's light ramp, lightened toward white by the layers over it */
  --grid-0: #ebedf0; --grid-1: #9be9a8; --grid-2: #216e39; --grid-3: #40c463;   /* @ 0, 24, 61, 67% */
  --grid-backdrop: var(--paper); --grid-vignette: rgb(255 255 255 / .8);
  --scrim: transparent; --shade: rgb(255 255 255 / .82); --ground-blend: normal;
  --term: #1d1c2d;   /* sampled from docs/demo-still.png; re-sample if demo.tape's theme changes */
}
/* dark (both blocks): */
  --paper: #0d1117; --paper-2: #161b22; --crease: #30363d; --ink: #e6edf3; --ink-2: #8b949e;
  --fold: #3fb950; --fold-deep: #161b22; --fold-tint: #0e4429; --fold-lit: #56d364; --on-fold: #0d1117;
  --ear-fold: color-mix(in oklch, var(--fold), var(--paper) 22%);
  --copied: color-mix(in oklch, var(--fold), var(--paper) 45%);
  --fold-hover: color-mix(in oklch, var(--fold), var(--paper) 14%); --fold-press: color-mix(in oklch, var(--fold), var(--paper) 28%);
  /* the hero ground on black: the Dither Grid palette as specified, multiplied down toward the page */
  --grid-0: #0e2417; --grid-1: #2e6b3e; --grid-2: #ddf0c8; --grid-3: #78b86b;
  --grid-vignette: rgb(0 0 0 / .8); --scrim: #b4c8ac; --shade: rgb(13 17 23 / .82); --ground-blend: multiply;
```

Shape: `--r-1` 4px (tabs, copy square, bars, pause chip), `--r-2` 12px
(sheets, run card, recording), `--ear` 28px, `--ear-lg` 48px. Space on a 4px
base, `--s-1` .25rem to `--s-10` 8rem. Motion: `--dur-state` 160ms,
`--dur-reveal` 420ms, `--dur-fold` 900ms, `--ease-out` `cubic-bezier(.2,.7,.2,1)`.

## Type

- Bricolage Grotesque, display only, never body: h1/h2 at `opsz 96` 700,
  h3 at `opsz 24` 600, the `#who` statement at `opsz 96` 500.
- Instrument Sans 400/500/600 for body, tabs, captions, the `dt`s.
- Geist Mono 400/500 for anything a machine said or you type; JetBrains Mono
  is the fallback if Geist Mono ever fails to load.
- Scale `--fs-0` 13px, `--fs-1` 15px, `--fs-2` 17px, `--fs-3` 20px, `--fs-4`
  24px, `--fs-5` h2 `clamp(1.75rem, 1.2rem + 1.8vw, 2.5rem)`, `--fs-6`
  statement `clamp(1.75rem, 1.1rem + 2.4vw, 2.75rem)`, `--fs-7` h1
  `clamp(2.5rem, 1.25rem + 2.9vw, 3.75rem)` (three lines in the 5fr column).
- Headings roman, sentence case, tracking −0.025em, no accent word, no
  italics, no eyebrows. The one caption over the transcript is lowercase
  mono in `--fold-lit`, not an eyebrow.

## Layout

- `--page-max` 72rem, `--gutter clamp(1rem, 4vw, 2.5rem)` as body padding.
- A 12-column mental grid rendered as `5fr 7fr` text-left / asset-right
  pairs (hero, agents, check, join, cost); one all-type pause section
  indented to column 3; one full-bleed dark band; the closing sheet
  `220px 1fr`.
- Bento of exactly three unequal tiles: A `span 4`, B `span 2`, C `span 6`
  with an inner two-column grid. Under 960px all three go full width and C's
  inner grid stacks (text, then the command).
- Section padding deliberately unequal: hero `2rem 5rem`, who `8rem`, agents
  `6rem`, check `6rem`, team `6rem`, join `5rem`, cost `4rem`, close
  `8rem 3rem`.
- Left-aligned everywhere; nothing centred. All `5fr 7fr` grids become one
  column at 960px; "Docs" leaves the nav under 480px (it recurs in the footer).

## Surfaces

- `.sheet`: paper-2, hairline, 12px radius with the top-right corner square,
  the corner cut away with a `clip-path` polygon so the ground shows through
  it, and the dog-ear via `::before` (a hard-stop fill: transparent over the
  reverse side). `.sheet--fold` (green, `--on-fold` text), `.sheet--tint`,
  `.sheet--deep` (the closing sheet, 48px ear).
- `pre.bar`: `--term`, 4px radius, `$` in `--fold-lit`, comments in
  `--on-dark-2`; one-line bars scroll with the native track hidden and a 24px
  right-edge mask fade only when they actually overflow. In the closing sheet
  the bar sits on `--deep-bar` (paper in light, `--term` in dark) with a
  `--deep-prompt` prompt.
- The run card: paper-2 shell, paper header with the state text, `--term`
  pre showing the `--json` object from `docs/map.md`, two-tone evidence
  (extracted `--fold-lit`, inferred `--on-dark-2`). No ear.
- The transcript in the band sits directly on `--fold-deep` with no box and
  wraps like a terminal (`pre-wrap`); it never scrolls sideways.
- The ear appears on exactly five things: the hero backing sheet, tiles A, B,
  C, and the closing sheet.

## The mark

The approved mark is the folded elephant supplied in `logo.png`. Its unchanged
web copy is `docs/brand/logo.png`; do not redraw it or restore the old sheet mark.
The landing page uses it in the navigation (32px), hero (56px), and closing
sheet (220px). On dark surfaces CSS renders the silhouette light. The mark is
static, including under reduced motion.

`docs/brand/favicon.svg` embeds the same pixels on a warm paper background for
visibility in either browser theme. Generated web and graph pages embed both
the favicon and logo so exports still open offline. README and social metadata
use the same PNG. Earlier proposals in `docs/brand/` are historical references.

## The ground

`.ground` is a `position: absolute; top: 0; z-index: -1` layer behind the
hero only, `max(100vh, 54rem)` tall and masked to transparent over its last
38% so it dissolves into `--paper` before `#who`. It holds one `<canvas>`
(the grid), with grain (`::after`, the 120px `feTurbulence` tile at opacity
.5, `mix-blend-mode: overlay`) and, multiplied over that (`::before`), the
vignette, the shade and the scrim, blended with `--ground-blend` (multiply
on black, normal on white, so each lightens or darkens toward its page).
`--scrim` is a light cap on the dark ramp; `--shade` (the page colour at .82) covers
the left 30% fading out by 60%, and the lower 30%, which is what lets the
hero copy, the caption and the install row read; under 960px the copy spans
the width and so does the shade. The layer is `aria-hidden`, has no pointer
events and is hidden in print. Everything below the hero sits on plain
`--paper`. The script at the foot of the page is the 21st.dev
"Dither Grid" in pixel mode, rebuilt from its parameters: square cells,
25 across the width whatever the height, with a 7% gap showing
`--grid-backdrop`; each cell samples the continuous palette ramp (Pine 0,
Moss .24, Sprout .61, Fern .67) along the 62° diagonal, with a `wave` 12 /
`distortion` 28 sine bend across it and a Bayer 4×4 ordered-dither offset of
up to ±8% of the ramp at strength .76, so neighbours jitter instead of banding. Colours come from the tokens via `getComputedStyle`, so the
`:root` block stays the only place a colour is written.

Motion: a `requestAnimationFrame` loop with an elapsed-seconds clock `t`,
`ph = t * 0.71`, `amt = 0.60`, `dir = 1`. The ramp slides along the
diagonal by `sin(ph * 0.9 * dir) * 0.5 * amt` (a sine sweep, not a scroll)
and the wave's phase drifts by `(cos(ph * 0.4) - 1) * 0.8`; every modulation
is exactly 0 at `ph = 0`, so the first frame equals the static one and
nothing snaps when the loop starts. Nothing animated is rounded. Under
`prefers-reduced-motion: reduce`, or while the tab is hidden, it draws one
frame at `ph = 0` and stops; it resumes on the media query or visibility
changing. The canvas re-sizes on `resize` at a device pixel ratio capped
at 2.

## Motion

Three primitives and the ground: the fold, the type-in, state, and the grid.

- Type-in: the transcript in `#agents` types at 7ms per character with a
  140ms pause at line ends (≈5.5s for the block), on first intersection at
  threshold .35, with the block cursor on the line being typed. The typed
  copy is an `aria-hidden` clone; the original `pre` stays in the
  accessibility tree, visually hidden and out of the tab order, until the
  typing ends; then the clone is removed and the real, focusable transcript
  is what stays. Height is reserved before clearing.
- State: 160ms `--ease-out` on named properties only — copy background
  (hover `--fold-hover`, pressed `--fold-press`), tab colour and underline
  (`box-shadow` inset), run-card `grid-template-rows` (420ms), `details`
  marker rotation, link underline thickness, the pause chip's border. No
  lifts. Focus rings never transition and never change geometry.
- The run card unfolds only after the transcript has finished typing; if it
  comes into view first it waits its turn — unless the transcript never
  started (a deep link below it), in which case the card plays at once.
- Reduced motion: the HTML ships every end state (mark folded, transcript
  complete with a static cursor, card in `output`), JS winds them back only
  when `prefers-reduced-motion: no-preference` matches and
  `IntersectionObserver` exists. The `<picture>` serves `demo-still.png` and
  the pause button starts as "play".

## Honest content rules

- No invented metrics, logos, testimonials or star counts. Every number on
  the page is either in the README or is a command's own output.
- Every section's claims come from the README or `docs/*.md`.
- Every section carries an HTML comment listing the README/docs lines it
  quotes; a copy change must update the comment.
- Links to `docs/*.md` point at the GitHub blob URL: the page is served
  from `docs/`, so a relative `docs/…` path is a dead link on Pages.
- The reduced-motion still (`docs/demo-still.png`) and the video
  (`docs/demo.mp4`) are committed with the page; `og:image` uses
  `docs/brand/logo.png`.
- The install line appears twice: hero and closing sheet. It is the one
  action; the copy square is the only filled control.

## The recording

`docs/demo.mp4` (1200×720, encoded from `docs/demo.gif` with the ffmpeg line
in `docs/demo.tape`) as a muted, looping, inline `<video>` at 100% of its
column, never cropped, on a green backing sheet offset 20px that may run off
the right edge; `docs/demo-still.png` is its poster and its CSS background,
so the first frame is on screen before a byte of video arrives. A text
"pause" chip pauses the element because the loop runs longer than five
seconds; under reduced motion JS holds the video on its first frame and the
chip starts as "play". The gif stays for the README; social previews use the elephant logo. The
recording has real vhs chrome baked in; nothing on the page imitates it.
Never a generated clip: the recording is the only footage on the page.

## Never on this page

- Purple, or any gradient other than the ground: the dog-ear fill is the only
  `linear-gradient` and the vignette the only `radial-gradient`.
- The dog-ear on anything but the five named surfaces; more than one
  animated fold per viewport visit; a fourth bento tile.
- Icons or emoji (the copy/check glyphs are the exception); drop shadows or
  glows; texture on anything but the ground; fake window chrome around code.
- Green as a page or section ground: the grounds are white and `#0d1117`,
  green is the accent, the folded sheets and the hero grid, nothing else.
- Orange, clay, terracotta or teal anywhere; serif faces; italic headings;
  tracked-uppercase labels.
- Middle-dot chains outside the footer; `→` on links; announcement pills;
  sticky nav; ⌘K or any search; numbered step markers (the join sequence is
  three shell lines).
- Invented numbers; `transition: all`; hover scale or lift; scroll-triggered
  fades; inline colours or fonts outside the token block.
