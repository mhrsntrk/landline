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

## Components
Every interactive element ships default, pressed, disabled, and focus. Status uses a 6pt square
(filled `ok` when connected, hollow `rule` when offline, filled `warn` while connecting), never a
circle, because squares belong to the drawing grammar and circles belong to iOS.

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
