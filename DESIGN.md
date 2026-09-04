# Landline: design system

Visual world: **micrographics**. Mode: **Operate**. Platform: iOS 17+, SwiftUI.

## Thesis
A terminal client should look like the instrument that measures a machine, not like an app that
decorates one. Landline borrows the grammar of technical drawing and instrument silkscreen:
hairlines, tick scales, registration marks, micro-caps annotation, tabular figures. Everything is
labelled, aligned, and measured. It refuses the category default of rounded cards floating on a
neutral ground with a soft shadow.

## Own world
Ink-dark ground from One Dark Pro. Structure is drawn with 0.5pt hairlines and tick marks, never
with fills or shadows. Every piece of machine data (hostname, shell, session age, geometry,
latency) is set in monospace with tabular figures, because it is measurement. Labels are 10pt
mono, uppercase, tracked. Corners are 4pt or square. There are no cards. Regions are delimited by
rules and corner registration marks, the way a plate is delimited on a drawing.

## Color

One Dark Pro, used verbatim so the phone matches the desktops. Strategy: **Restrained**. Blue is
the only accent, reserved for the current selection, primary actions, and focus. Semantic color
comes from the terminal palette itself, never invented.

### Chrome is One Dark Pro. Only the terminal is themed.

A host can render its terminal in any of the shipped schemes (Catppuccin Mocha, Tokyo Night,
Gruvbox Dark, Dracula, Nord, Solarized Dark, Rosé Pine, Catppuccin Latte), each transcribed from
its own repository and cited in `TerminalPalette`. **None of that touches the app.** The chrome
tokens below, and the contrast floor measured against them, are calibrated for the One Dark Pro
ground; re-deriving an accessible chrome palette per scheme is a different and much larger piece
of work, and a half-derived one would put annotation under the readable floor in exactly the bad
light this app is used in. So the bars, sheets, rules, labels, and the accent stay One Dark Pro
whatever the terminal is set to, and a scheme appears in the chrome only as a **specimen**: a
swatch strip printed on its own ground, never as a surface the app paints itself with.

The one setting that reaches past the terminal is `matchSystem`, and only as far as the software
keyboard: a palette carries `isDark` so the keyboard does not flash white under a dark terminal.

### Chrome tokens
| Token | Hex | Use |
|---|---|---|
| `ground` | `#282C34` | terminal ground and app background |
| `panel` | `#21252B` | bars, sheets, the second neutral layer |
| `raised` | `#2C313C` | pressed and selected rows |
| `rule` | `#3E4451` | hairlines, tick marks, borders |
| `ink` | `#ABB2BF` | primary text |
| `inkBright` | `#D7DAE0` | emphasis, active values |
| `inkMuted` | `#949CAB` | micro-caps labels, secondary metadata, annotation |
| `inkDim` | `#5C6370` | **non-text only**: disabled chrome, inactive marks |
| `accent` | `#61AFEF` | selection, primary action, focus ring |
| `cursor` | `#528BFF` | terminal cursor |
| `ok` | `#98C379` | connected, success |
| `warn` | `#E5C07B` | reconnecting, degraded |
| `alert` | `#E06C75` | error and destructive marks, squares, rules |
| `alertText` | `#EC9098` | error *text*; `alert` measures 4.38:1 and misses the body floor |

### Terminal ANSI (One Dark Pro, exact)
Normal: `#282C34` `#E06C75` `#98C379` `#E5C07B` `#61AFEF` `#C678DD` `#56B6C2` `#ABB2BF`
Bright: `#5C6370` `#E06C75` `#98C379` `#E5C07B` `#61AFEF` `#C678DD` `#56B6C2` `#FFFFFF`
Foreground `#ABB2BF`, background `#282C34`, cursor `#528BFF`, selection `#3E4451`.

