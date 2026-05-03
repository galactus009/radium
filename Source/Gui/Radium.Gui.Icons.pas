unit Radium.Gui.Icons;

{$mode Delphi}{$H+}

// Glyphs for Radium's GUI shell.
//
// Primary path: Phosphor (https://phosphoricons.com — MIT) loaded as
// a TTF from Resources/Fonts/Phosphor-Regular.ttf. Codepoints below
// are the actual values from Phosphor's published stylesheet, not
// guesses (an earlier slice mis-mapped these and every nav button
// rendered as a hamburger).
//
// Fallback path: when the font is missing or LoadIconFont returns
// False, NavButton skips setting Font.Name. The codepoints still
// render — just as Qt's "missing glyph" boxes since they sit in the
// PUA range and no system font owns them. The app still functions;
// the nav reads as a row of boxes until the font's dropped in.
//
// Setup (one-time):
//   Drop Phosphor-Regular.ttf into Radium/Resources/Fonts/. The
//   macOS bundle script copies the entire Resources/ tree into
//   Contents/Resources/ on every build.

interface

uses
  Classes, SysUtils;

type
  // The icon roles the nav uses today. Keep this enum tight; each
  // member maps to one PUA codepoint in the icon font. Add a member
  // when a new role appears in the UI.
  TIconKind = (
    iconList,          // hamburger / nav-toggle expand
    iconCaretLeft,     // collapse-direction caret
    iconBrokers,       // chart-bar — broker sessions + status
    iconPlans,         // clipboard-text — trading plans
    iconRisk,          // shield — risk knobs
    iconClerk,         // file-text — clerk reports
    iconAi,            // sparkle — AI assistant
    iconSettings,      // gear — settings
    iconNew,           // plus-circle — new plan / trade
    iconRefresh,       // arrows-clockwise — refresh
    iconSun,           // sun — show "switch to light" when in dark
    iconMoon           // moon — show "switch to dark" when in light
  );

const
  // Font family registered into Qt at startup. Match the font's
  // PostScript name as Qt sees it after addApplicationFont.
  ICON_FONT_FAMILY = 'Phosphor';

// Tries several install locations for Phosphor-Regular.ttf and
// registers the first one found. Safe to call once at startup.
// Returns True if the font registered successfully — caller can log,
// but app continues either way (Qt will fall back to box glyphs).
function LoadIconFont: Boolean;

// Unicode glyph string for the given icon. Returns UTF-8 (LCL
// convention) — assign directly to TLabel.Caption / TButton.Caption.
function IconGlyph(AKind: TIconKind): string;

// Returns the registered family name (or '' if load failed). Set
// the .Font.Name of any TLabel/TButton you want rendering icons.
function IconFontFamily: string;

implementation

uses
  qt6;

const
  // Phosphor regular-weight PUA codepoints. Verified against
  // unpkg.com/@phosphor-icons/web/src/regular/style.css. If a glyph
  // ever renders wrong after a Phosphor version bump, look the icon
  // name up at phosphoricons.com and update here — every call site
  // routes through IconGlyph().
  CP_LIST         = $E2F0;  // ph-list (hamburger)
  CP_CARET_LEFT   = $E138;  // ph-caret-left
  CP_CHART_BAR    = $E150;  // ph-chart-bar          (Brokers)
  CP_CLIPBOARD    = $E198;  // ph-clipboard-text     (Plans)
  CP_SHIELD       = $E40C;  // ph-shield-check       (Risk)
  CP_FILE_TEXT    = $E23A;  // ph-file-text          (Clerk)
  CP_SPARKLE      = $E6A2;  // ph-sparkle            (AI)
  CP_GEAR         = $E272;  // ph-gear-six           (Settings)
  CP_PLUS_CIRCLE  = $E3D6;  // ph-plus-circle        (Trade — new order)
  CP_ARROWS_CLOCK = $E094;  // ph-arrows-clockwise   (Refresh)
  CP_SUN          = $E472;  // ph-sun                (theme toggle, when in dark)
  CP_MOON         = $E330;  // ph-moon               (theme toggle, when in light)

var
  GFontFamily: string = '';

function ResourceCandidates: TStringArray;
var
  exeDir, bundleRes, repoRes: string;
  i: Integer;
const
  // Phosphor's published TTF ships as either filename depending on
  // download source: phosphoricons.com hands out 'Phosphor.ttf', the
  // npm bundle 'Phosphor-Regular.ttf'. Accept both so the operator
  // doesn't have to rename.
  FILENAMES: array[0..1] of string = ('Phosphor.ttf', 'Phosphor-Regular.ttf');
