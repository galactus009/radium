unit Radium.Gui.NavButton;

{$mode Delphi}{$H+}

// TNavButton — sidebar nav-item compound widget.
//
// What it is
// ──────────
// A clickable TPanel hosting two TLabels: an icon glyph (icon font)
// and a caption (regular font). One semantic widget per sidebar
// destination, swappable between Expanded / Collapsed visual modes.
//
// Why a compound, not a TSpeedButton
// ──────────────────────────────────
// SpeedButton.Caption is a single string in a single font — we can't
// mix the icon font (Phosphor) with the regular UI font (system
// sans). We could overlay a TSpeedButton + TLabel, but a clean
// compound is less fragile and lets the active/hover state apply
// uniformly to both surfaces.
//
// State model
// ───────────
// - Active: highlighted bg + accent fg. Set by MainForm whenever the
//   centre frame is the matching destination.
// - Collapsed: caption hidden, button width shrinks to icon-only.
//   Driven by MainForm's nav-collapsed flag.
// - Hover: bg lightens. Bound to mouse-enter/leave on both labels.

interface

uses
  Classes,
  SysUtils,
  Controls,
  ExtCtrls,
  StdCtrls,
  Graphics,
  Radium.Gui.Icons;

type

  { TNavButton }
  TNavButton = class(TPanel)
  private
    FIconLbl:    TLabel;
    FCaptionLbl: TLabel;
    FOnNavClick: TNotifyEvent;
    FActive:     Boolean;
    FHovered:    Boolean;
    FCollapsed:  Boolean;
    FBaseColor:  TColor;
    FActiveBg:   TColor;
    FHoverBg:    TColor;
    FFgIdle:     TColor;
    FFgActive:   TColor;

    procedure ChildClick(Sender: TObject);
    procedure ChildEnter(Sender: TObject);
    procedure ChildLeave(Sender: TObject);
    procedure Repaint2;
  public
    constructor Create(AOwner: TComponent); override;

    procedure Configure(const AIcon: TIconKind; const ACaption: string);
    procedure SetActive(AActive: Boolean);
    procedure SetCollapsed(ACollapsed: Boolean);
    procedure SetColors(ABase, AActiveBg, AHoverBg, AFgIdle, AFgActive: TColor);

    property OnNavClick: TNotifyEvent read FOnNavClick write FOnNavClick;
    property IsActive:   Boolean       read FActive;
    property IsCollapsed: Boolean      read FCollapsed;
  end;

const
  NAV_ROW_HEIGHT       = 40;
  NAV_ICON_BOX_WIDTH   = 40;   // icon column width — same in both modes
  NAV_ICON_FONT_SIZE   = 18;   // visual size of the icon glyph
  NAV_CAPTION_FONT_SIZE = 11;  // expanded-mode caption size

implementation

{ TNavButton ──────────────────────────────────────────────────────── }

constructor TNavButton.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption    := '';
  Cursor     := crHandPoint;
  Height     := NAV_ROW_HEIGHT;

  FIconLbl := TLabel.Create(Self);
  FIconLbl.Parent     := Self;
  FIconLbl.AutoSize   := False;
  FIconLbl.Left       := 0;
  FIconLbl.Top        := 0;
  FIconLbl.Width      := NAV_ICON_BOX_WIDTH;
  FIconLbl.Height     := NAV_ROW_HEIGHT;
  FIconLbl.Alignment  := taCenter;
  FIconLbl.Layout     := tlCenter;
  FIconLbl.Cursor     := crHandPoint;
  FIconLbl.OnClick      := ChildClick;
  FIconLbl.OnMouseEnter := ChildEnter;
  FIconLbl.OnMouseLeave := ChildLeave;
  // Configure() picks up the icon font once it's been registered.

  FCaptionLbl := TLabel.Create(Self);
  FCaptionLbl.Parent     := Self;
  FCaptionLbl.AutoSize   := False;
  FCaptionLbl.Left       := NAV_ICON_BOX_WIDTH + 4;
  FCaptionLbl.Top        := 0;
  FCaptionLbl.Width      := 140;
  FCaptionLbl.Height     := NAV_ROW_HEIGHT;
  FCaptionLbl.Layout     := tlCenter;
  FCaptionLbl.Cursor     := crHandPoint;
  FCaptionLbl.Font.Height  := -NAV_CAPTION_FONT_SIZE;
  FCaptionLbl.OnClick      := ChildClick;
  FCaptionLbl.OnMouseEnter := ChildEnter;
  FCaptionLbl.OnMouseLeave := ChildLeave;

  FBaseColor := clNone;
  FActiveBg  := clNone;
  FHoverBg   := clNone;
  FFgIdle    := clNone;
  FFgActive  := clNone;

  OnClick      := ChildClick;
  OnMouseEnter := ChildEnter;
  OnMouseLeave := ChildLeave;
end;

procedure TNavButton.Configure(const AIcon: TIconKind; const ACaption: string);
var
  family: string;
begin
  // If a custom icon-font has been registered (LoadIconFont
  // returned True with a non-empty family), use it for the glyph
  // column. Otherwise the glyph stays in the system font — our
  // codepoints are common Unicode geometric shapes that render
  // cleanly without a bundled font.
  family := IconFontFamily;
  if family <> '' then
    FIconLbl.Font.Name := family;
  FIconLbl.Font.Height := -NAV_ICON_FONT_SIZE;
  FIconLbl.Caption     := IconGlyph(AIcon);
  FCaptionLbl.Caption  := ACaption;
end;

procedure TNavButton.SetActive(AActive: Boolean);
begin
  if FActive = AActive then exit;
  FActive := AActive;
  Repaint2;
end;

procedure TNavButton.SetCollapsed(ACollapsed: Boolean);
begin
  if FCollapsed = ACollapsed then exit;
  FCollapsed := ACollapsed;
  FCaptionLbl.Visible := not FCollapsed;
end;

procedure TNavButton.SetColors(ABase, AActiveBg, AHoverBg, AFgIdle, AFgActive: TColor);
begin
  FBaseColor := ABase;
  FActiveBg  := AActiveBg;
  FHoverBg   := AHoverBg;
  FFgIdle    := AFgIdle;
  FFgActive  := AFgActive;
  Repaint2;
end;

procedure TNavButton.ChildClick(Sender: TObject);
begin
  if Assigned(FOnNavClick) then FOnNavClick(Self);
end;

procedure TNavButton.ChildEnter(Sender: TObject);
begin
  if FHovered then exit;
  FHovered := True;
  Repaint2;
end;

procedure TNavButton.ChildLeave(Sender: TObject);
begin
  if not FHovered then exit;
  FHovered := False;
  Repaint2;
end;

procedure TNavButton.Repaint2;
var
  bg, fg: TColor;
begin
  // State precedence: active > hover > base. Active is "operator is
  // currently looking at this destination" — should always win over
  // hover on a different row, and even on the same row.
  if FActive then
  begin
    bg := FActiveBg;
    fg := FFgActive;
  end
  else if FHovered then
  begin
    bg := FHoverBg;
    fg := FFgActive;
  end
  else
  begin
    bg := FBaseColor;
    fg := FFgIdle;
  end;
  Color               := bg;
  FIconLbl.Color      := bg;  FIconLbl.ParentColor    := False;
  FCaptionLbl.Color   := bg;  FCaptionLbl.ParentColor := False;
  FIconLbl.Font.Color    := fg;
  FCaptionLbl.Font.Color := fg;
end;

end.
