unit Radium.Gui.QtFusion;

{$mode Delphi}{$H+}

// Fusion-style + Light/Dark palette for Radium's Qt6 widgetset.
//
// Why this exists
// ───────────────
// LCL's per-widget Color/Font.Color stamping fights Qt's native
// styles. On macOS Qt picks the "macintosh" style by default, which
// renders TButton / TEdit / TComboBox with native chrome that ignores
// QPalette. Fusion is Qt's cross-platform widget style — it honours
// QPalette uniformly across every widget class on every OS we ship
// to (macOS, Linux, Windows). Combined with a calibrated palette,
// every TEdit/TButton/TPageControl/TStringGrid renders consistently
// with no per-control walking.
//
// Theme switching
// ───────────────
// `ApplyFusionTheme(kind)` resets the QPalette and the QSS overlay
// in one shot. Safe to call repeatedly at runtime — Qt re-paints
// every widget on the next event loop tick. The toggle in MainForm's
// sidebar drives this.

interface

uses
  Radium.Gui.Theme;

// Initialise Fusion style on the QApplication. Call once after
// Application.Initialize. Idempotent.
procedure InstallFusionStyle;

// Apply (or re-apply) the QPalette + QSS overlay matching AKind.
// Cheap to call on every theme toggle — Qt copies the palette
// internally on setPalette + diffs the stylesheet on setStyleSheet.
procedure ApplyFusionTheme(AKind: TThemeKind);

implementation

uses
  qt6;

const
  COLOR_SPEC_RGB = 1;
  ALPHA_FULL_16  = $FFFF;

// Channel16 — 8-bit channel scaled into Qt's 16-bit per-channel
// storage. Mirrors what QColor::setRgb(int) does internally
// (v << 8 | v) so colours match the integer-ctor reference.
function Channel16(AByte: Integer): Word; inline;
begin
  result := Word(AByte) or (Word(AByte) shl 8);
end;

procedure FillColor(out AColor: TQColor; R, G, B: Integer); inline;
begin
  AColor.ColorSpec := COLOR_SPEC_RGB;
  AColor.Alpha     := ALPHA_FULL_16;
  AColor.r         := Channel16(R);
  AColor.g         := Channel16(G);
  AColor.b         := Channel16(B);
  AColor.Pad       := 0;
end;

procedure SetRole(APalette: QPaletteH; ARole: QPaletteColorRole;
  R, G, B: Integer);
var
  c: TQColor;
begin
  FillColor(c, R, G, B);
  QPalette_setColor(APalette, QPaletteActive,   ARole, @c);
  QPalette_setColor(APalette, QPaletteInActive, ARole, @c);
end;

procedure SetRoleDisabled(APalette: QPaletteH; ARole: QPaletteColorRole;
  R, G, B: Integer);
var
  c: TQColor;
begin
  FillColor(c, R, G, B);
  QPalette_setColor(APalette, QPaletteDisabled, ARole, @c);
end;

// ── Light palette ─────────────────────────────────────────────────

procedure InstallLightPalette;
var
  pal: QPaletteH;
begin
  pal := QPalette_Create();
  try
    SetRole(pal, QPaletteWindow,          $FF, $FF, $FF);
    SetRole(pal, QPaletteWindowText,      $09, $09, $0B);
    SetRole(pal, QPaletteBase,            $FF, $FF, $FF);
    SetRole(pal, QPaletteAlternateBase,   $FA, $FA, $FA);
    SetRole(pal, QPaletteText,            $09, $09, $0B);
    SetRole(pal, QPaletteToolTipBase,     $FA, $FA, $FA);
    SetRole(pal, QPaletteToolTipText,     $09, $09, $0B);
    SetRole(pal, QPaletteButton,          $F4, $F4, $F5);
    SetRole(pal, QPaletteButtonText,      $09, $09, $0B);
    SetRole(pal, QPaletteBrightText,      $DC, $26, $26);
    SetRole(pal, QPaletteHighlight,       $63, $66, $F1);
    SetRole(pal, QPaletteHighlightedText, $FF, $FF, $FF);
    SetRole(pal, QPaletteLink,            $63, $66, $F1);

    SetRoleDisabled(pal, QPaletteWindowText, $A1, $A1, $AA);
    SetRoleDisabled(pal, QPaletteText,       $A1, $A1, $AA);
    SetRoleDisabled(pal, QPaletteButtonText, $A1, $A1, $AA);

    QApplication_setPalette(pal, nil);
  finally
    QPalette_Destroy(pal);
  end;
end;

// ── Dark palette ──────────────────────────────────────────────────

procedure InstallDarkPalette;
var
  pal: QPaletteH;