This is the default and the only palette that is also the chrome. The other schemes live in
`TerminalPalette` with the repository each was transcribed from cited on it, because the audience
reads these colours every day and one wrong hex is noticed instantly. The rules for adding one:
take all sixteen ANSI values plus foreground, background, cursor, and selection from the scheme's
own project, prefer the project's own terminal port over a third-party one, and where a project
publishes no distinct bright ramp, ship the values its own terminal configs ship rather than
inventing a brighter set. Repetition between the ramps is the scheme, not an omission.

Dark is not a category default here. It is forced by the scene: this app is opened in bed, on a
night train, and beside a sleeping person. A light ground would be hostile. Catppuccin Latte is
in the list anyway, for bright sunlight, and it is the only light scheme a user can pick outright;
`matchSystem` resolves to One Light in light appearance, because One Light is One Dark Pro's own
sibling and following the system should change the ground without changing the hues.

## Contrast floor, measured not estimated

Body and label text is at least 4.5:1 against whichever of `ground` or `panel` sits behind it.
Measured against `ground`: `ink` 6.57, `inkBright` 10.00, `inkMuted` 5.07, `accent` 5.92, `ok`
6.94, `warn` 8.10, `alertText` 6.01. `inkDim` measures **2.32 and therefore never carries text**,
which is the rule this system got wrong first time round: an instrument is read in bad light and
at arm's length, so its annotation has to survive that, and a dim label is the first thing to go.
Prose sets in `ink`, never in a muted token.

## Type
One family: **SF Mono** for everything that is data, label, or measurement, which in this app is
almost everything. **SF Pro Text** only for sentences a human wrote (explanatory copy, error
recovery text, onboarding). Never SF Pro for a value.

| Role | Face | Size | Tracking | Notes |
|---|---|---|---|---|
| `microLabel` | SF Mono Medium | 10 | +0.8pt | uppercase, `inkMuted`, annotation grammar |
| `value` | SF Mono Regular | 13 | 0 | tabular figures, always |
| `valueStrong` | SF Mono Medium | 15 | 0 | host names, primary identifiers |
| `title` | SF Mono Medium | 20 | -0.2pt | screen titles |
| `prose` | SF Pro Text | 15 | 0 | sentences only |

Tabular figures are mandatory on every numeral. A digit that changes width while a timer ticks
breaks the instrument illusion.

## Structure
- 4pt spacing grid. Row height 56pt minimum, so a thumb hits it while walking.
- Hairlines are 0.5pt `rule`, drawn edge to edge, never inset to fake a card.
- Tick scale: a repeating 4pt tick every 16pt along a region edge, used sparingly to mark a live
  or primary region. This is the world's signature device; one per screen at most.
- Registration marks: 6pt corner brackets in `rule` marking the terminal viewport and any focused
  region. Two per region maximum (opposite corners), never four, which reads as a frame.
- No shadows anywhere. Depth comes from the `panel` and `raised` layers.
- The index column in regular width is 300 to 380pt, measured off the longest thing its row prints
  (a tailnet hostname with its port). A row that will not fit its columns at that width **drops or
  stacks them**; it never truncates every column equally, because that is not a narrow layout, it
  is a wide layout that has stopped working.
- Prose never sets wider than about 560pt, whatever the pane is. A drawing has a plate size.

## Components
Every interactive element ships default, pressed, disabled, and focus. Status uses a 6pt square
(filled `ok` when connected, hollow `rule` when offline, filled `warn` while connecting), never a
circle, because squares belong to the drawing grammar and circles belong to iOS.

## Navigation grammar

The app has two shapes, chosen by **horizontal size class** and never by device idiom, because an
iPad in a narrow Split View is a phone-shaped window and has to behave like one:

| Width | Shape | The index is |
|---|---|---|
| compact | a pushed `NavigationStack` | a screen you go back to |
| regular | a two-column `NavigationSplitView` | a column beside the terminal |

### The header band
Every screen that is not a bare sheet wears one band across its top: `panel` ground, a hairline
along its bottom edge, and nothing else on it. It holds, in this order:

