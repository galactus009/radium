unit Radium.Gui.Theme;

(* ----------------------------------------------------------------------------
  Active palette + theme application for Radium's GUI shell.

  Pinned spec: Docs/LookAndFeel.md. This unit owns the Light + Dark
  token tables verbatim and exposes them through one type-safe getter:

      Theme.Token(tBgCanvas)

  Apply() walks a control tree once and stamps the relevant tokens onto
  the control properties LCL exposes uniformly across widgetsets:
  TForm.Color / TPanel.Color / TStatusBar.Color, plus Font.Color where
  the surface carries text. Native menu chrome (TMainMenu / TMenuItem)
  stays OS-defined on purpose — re-skinning the menubar reliably needs
  the Qt6 QApplication.setStyleSheet route, which costs widgetset
  coupling for marginal gain. macOS / Win11 / GNOME native menus
  already look modern.

  Theme switching is process-wide: call SetActiveTheme + Apply() on the
  main form (which propagates to children). View → Theme menu items
  drive this. Choice persists in app settings (slice 2.x).
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  Classes,
  Graphics,
  Controls;

type
  // Match Docs/LookAndFeel.md §1. Both Light and Dark resolve every
  // token; missing entries would mean a relationship the doc didn't
  // calibrate, which we never want to ship.
  TThemeKind = (tkLight, tkDark);

  TPaletteToken = (
    tBgCanvas,        tBgSurface,       tBgElevated,
    tBorderSubtle,    tBorderStrong,
    tFgPrimary,       tFgSecondary,     tFgMuted,
    tAccentPrimary,   tAccentHover,
    tSuccess,         tWarning,         tDanger,        tInfo
  );

  // Semantic intent of an interactive control. See LookAndFeel.md
  // §1.5 — every action button must declare its kind, never freelance
  // a colour. The set is closed; if you need a new kind, the doc
  // changes first.
  TSemanticKind = (
    skNeutral, skPrimary,
    skBuy,     skSell,    skCancel,
    skDelete,  skModify,  skInfo,
    skMuted
  );

function ActiveTheme: TThemeKind;
procedure SetActiveTheme(AKind: TThemeKind);

// TColor lookup for the currently active theme. Use this — never
// embed hex in calling code.
function Token(AToken: TPaletteToken): TColor;

// Token mapped from a semantic kind. Background colours stay canonical
// (per §1); semantic kind paints Font.Color (and bg, where the widget
// permits — see SetSemantic).
function SemanticForeground(AKind: TSemanticKind): TColor;

// One-shot tagging: paints the control's font with the semantic kind's
// colour. Call from FormCreate (or wherever the control is built) so
// every action's intent is obvious at a glance. Re-applied by ApplyTheme
// when the active theme flips.
procedure SetSemantic(AControl: TControl; AKind: TSemanticKind);

// Stamp the palette onto the control and recurse. Idempotent — call
// again after SetActiveTheme to reskin live. Preserves any prior
// SetSemantic tagging on each control.
procedure Apply(ARoot: TWinControl);

implementation

uses
  SysUtils,
  StdCtrls,
  ExtCtrls,
  ComCtrls,
  Buttons,
  EditBtn,
  Spin,
  Grids,
  Forms;

// TColor encodes BGR ($00BBGGRR), so every literal below is the doc's
// CSS hex (RRGGBB) with bytes reversed. Source of truth for the CSS
// hex side: Docs/LookAndFeel.md §1.
//
// Palette is Linear/Vercel/Cursor-inspired: warm neutrals (no slate
// blue tint), three clearly separable elevation steps, a single
// indigo accent. Earlier slate-blue dark theme had the bug that
// borderSubtle == bgElevated, so card edges literally vanished —
// fixed here by spacing borders one step lighter than elevated.

const
  LightPalette: array[TPaletteToken] of TColor = (
    {tBgCanvas      #FFFFFF} TColor($00FFFFFF),
    {tBgSurface     #FAFAFA} TColor($00FAFAFA),
    {tBgElevated    #FFFFFF} TColor($00FFFFFF),
    {tBorderSubtle  #E4E4E7} TColor($00E7E4E4),
    {tBorderStrong  #D4D4D8} TColor($00D8D4D4),
    {tFgPrimary     #09090B} TColor($000B0909),
    {tFgSecondary   #52525B} TColor($005B5252),
    {tFgMuted       #71717A} TColor($007A7171),
    {tAccentPrimary #6366F1} TColor($00F16663),
    {tAccentHover   #4F46E5} TColor($00E5464F),
    {tSuccess       #16A34A} TColor($004AA316),
    {tWarning       #CA8A04} TColor($00048ACA),
    {tDanger        #DC2626} TColor($002626DC),
    {tInfo          #0891B2} TColor($00B29108)
  );

  DarkPalette: array[TPaletteToken] of TColor = (
    {tBgCanvas      #0A0A0B} TColor($000B0A0A),
    {tBgSurface     #141417} TColor($00171414),
    {tBgElevated    #1C1C20} TColor($00201C1C),
    {tBorderSubtle  #2A2A2E} TColor($002E2A2A),
    {tBorderStrong  #3F3F46} TColor($00463F3F),
    {tFgPrimary     #FAFAFA} TColor($00FAFAFA),
    {tFgSecondary   #A1A1AA} TColor($00AAA1A1),
    {tFgMuted       #71717A} TColor($007A7171),
    {tAccentPrimary #818CF8} TColor($00F88C81),
    {tAccentHover   #6366F1} TColor($00F16663),
    {tSuccess       #22C55E} TColor($005EC522),
    {tWarning       #FBBF24} TColor($0024BFFB),
    {tDanger        #F87171} TColor($007171F8),
    {tInfo          #22D3EE} TColor($00EED322)
  );

var
  GActive: TThemeKind = tkLight;

function ActiveTheme: TThemeKind;
begin
  result := GActive;
end;

procedure SetActiveTheme(AKind: TThemeKind);
begin
  GActive := AKind;
end;

function Token(AToken: TPaletteToken): TColor;
begin
  case GActive of
    tkDark: result := DarkPalette[AToken];
  else
    result := LightPalette[AToken];
  end;
end;

const
  // Semantic kind is stamped into TControl.Tag so theme switches can
  // re-apply the right colour without re-walking the call site. Tag=0
  // means "untagged"; valid kinds occupy Tag = Ord(kind) + 1.
  SEMANTIC_TAG_BASE = 1;

function SemanticForeground(AKind: TSemanticKind): TColor;
begin
  case AKind of
    skPrimary: result := Token(tAccentPrimary);
    skBuy:     result := Token(tSuccess);
    skSell:    result := Token(tDanger);
    skCancel:  result := Token(tDanger);
    skDelete:  result := Token(tDanger);
    skModify:  result := Token(tWarning);
    skInfo:    result := Token(tInfo);
    skMuted:   result := Token(tFgMuted);
  else
    result := Token(tFgPrimary); // skNeutral
  end;
end;

procedure ApplySemanticToControl(AControl: TControl); forward;

procedure SetSemantic(AControl: TControl; AKind: TSemanticKind);
begin
  if AControl = nil then
    exit;
  AControl.Tag := SEMANTIC_TAG_BASE + Ord(AKind);
  ApplySemanticToControl(AControl);
end;

procedure ApplySemanticToControl(AControl: TControl);
var
  kindIdx: Integer;
  fc: TColor;
begin
  kindIdx := AControl.Tag - SEMANTIC_TAG_BASE;
  if (kindIdx < Ord(Low(TSemanticKind))) or
     (kindIdx > Ord(High(TSemanticKind))) then
    exit;
  fc := SemanticForeground(TSemanticKind(kindIdx));
  // TGraphicControl + TWinControl both publish Font; that covers
  // TLabel / TSpeedButton / TButton / TEdit / TBitBtn etc. Plain
  // TControl doesn't, so we narrow the cast.
  if AControl is TGraphicControl then
    TGraphicControl(AControl).Font.Color := fc
  else if AControl is TWinControl then
    TWinControl(AControl).Font.Color := fc;
end;

// ApplyOne — surface-specific stamping. Only touches properties LCL
// guarantees on the concrete class; falls through to recurse.
procedure ApplyOne(AControl: TControl); forward;

procedure ApplyChildren(AParent: TWinControl);
var
  i: Integer;
begin
  for i := 0 to AParent.ControlCount - 1 do
    ApplyOne(AParent.Controls[i]);
end;

procedure ApplyOne(AControl: TControl);
begin
  if AControl is TForm then
  begin
    TForm(AControl).Color := Token(tBgCanvas);
    TForm(AControl).Font.Color := Token(tFgPrimary);
    ApplyChildren(TForm(AControl));
  end
  else if AControl is TPanel then
  begin
    // Default panels paint with the canvas colour so the form reads
    // flat. Two by-name overrides give the sidebar / centre card
    // their visual identity (off-white sidebar against bright
    // canvas centre, per Docs/LookAndFeel.md §1).
    if SameText(AControl.Name, 'SidebarHost') or
       SameText(AControl.Name, 'SidebarTopGroup') or
       SameText(AControl.Name, 'SidebarSpring') or
       SameText(AControl.Name, 'SidebarBotGroup') then
      TPanel(AControl).Color := Token(tBgSurface)
    else
      TPanel(AControl).Color := Token(tBgCanvas);
    TPanel(AControl).Font.Color := Token(tFgPrimary);
    TPanel(AControl).BevelOuter := bvNone;
    TPanel(AControl).BevelInner := bvNone;
    ApplyChildren(TPanel(AControl));
  end
  else if AControl is TStatusBar then
  begin
    TStatusBar(AControl).Color := Token(tBgSurface);
    TStatusBar(AControl).Font.Color := Token(tFgSecondary);
  end
  else if AControl is TLabel then
  begin
    TLabel(AControl).Font.Color := Token(tFgPrimary);
    ApplySemanticToControl(AControl);
  end
  // ── Tab containers: let the page bg follow canvas so tab bodies
  // read like the surrounding frame, not white.
  else if AControl is TPageControl then
  begin
    TPageControl(AControl).Color := Token(tBgCanvas);
    TPageControl(AControl).Font.Color := Token(tFgPrimary);
    ApplyChildren(TPageControl(AControl));
  end
  else if AControl is TTabSheet then
  begin
    TTabSheet(AControl).Color := Token(tBgCanvas);
    TTabSheet(AControl).Font.Color := Token(tFgPrimary);
    ApplyChildren(TTabSheet(AControl));
  end
  else if AControl is TTabControl then
  begin
    TTabControl(AControl).Color := Token(tBgCanvas);
    TTabControl(AControl).Font.Color := Token(tFgPrimary);
    ApplyChildren(TTabControl(AControl));
  end
  // ── Editable inputs: paint surface bg + primary fg so empty fields
  // don't read as bright-white blocks on a dark canvas. Covers
  // TEdit, TMemo, TLabeledEdit, TDateEdit, TFloatSpinEdit, TSpinEdit
  // through the TCustomEdit base.
  else if AControl is TCustomEdit then
  begin
    TCustomEdit(AControl).Color := Token(tBgElevated);
    TCustomEdit(AControl).Font.Color := Token(tFgPrimary);
    ApplyChildren(TCustomEdit(AControl) as TWinControl);
  end
  else if AControl is TCustomComboBox then
  begin
    TCustomComboBox(AControl).Color := Token(tBgElevated);
    TCustomComboBox(AControl).Font.Color := Token(tFgPrimary);
    ApplyChildren(TCustomComboBox(AControl) as TWinControl);
  end
  else if AControl is TCustomListBox then
  begin
    TCustomListBox(AControl).Color := Token(tBgElevated);
    TCustomListBox(AControl).Font.Color := Token(tFgPrimary);
    ApplyChildren(TCustomListBox(AControl) as TWinControl);
  end
  else if AControl is TCustomCheckBox then
  begin
    TCustomCheckBox(AControl).Font.Color := Token(tFgPrimary);
    ApplySemanticToControl(AControl);
    ApplyChildren(TCustomCheckBox(AControl) as TWinControl);
  end
  else if AControl is TRadioButton then
  begin
    TRadioButton(AControl).Font.Color := Token(tFgPrimary);
    ApplySemanticToControl(AControl);
    ApplyChildren(TRadioButton(AControl) as TWinControl);
  end
  else if AControl is TCustomGroupBox then
  begin
    TCustomGroupBox(AControl).Color := Token(tBgCanvas);
    TCustomGroupBox(AControl).Font.Color := Token(tFgPrimary);
    ApplyChildren(TCustomGroupBox(AControl) as TWinControl);
  end
  // ── Push buttons: Qt6 paints native chrome so Color often gets
  // ignored, but the font we can control. Semantic tag wins for
  // colour-coded actions; otherwise primary fg.
  else if AControl is TCustomButton then
  begin
    if AControl.Tag = 0 then
      TCustomButton(AControl).Font.Color := Token(tFgPrimary)
    else
      ApplySemanticToControl(AControl);
  end
  else if AControl is TBitBtn then
  begin
    if AControl.Tag = 0 then
      TBitBtn(AControl).Font.Color := Token(tFgPrimary)
    else
      ApplySemanticToControl(AControl);
  end
  else if AControl is TCustomGrid then
  begin
    TCustomGrid(AControl).Color := Token(tBgElevated);
    TCustomGrid(AControl).Font.Color := Token(tFgPrimary);
  end
  else if AControl is TGraphicControl then
  begin
    // TSpeedButton, TBevel etc — let the semantic tag drive Font
    // colour so SetSemantic() survives a theme switch.
    ApplySemanticToControl(AControl);
  end
  else if AControl is TWinControl then
  begin
    ApplySemanticToControl(AControl);
    ApplyChildren(TWinControl(AControl));
  end;
end;

procedure Apply(ARoot: TWinControl);
begin
  if ARoot = nil then
    exit;
  ApplyOne(ARoot);
end;

end.
