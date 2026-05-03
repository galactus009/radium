# Radium Look & Feel — Hardcoded Design Tokens

**Status:** HARDCODED. Like `ThoriumdContract.md`, this file pins design
decisions; deviations require a doc + code change in the same diff. The
goal is one consistent visual language across every panel, with zero
"freestyling" by individual forms.

## Design language

**Modern flat, trader-conventional semantic colour.** Influences:
TradingView's Light/Dark themes (palette + meaning), Linear (sidebar +
density), Bloomberg Terminal (status-bar discipline). Avoid: 2010s
Delphi grey-on-grey, Material Design ripples + elevation drama, OS
skeuomorphism. Every visible surface answers to a token from §1; every
visible *action* answers to a semantic kind from §1.5.

**Two non-negotiables, established 2026-05-02:**

1. **Modern aesthetic colours.** No grey-on-grey 2010s Delphi look.
   Flat surfaces, low-saturation accents, generous whitespace, system
   font on each platform. Reference points: Linear, modern Bloomberg
   Terminal Light/Dark, JetBrains' New UI.
2. **Sidebar-driven shell.** No `TPageControl`/tabs and no `TMainMenu`
   either. The main window has a fixed-width left sidebar (`SidebarHost`)
   with one button per top-level destination; clicking a button swaps
   the centre panel via a frame stack. Status bar at the bottom carries
   global state (connection / feed health / clock).

   Why not the menu bar: LCL+Qt6 on macOS routes `TMainMenu` through
   the system menu bar at the top of the screen, which is invisible
   from a window-focused glance and depends on the app being a real
   foreground bundle. After multiple attempts (`Menu = MainMenu` in
   the LFM, `.app` packaging with `Info.plist`, `NSPrincipalClass =
   NSApplication`), the menu still didn't surface reliably for the
   operator. A sidebar renders identically on every platform / launch
   path and never hides behind a focus boundary. Dropped 2026-05-02.

---

## 1. Palette

Two themes ship: **Light** (default; institutional, bright) and **Dark**
(after-hours / charts). The user toggles via the sidebar's sun/moon
button (icon shows what clicking switches *to*); the choice persists
in `~/.radium/settings.json` as `theme: 'light' | 'dark'` and is
re-applied at boot before the main form is constructed so the welcome
card never flashes the wrong palette.

Tokens are RGB hex. Apply via Qt6 stylesheet (see §4) — never hard-code
colours into individual `.lfm` files.

Hue language is **warm neutral**, not slate-blue. Accent is a single
indigo across both themes. Three elevation steps (canvas → surface →
elevated) are visibly distinct, and `border.subtle` is always one
step lighter than `bg.elevated` so cards have visible edges — earlier
versions where borderSubtle == bgElevated made everything look flat
and that bug is gone.

### 1.1 Light

| Token            | Hex       | Use                                          |
|------------------|-----------|----------------------------------------------|
| `bg.canvas`      | `#FFFFFF` | Window + panel background                    |
| `bg.surface`     | `#FAFAFA` | Sidebar, cards, status bar (clear off-white) |
| `bg.elevated`    | `#FFFFFF` | Dialogs, popovers (border-distinguished)     |
| `border.subtle`  | `#E4E4E7` | Dividers, grid lines                         |
| `border.strong`  | `#D4D4D8` | Form borders, focused control rim            |
| `fg.primary`     | `#09090B` | Headings, body text                          |
| `fg.secondary`   | `#52525B` | Secondary text, table column headers         |
| `fg.muted`       | `#71717A` | Placeholders, disabled                       |
| `accent.primary` | `#6366F1` | Active menu item, focused button, links      |
| `accent.hover`   | `#4F46E5` | Hover state on the above                     |
| `success`        | `#16A34A` | Connected / healthy / order accepted         |
| `warning`        | `#CA8A04` | Stale feed / risk warning                    |
| `danger`         | `#DC2626` | Disconnected / order rejected / cutoff hit   |
| `info`           | `#0891B2` | Info banners, neutral notifications          |

### 1.2 Dark