begin
  exeDir  := ExtractFilePath(ParamStr(0));
  // macOS app-bundle layout: <bundle>.app/Contents/MacOS/<exe>
  // Resources sit at <bundle>.app/Contents/Resources/. Walk up two.
  bundleRes := IncludeTrailingPathDelimiter(exeDir) + '..' +
               PathDelim + 'Resources' + PathDelim;
  // Repo-relative when running uninstalled from Bin/ output.
  repoRes := exeDir + '..' + PathDelim + '..' + PathDelim +
             'Resources' + PathDelim;
  SetLength(result, 4 * Length(FILENAMES));
  for i := 0 to High(FILENAMES) do
  begin
    result[i * 4 + 0] := exeDir + 'Resources' + PathDelim + 'Fonts' +
                         PathDelim + FILENAMES[i];
    result[i * 4 + 1] := bundleRes + 'Fonts' + PathDelim + FILENAMES[i];
    result[i * 4 + 2] := repoRes + 'Fonts' + PathDelim + FILENAMES[i];
    // System-installed (Linux deb / homebrew formula).
    result[i * 4 + 3] := '/usr/share/fonts/truetype/phosphor/' + FILENAMES[i];
  end;
end;

function LoadIconFont: Boolean;
var
  paths:     TStringArray;
  i, fontId: Integer;
  wp:        WideString;
  families:  QStringListH;
  buf:       WideString;
begin
  result := False;
  paths := ResourceCandidates;
  fontId := -1;
  for i := 0 to High(paths) do
    if FileExists(paths[i]) then
    begin
      wp := WideString(paths[i]);
      fontId := QFontDatabase_addApplicationFont(PWideString(@wp));
      if fontId >= 0 then
        break;
    end;
  if fontId < 0 then
  begin
    GFontFamily := '';
    exit;
  end;
  // The TTF's family name as Qt registered it — pick index 0 (the
  // font has a single family). We keep the configured constant if
  // the lookup fails for any reason; harmless on the happy path.
  families := QStringList_create();
  try
    QFontDatabase_applicationFontFamilies(families, fontId);
    if QStringList_size(families) > 0 then
    begin
      buf := '';
      QStringList_at(families, PWideString(@buf), 0);
      GFontFamily := string(buf);
    end
    else
      GFontFamily := ICON_FONT_FAMILY;
  finally
    QStringList_destroy(families);
  end;
  result := True;
end;

function IconFontFamily: string;
begin
  result := GFontFamily;
end;

// EncodeUcs4 — turn a Unicode codepoint into its UTF-8 byte sequence.
// LCL TLabel.Caption is UTF-8 in Lazarus convention; codepoints in
// the BMP (≤U+FFFF) round-trip through WideString fine, but we have
// supplementary-plane emoji (U+1F4CB clipboard) that need surrogate
// handling. Hand-rolled for portability.
function EncodeUcs4(ACp: Cardinal): string;
begin
  if ACp < $80 then
    result := Char(ACp)
  else if ACp < $800 then
    result :=
      Char($C0 or (ACp shr 6)) +
      Char($80 or (ACp and $3F))
  else if ACp < $10000 then
    result :=
      Char($E0 or (ACp shr 12)) +
      Char($80 or ((ACp shr 6) and $3F)) +
      Char($80 or (ACp and $3F))
  else
    result :=
      Char($F0 or (ACp shr 18)) +
      Char($80 or ((ACp shr 12) and $3F)) +
      Char($80 or ((ACp shr 6) and $3F)) +
      Char($80 or (ACp and $3F));
end;

function IconGlyph(AKind: TIconKind): string;
begin
  case AKind of
    iconList:       result := EncodeUcs4(CP_LIST);
    iconCaretLeft:  result := EncodeUcs4(CP_CARET_LEFT);
    iconBrokers:    result := EncodeUcs4(CP_CHART_BAR);
    iconPlans:      result := EncodeUcs4(CP_CLIPBOARD);
    iconRisk:       result := EncodeUcs4(CP_SHIELD);
    iconClerk:      result := EncodeUcs4(CP_FILE_TEXT);
    iconAi:         result := EncodeUcs4(CP_SPARKLE);
    iconSettings:   result := EncodeUcs4(CP_GEAR);
    iconNew:        result := EncodeUcs4(CP_PLUS_CIRCLE);
    iconRefresh:    result := EncodeUcs4(CP_ARROWS_CLOCK);
    iconSun:        result := EncodeUcs4(CP_SUN);
    iconMoon:       result := EncodeUcs4(CP_MOON);
  else
    result := '?';
  end;
end;

end.
