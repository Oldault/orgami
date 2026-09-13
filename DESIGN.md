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

## System — Crease

A warm sheet of paper that is verdigris teal on the reverse. Wherever the page
folds, a corner turns over and shows the colour underneath. The crease
notation — solid line = mountain fold = extracted, dashed line = valley fold =
inferred — is the product's own evidence vocabulary drawn as origami.

- Macrostructure · Workbench (folded): the recording and real transcripts are
  the content; copy is captions around them
- Enrichment · E1: the real recording on a teal backing sheet, plus the folded
  mark
- Nav · N1a: wordmark with the static mark, three text links, not sticky, no
  border, no button
- Footer · Ft2 inline, under the closing sheet, the only middle-dot line
- One all-type pause section (`#who`), one full-bleed dark band (`#agents`)

## Tokens

The `:root` block in `docs/index.html` is the source of truth; copy it, do
not retype it. Light is the default on bare `:root`; dark answers both
`prefers-color-scheme: dark` (guarded with `:root:not([data-theme="light"])`)
and `:root[data-theme="dark"]`, same values in both blocks.

```css
:root {
  color-scheme: light;
  --paper:     oklch(97% 0.011 82);   /* page ground: oat */
  --paper-2:   oklch(93.5% 0.014 82); /* a second sheet: tiles, run card, tab strip */
  --crease:    oklch(85% 0.018 82);   /* hairlines, crease lines, borders */
  --ink:       oklch(24% 0.02 62);    /* headings, body. warm charcoal, never #000 */
  --ink-2:     oklch(45% 0.018 62);   /* muted: captions, inferred evidence, comments */
  --fold:      oklch(46% 0.11 196);   /* deep verdigris: copy square, links, focus ring, tile A, turned corners */
  --fold-deep: oklch(27% 0.05 200);   /* the paper turned fully over: the #agents band and the closing sheet */
  --fold-tint: oklch(91% 0.045 196);  /* tile C, copied-state background */
  --fold-lit:  oklch(74% 0.10 196);   /* light teal ONLY on dark surfaces ($ prompt, section words, cursor); same in both modes */
  --on-fold:   oklch(97% 0.011 82);   /* text on --fold / --fold-deep in light mode (= paper) */
  --on-dark:   oklch(93% 0.012 82);   /* text on --fold-deep and --term in BOTH modes */
  --on-dark-2: oklch(72% 0.014 76);   /* muted text on dark surfaces in BOTH modes */
  --ear-fold:  color-mix(in oklch, var(--fold), var(--ink) 28%);   /* the corner turned on a --fold sheet */
  --ear-deep:  var(--fold);                                        /* on a --fold-deep sheet */
  --ear-paper: var(--fold);                                        /* on a paper-2 sheet */
  --copied:    color-mix(in oklch, var(--fold), var(--paper) 55%); /* button background while "copied" */
  --fold-hover: color-mix(in oklch, var(--fold), var(--ink) 14%);  /* copy square under the pointer */
  --fold-press: color-mix(in oklch, var(--fold), var(--ink) 28%);  /* copy square while pressed */
  --deep-bar: var(--paper); --deep-bar-ink: var(--ink); --deep-prompt: var(--fold); /* the install bar on the closing sheet */
  /* the machine surface. Sampled from docs/demo-still.png (edge pixels = #1d1c2d). Re-sample if demo.tape's theme changes. */
  --term:      #1d1c2d;
}
/* dark (both blocks): */
  --paper: oklch(19% 0.012 66); --paper-2: oklch(23.5% 0.014 66); --crease: oklch(32% 0.014 66);
  --ink: oklch(93% 0.012 82); --ink-2: oklch(70% 0.014 76);
  --fold: oklch(74% 0.10 196);        /* the underside is LIGHTER on dark: elevation by lightness */
  --fold-deep: oklch(24% 0.06 200);   /* the reverse side must still read against --paper at 19% */
  --fold-tint: oklch(30% 0.055 196); --on-fold: oklch(16% 0.02 66);
  --ear-fold: color-mix(in oklch, var(--fold), var(--paper) 22%);
  --copied: color-mix(in oklch, var(--fold), var(--paper) 45%);
  --fold-hover: color-mix(in oklch, var(--fold), var(--paper) 14%);
  --fold-press: color-mix(in oklch, var(--fold), var(--paper) 28%);
  --deep-bar: var(--term); --deep-bar-ink: var(--on-dark); --deep-prompt: var(--fold-lit); /* in dark the closing bar sits on the terminal ground, not on paper */
  --deep-bar-edge: color-mix(in oklch, var(--on-dark) 20%, transparent); /* hairline on that bar (transparent in light) */
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
  dog-ear via `::before` (a hard-stop two-colour fill: page colour over the
  reverse side). `.sheet--fold` (teal, `--on-fold` text), `.sheet--tint`,
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

`.mark`: an HTML square (`--paper-2`, inset hairline) holding an inline SVG
of nine faint squares, a solid mountain crease and a dashed valley crease,
with a `--fold` flap layer whose `clip-path` polygon is the lower-right
triangle. Sizes 20 (nav, static), 48 (hero, folds once 250ms after load) and
220 (closing sheet, folds once on first intersection at threshold .6). The
fold is a 2D `clip-path` sweep from the diagonal into the corner, 900ms; the
vertex count is constant so it interpolates in every engine.

## Motion

Three primitives and nothing else: the fold, the type-in, and state.

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
- The reduced-motion still (`docs/demo-still.png`) is committed with the
  page; `og:image` stays `docs/demo.gif`.
- The install line appears twice: hero and closing sheet. It is the one
  action; the copy square is the only filled control.

## The recording

`docs/demo.gif` (1200×720) at 100% of its column, never cropped, on a teal
backing sheet offset 20px that may run off the right edge; eager, high fetch
priority, with `docs/demo-still.png` served for `prefers-reduced-motion`. A
text "pause" chip swaps in the still because the loop runs longer than five
seconds; under reduced motion it starts as "play". The gif has real vhs
chrome baked in; nothing on the page imitates it.

## Never on this page

- Purple or any multi-stop gradient; the dog-ear fill is the only
  `linear-gradient`.
- The dog-ear on anything but the five named surfaces; more than one
  animated fold per viewport visit; a fourth bento tile.
- Icons or emoji (the copy/check glyphs are the exception); drop shadows or
  glows; paper grain or texture images; fake window chrome around code.
- `#000`/`#fff` paint; orange, clay or terracotta anywhere — the accent is
  hue 196 or nothing; serif faces; italic headings; tracked-uppercase labels.
- Middle-dot chains outside the footer; `→` on links; announcement pills;
  sticky nav; ⌘K or any search; numbered step markers (the join sequence is
  three shell lines).
- Invented numbers; `transition: all`; hover scale or lift; scroll-triggered
  fades; inline colours or fonts outside the token block.
