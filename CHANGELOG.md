# Changelog

All notable changes to Radium go in this file. The format follows
"Keep a Changelog"; versions are reserved for tagged releases.

## [Unreleased]

### Added
- Slice 0: project scaffold — Lazarus Qt6 desktop app skeleton, build
  scripts (`Build/build-macos.sh`, `Build/build-linux.sh`), Makefile,
  README + Architecture.md, `.gitignore`. Empty main window opens via
  `make run`. No thoriumd integration yet.
- Slice 1: thoriumd Pascal client.
  - `Source/Api/Radium.Api.Types.pas` — records mirroring thoriumd's
    REST JSON shapes (login, status, ping, AI, risk, plans).
  - `Source/Api/Radium.Api.Client.pas` — `TThoriumClient` with one
    method per thoriumctl endpoint: `Login`, `Logout`, `Refresh`,
    `Ping`, `Status`/`StatusRaw`, `AiConfigure`/`AiAsk`/`AiShow`,
    `RiskGet`/`RiskSet`, `PlanCreate`/`List`/`Get`/`Update`/`Cancel`.
    HTTP via mORMot 2's proxy-aware `TSimpleHttpClient`; JSON in/out
    via `_ObjFast`/`_Json`/`_Safe`; errors raise `EThoriumApi` with
    HTTP code attached. Special-cased `/ping`'s `{status:ok}` envelope.
    Compiles clean against FPC 3.2.4 + mORMot2.
  - `Docs/ThoriumdContract.md` — hardcoded wire-contract specification.
- `Docs/LookAndFeel.md` — hardcoded visual language. Modern aesthetic
  palette (Light + Dark themes, calibrated WCAG-AA), 8px spacing grid,
  system fonts, and the menu-driven shell decision (one `TMainMenu`
  drives navigation; centre frame swaps; no `TPageControl` tabs).
- Slice 2: GUI shell — single-window, **sidebar-driven** (pivoted
  from menu-driven mid-slice; LCL+Qt6 macOS menu surfacing was
  unreliable, see Docs/LookAndFeel.md §5).
  - `Source/Gui/Radium.Gui.Theme.pas` — Light + Dark palette tables
    (CSS hex byte-flipped to TColor BGR), `Apply(ARoot)` walks the
    control tree and stamps tokens onto Form / Panel / StatusBar /
    Label colours.
  - `Source/Gui/Radium.Gui.MainForm.pas/.lfm` — main window with
    fixed-width `SidebarHost` (TPanel, 200px) carrying TSpeedButton
    nav (Login / Status / Plans / Risk / AI), a spring panel, and a
    bottom group (Settings + theme toggle). Centre `TPanel` is the
    swap target for future frames. `TStatusBar` (connection / feed /
    instance / clock) at the bottom. Theme toggle flips Light ↔ Dark
    live. Buttons stub `NotImplemented(...)` until subsequent slices
    wire them.
  - Build chain: `Build/build-macos.sh` packages `Bin/Radium.app`
    with a minimum-viable `Info.plist` (CFBundleExecutable, identifier,
    `LSMinimumSystemVersion=11.0`, `NSPrincipalClass=NSApplication`)
    so macOS treats the binary as a real GUI process. `make run` does
    `open Bin/Radium.app` on Darwin. `-WM11.0` macOS deployment floor,
    `-k-F/Library/Frameworks` so the linker finds `Qt6Pas.framework`.
