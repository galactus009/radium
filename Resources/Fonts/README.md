# Icon font

Drop the regular-weight Phosphor TTF here and the nav glyphs in
Radium's sidebar render as actual icons. Without it the icons fall
back to empty boxes (Qt's missing-glyph) but the app still runs.

Either filename is recognised: `Phosphor.ttf` (what phosphoricons.com
hands out) or `Phosphor-Regular.ttf` (what the npm bundle uses). No
rename needed — `LoadIconFont` scans both.

## Get the font

1. Visit https://phosphoricons.com/
2. Click **Download** → grab the regular weight TTF.
3. Drop the resulting file into this directory.

License: MIT (https://github.com/phosphor-icons/homepage/blob/master/LICENSE).

## Codepoint mapping

The mapping from semantic icon role (e.g. "Brokers") to the actual
Phosphor codepoint lives in
[`Source/Gui/Radium.Gui.Icons.pas`](../../Source/Gui/Radium.Gui.Icons.pas).
If a glyph renders wrong after dropping the TTF, look up the icon's
real codepoint at phosphoricons.com (the cheat sheet shows
`U+EXXX`) and update the constant in `Icons.pas`. One source of
truth — every nav button reads through `IconGlyph()`.

## Runtime lookup

`Radium.Gui.Icons.LoadIconFont` checks these paths, in order, and
registers the first match with Qt's `QFontDatabase`. Each path is
probed for both `Phosphor.ttf` and `Phosphor-Regular.ttf`:

1. `<exe-dir>/Resources/Fonts/<name>`
2. `<bundle>/Contents/Resources/Fonts/<name>` (macOS)
3. `<repo-root>/Resources/Fonts/<name>` (uninstalled `make app`
   runs from `Bin/`)
4. `/usr/share/fonts/truetype/phosphor/<name>` (Linux system install)

The macOS bundle script (`Build/build-macos.sh`) copies the entire
`Resources/` tree into `Contents/Resources/` automatically, so once
the TTF is here it's part of every `.app` build.