1. the **leading cell** (below),
2. the **title**, `title` face, uppercase, one line, truncating tail, with the **annotation line**
   under it in `microLabel` stating what the screen currently holds,
3. **measured columns** on the trailing end, when the screen has machine values to report.

A screen with more room prints more columns rather than more space. A band with a hole in the
middle of it is a narrow layout that has been stretched, which is the one thing a measured strip
may not look like.

### The back affordance: one form, one place
**The control that moves you between screens is the band's leading cell.** A cell the full height
of the band, `microLabel` face, `inkMuted` going to `inkBright` on press, the press lifting the
cell to `raised`, divided from the rest of the band by a vertical hairline the way a plate is
divided. Never a bordered box, because `[ ... ]` is this world's grammar for an **action on the
content** (`SAVE`, `RECONNECT`, `+ HOST`) and going back is not that, it is structure. Never an SF
Symbol chevron: this world draws its marks as glyphs on the mono grid.

| Context | Label | Why |
|---|---|---|
| pushed screen, compact | `◀ BACK` | there is a screen behind this one |
| split detail, regular | `◀ INDEX` / `▶ INDEX` | the index is *beside* this, so the cell shows and hides it; the mark points the way the press moves things |
| root of a sheet | `CLOSE` | nothing is behind it, so it does not point anywhere |
| the index itself, either shape | no cell | nothing is behind it |

A screen never carries a second control that does what the leading cell already does. The
terminal's closed band used to offer `[ INDEX ]` next to `[ RECONNECT ]`; it does not any more.

### Collapsing the index
A terminal is the one thing in this app that genuinely wants every pixel, so the index column can
be given back to it. The `◀ INDEX` cell collapses it and `▶ INDEX` brings it back; the transition
is a plain state change on the standard 180ms ease-out, never a bespoke choreography. Three rules
hold it together:

- The control lives in the **detail pane**, not in the column. A control inside the index goes
  away with the index, and there is then no way back.
- The choice is **remembered app-wide** (`settings.json`, alongside the key bar and the scroll
  speed), because it is a decision about the screen you are holding rather than about any one
  machine. Which means the app can open with the column collapsed and nothing selected, so the
  detail placeholder carries the same cell.
- Collapsing changes the terminal's width, which means a RESIZE to the daemon and a redraw at the
  far end. Verify that against a real session, never by reasoning: `GEOM` in the header is written
  only by the resize callback that sends the frame, so a `GEOM` that moved is the proof.

### The disclosure mark
A row that leads to another screen ends in `›` (U+203A) in `valueStrong`, `inkMuted`. A row that
**selects** rather than pushes — a sidebar row in regular width, whose screen appears next to it
rather than over it — carries no `›`. It is marked instead: a 2pt `accent` rule on its leading
edge and a `raised` ground, the same pair focus uses, because in both cases the row is the one the
screen is currently about.

### What is a sheet and what is a screen
- **Modal (sheet)**: a decision that must be finished or abandoned. Adding and editing a host, in
  both shapes, because it ends in `SAVE` or `CANCEL`.
- **Pushed screen**: a setting whose outcome is still owned by whatever opened it. Palette, font,
  leader, security, key bar. Backing out abandons nothing.
- **The detail pane** is the session, and only the session. App-wide settings are a push in
  compact and a **sheet** in regular, never the detail pane: they change how the terminal behaves
  under your thumb, so taking the terminal away to set them is exactly backwards, and closing
  returns you to a session that never stopped.

## Motion
150 to 200ms, ease-out, state only. One authored moment: the connect transition, where the
terminal region's registration marks draw themselves in as the session attaches. Everything else
is a plain state change. No page-load choreography, no decorative animation.

## Prohibitions specific to this world
- No cards, no shadows, no gradient fills, no glass.
- No circular status dots, no progress rings, no sparklines.
- No SF Pro on a machine value.
- No proportional figures on anything numeric.
- Do not scatter tick scales or registration marks; their scarcity is what makes them read as
  instrument marking rather than as texture.