| Token            | Hex       | Use                                          |
|------------------|-----------|----------------------------------------------|
| `bg.canvas`      | `#0A0A0B` | Window + panel background (warm near-black)  |
| `bg.surface`     | `#141417` | Cards, grouped sections, status bar          |
| `bg.elevated`    | `#1C1C20` | Dialogs, popovers                            |
| `border.subtle`  | `#2A2A2E` | Dividers, grid lines (always > elevated)     |
| `border.strong`  | `#3F3F46` | Form borders, focused control rim            |
| `fg.primary`     | `#FAFAFA` | Headings, body text (crisp, not gray)        |
| `fg.secondary`   | `#A1A1AA` | Secondary text, table column headers         |
| `fg.muted`       | `#71717A` | Placeholders, disabled                       |
| `accent.primary` | `#818CF8` | Active menu item, focused button, links      |
| `accent.hover`   | `#6366F1` | Hover state on the above                     |
| `success`        | `#22C55E` | Connected / healthy / order accepted         |
| `warning`        | `#FBBF24` | Stale feed / risk warning                    |
| `danger`         | `#F87171` | Disconnected / order rejected / cutoff hit   |
| `info`           | `#22D3EE` | Info banners, neutral notifications          |

These pairings are calibrated for WCAG-AA contrast on body text. Don't
swap individual tokens between themes — the relationships matter more
than the exact hex.

### 1.5 Semantic kinds — colour by intent (HARDCODED)

Every interactive control MUST be tagged with a semantic kind that
communicates its intent at a glance. This is the trader-conventional
mapping; deviations confuse the operator and lose the protective
muscle memory that prevents Buys-being-clicked-instead-of-Cancels.