begin
  pal := QPalette_Create();
  try
    SetRole(pal, QPaletteWindow,          $0A, $0A, $0B);
    SetRole(pal, QPaletteWindowText,      $FA, $FA, $FA);
    SetRole(pal, QPaletteBase,            $1C, $1C, $20);
    SetRole(pal, QPaletteAlternateBase,   $14, $14, $17);
    SetRole(pal, QPaletteText,            $FA, $FA, $FA);
    SetRole(pal, QPaletteToolTipBase,     $1C, $1C, $20);
    SetRole(pal, QPaletteToolTipText,     $FA, $FA, $FA);
    SetRole(pal, QPaletteButton,          $1C, $1C, $20);
    SetRole(pal, QPaletteButtonText,      $FA, $FA, $FA);
    SetRole(pal, QPaletteBrightText,      $F8, $71, $71);
    SetRole(pal, QPaletteHighlight,       $81, $8C, $F8);
    SetRole(pal, QPaletteHighlightedText, $FA, $FA, $FA);
    SetRole(pal, QPaletteLink,            $81, $8C, $F8);

    SetRoleDisabled(pal, QPaletteWindowText, $52, $52, $5B);
    SetRoleDisabled(pal, QPaletteText,       $52, $52, $5B);
    SetRoleDisabled(pal, QPaletteButtonText, $52, $52, $5B);

    QApplication_setPalette(pal, nil);
  finally
    QPalette_Destroy(pal);
  end;
end;

// ── Stylesheets ──────────────────────────────────────────────────

procedure InstallStylesheet(const AQss: WideString);
var
  app: QApplicationH;
begin
  app := QApplicationH(QCoreApplication_instance);
  if app <> nil then
    QApplication_setStyleSheet(app, PWideString(@AQss));
end;

const
  // Light QSS — see commit history / Docs/LookAndFeel.md for the
  // calibration. Targets only widgets where Fusion's auto-derivation
  // reads poorly.
  LIGHT_QSS: WideString =
    'QTabWidget::pane { background: #FFFFFF; border: 1px solid #E4E4E7; top: -1px; } '+
    'QTabBar { background: #FFFFFF; qproperty-drawBase: 0; } '+
    'QTabBar::tab { background: #F4F4F5; color: #71717A; padding: 6px 16px; '+
    '  border: 1px solid #E4E4E7; border-bottom: none; margin-right: 2px; } '+
    'QTabBar::tab:selected { background: #FFFFFF; color: #09090B; '+
    '  border-color: #D4D4D8; border-bottom: 2px solid #6366F1; } '+
    'QTabBar::tab:hover:!selected { background: #FAFAFA; color: #09090B; } '+
    'QGroupBox { border: 1px solid #E4E4E7; margin-top: 12px; padding-top: 10px; } '+
    'QGroupBox::title { color: #71717A; subcontrol-origin: margin; left: 8px; } '+
    'QHeaderView::section { background: #FAFAFA; color: #52525B; padding: 4px 8px; '+
    '  border: 1px solid #E4E4E7; } ';

  // Dark QSS — symmetric to light. Active tab uses elevated bg
  // (#1C1C20) against canvas (#0A0A0B) with the same indigo bottom
  // strip; the indigo brightens slightly on dark backgrounds.
  DARK_QSS: WideString =
    'QTabWidget::pane { background: #0A0A0B; border: 1px solid #2A2A2E; top: -1px; } '+
    'QTabBar { background: #0A0A0B; qproperty-drawBase: 0; } '+
    'QTabBar::tab { background: #14141A; color: #A1A1AA; padding: 6px 16px; '+
    '  border: 1px solid #2A2A2E; border-bottom: none; margin-right: 2px; } '+
    'QTabBar::tab:selected { background: #1C1C20; color: #FAFAFA; '+
    '  border-color: #3F3F46; border-bottom: 2px solid #818CF8; } '+
    'QTabBar::tab:hover:!selected { background: #1C1C20; color: #FAFAFA; } '+
    'QGroupBox { border: 1px solid #2A2A2E; margin-top: 12px; padding-top: 10px; } '+
    'QGroupBox::title { color: #A1A1AA; subcontrol-origin: margin; left: 8px; } '+
    'QHeaderView::section { background: #14141A; color: #A1A1AA; padding: 4px 8px; '+
    '  border: 1px solid #2A2A2E; } ';

// ── public surface ────────────────────────────────────────────────

procedure InstallFusionStyle;
var
  styleName: WideString;
begin
  styleName := 'Fusion';
  QApplication_setStyle(PWideString(@styleName));
end;

procedure ApplyFusionTheme(AKind: TThemeKind);
begin
  case AKind of
    tkDark:
    begin
      InstallDarkPalette;
      InstallStylesheet(DARK_QSS);
    end;
  else
    InstallLightPalette;
    InstallStylesheet(LIGHT_QSS);
  end;
  Radium.Gui.Theme.SetActiveTheme(AKind);
end;

end.