| Kind        | Token            | When                                                                |
|-------------|------------------|---------------------------------------------------------------------|
| `skNeutral` | `fg.primary`     | Navigation, links, default state. Most sidebar items.               |
| `skPrimary` | `accent.primary` | The one obvious next-action on a panel: Login, Apply, Submit, Save. |
| `skBuy`     | `success`        | Long entries, Buy, increase position, anything additive.            |
| `skSell`    | `danger`         | Short entries, Sell, exit, decrease position. Symmetric to skBuy.   |
| `skCancel`  | `danger`         | Cancel order, kill switch, panic-flatten. Always red, never grey.   |
| `skDelete`  | `danger`         | Logout, delete plan, drop session — destructive but non-trade.      |
| `skModify`  | `warning`        | Edit, modify SL/TP, change leverage. Yellow = "be deliberate".      |
| `skInfo`    | `info`           | Show details, expand, help — non-destructive read-only actions.     |
| `skMuted`   | `fg.muted`       | Disabled controls, secondary actions, "Cancel" on a settings dialog |
|             |                  | (NOT order-cancel — that's `skCancel`).                             |

Implementation rule: each Pascal control gets a one-shot
`Theme.SetSemantic(AControl, AKind)` call after creation; the helper
sets `Font.Color` (and `Color` where the widget allows) so the
operator never has to decode "is this red because it's destructive
or because it's an error message". Background colour stays canonical
per §1; semantic kind paints text and accent rims only.

Two examples baked in:

- **Login dialog**: "Sign in" = `skPrimary`, "Cancel" = `skMuted`.
- **Plans grid**: "New plan" = `skPrimary`, "Cancel plan" = `skCancel`,
  "Edit" = `skModify`, "Show details" = `skInfo`. The same row never
  carries two skCancel buttons — an operator should never have to
  pick which red button kills.

---

## 2. Typography

- **Family:** system default per platform.
  - macOS: `-apple-system` / "SF Pro Text".
  - Linux: "Inter" if present, fall back to "Cantarell" / "DejaVu Sans".
  - Windows: "Segoe UI Variable Text".
- **Sizes (pt at 100% scale):**
  - `12pt` body / form fields.
  - `11pt` table cells.
  - `10pt` status bar / secondary annotations.
  - `14pt` panel headings.
  - `18pt` page titles (rare; most panels skip a title because the
    menu communicates location).
- **Weights:** `400` body, `500` headings, `600` page titles. No bold
  in tables — use colour or background to call out instead.
- **Numerals:** tabular-nums everywhere prices/quantities show. Qt6:
  `font-feature-settings: "tnum"`.

---

## 3. Layout & spacing

- **8px grid.** Padding/margin always a multiple of 4 (preferably 8).
- **Window chrome:** native title bar; no custom frame painting.
- **Main menu:** none. Navigation lives in the sidebar (§5); no
  `TMainMenu`, no toolbar of duplicated commands.
- **Status bar:** single row, `bg.surface`, 28px tall. Sections
  (left→right): connection status • feed health • selected instance •
  IST clock.
- **Panels:** centre frame swap. One panel visible at a time. 16px
  padding from frame edge to content.
- **Forms:** label above field (not left-of) — keeps fields left-edge
  aligned and copes better with translation. 24px between field
  groups.
- **Tables:** `border.subtle` row separators only; no vertical grid
  lines. Hover row: `bg.surface`. Sticky header.

---

## 4. Implementation in Lazarus + Qt6

LCL's design-time colour properties can't express tokens, so we apply
colours via a Qt6 stylesheet at startup, not in `.lfm` files.

- One unit, `Source/Gui/Radium.Gui.Theme.pas`, owns the palette and
  the active-theme switch. It exposes `ApplyTheme(AKind: TThemeKind)`
  which builds a Qt6 stylesheet string from the tokens and calls
  `QApplication_setStyleSheet`.
- Forms reference theme tokens by name in code-behind when they need a
  colour at runtime (e.g. a "danger" cell in a grid). They never set a
  literal hex.
- The .lfm designer values for `Color`/`Font.Color` are left at
  defaults (`clDefault`, `clWindowText`); the stylesheet wins at
  runtime.

This keeps the IDE designer usable (forms render with system defaults
in the IDE), and the running app honours the palette.

---

## 5. Sidebar-driven shell

The main window's left sidebar IS the navigation. 220px expanded /
56px collapsed (toggled via the top hamburger), buttons stacked
vertically, one button per top-level destination. Centre frame swaps
on click.

```
+----------------+--------------------------------------+
| ▣ Login        |                                      |
| ▣ Status       |   CenterHost                         |
| ▣ Plans        |   ─ frame slot, swapped on click ─   |
| ▣ Risk         |                                      |
| ▣ AI           |                                      |
|                |                                      |
| (spring)       |                                      |
| ▣ Settings     |                                      |
| ◐ Light/Dark   |                                      |
+----------------+--------------------------------------+
| connection ▶  feed: live  •  inst: alpha  •  09:14 IST|
+-------------------------------------------------------+
```

Decisions baked in:
- One panel visible at a time. Selecting a sidebar button swaps the
  centre frame; previously open frame state is forgotten (no tab
  persistence).
- Active button gets `accent.primary` text on `bg.elevated` background;
  inactive buttons get `fg.secondary` on `bg.surface`. Hover bumps to
  `fg.primary`.
- Settings + theme toggle are pinned to the sidebar bottom via a
  spring (TPanel with `Align = alClient` between top + bottom groups).
- The same shell works on macOS, Linux, Windows with no widgetset
  branching. Visible from the very first frame; no system-menu-bar
  focus dependency.

---

## 6. Iconography

- Outlined font-rendered icons, 18-20px. Single colour at the active
  `fg.secondary` token, recolour on hover/active via standard label
  Font.Color (no SVG raster pipeline).
- **Source:** Phosphor (https://phosphoricons.com) regular weight —
  MIT, single TTF, PUA codepoints. Drop the TTF into
  `Resources/Fonts/` (either `Phosphor.ttf` or `Phosphor-Regular.ttf`
  is accepted); `LoadIconFont` registers it with Qt at startup. The
  semantic role → codepoint map lives in `Source/Gui/Radium.Gui.Icons.pas`
  (`TIconKind` + `IconGlyph()`); add a member when a new role appears.
- No emoji, no platform-specific icon sets, no skeuomorphism.

---

## 7. Motion

- Frame swaps are instant. No fade/slide.
- Status bar changes are instant.
- Toasts (when added) fade in 150ms, hold 4s, fade out 200ms. One
  visible at a time, top-right of the centre frame.

Keep the app feeling fast — no animation longer than 250ms anywhere.

---

## 8. What this file is not

This is a token + decision spec, not a UX style guide. Microcopy,
onboarding flows, and accessibility audits live elsewhere when they
become relevant. Do not extend this file with prose about flows or
content; either add a sibling doc or push the decision into the
specific panel's source comments.
