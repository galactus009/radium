unit Radium.Gui.StatusFrame;

(* ----------------------------------------------------------------------------
  Status frame — centre-host content for the "Status" sidebar destination.
  Mirrors `thoriumctl status` plus the metrics fan-out the GUI status bar
  doesn't have room for. Pulls /status (typed via TThoriumClient.Status)
  and renders:

    +- thoriumd Status ──────────────────────────────────────────────+
    |                                                                |
    |   UPTIME      MEMORY         TICKS / SEC      GOROUTINES       |
    |   3h 22m      48 MB          1,420 (60s)     142               |
    |                                                                |
    |   TICKS TOTAL   BUS SUBS                                       |
    |   1,234,567     6                                              |
    |                                                                |
    |  ATTACHED SESSIONS                                             |
    |   alpha   fyers   Data+REST   148,231 rows   attached 09:14    |
    |   beta    kite    REST only    98,442 rows   attached 09:18    |
    |                                                                |
    |  DETAILED METRICS                                              |
    |   key                       value                              |
    |   ─────────────────────────────────────                        |
    |   uptime                    3h 22m 14s                         |
    |   ticks_per_sec_1s          1,400.0                            |
    |   ...                                                          |
    +----------------------------------------------------------------+

  Auto-refresh: while the panel is visible, /status fires every 5
  seconds. Hidden panel → timer pauses (no /status traffic when the
  operator is on Plans / Risk / Clerk). Faster cadence than the
  process-level heartbeat (which only pings) because here the
  numbers are the point — ticks/sec changes 5x/minute.

  Frame raises events; MainForm owns the client + timer, same pattern
  as the other frames.
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  Classes,
  SysUtils,
  Forms,
  Controls,
  Graphics,
  Grids,
  ExtCtrls,
  StdCtrls,
  mormot.core.base,
  Radium.Api.Types,
  Radium.Gui.Theme;

type
  TStatusReloadEvent = procedure(Sender: TObject) of object;

  { TStatusFrame }
  TStatusFrame = class(TPanel)
  private
    FTopBar:        TPanel;
      FBtnReload:   TButton;
      FChkAuto:     TCheckBox;
      FStatusLbl:   TLabel;

    FTilesCard:     TPanel;
      FTileUptime,
      FTileMem,
      FTileTicksPerSec,
      FTileGoroutines,
      FTileTicksTotal,
      FTileBusSubs:   TPanel;

    FSessionsCard:  TPanel;
      FSessionsLbl:  TLabel;
      FSessionsGrid: TStringGrid;

    FMetricsCard:   TPanel;
      FMetricsLbl:   TLabel;
      FMetricsGrid:  TStringGrid;

    FOnReload:      TStatusReloadEvent;
    FOnAutoToggle:  TStatusReloadEvent;

    procedure BuildTopBar;
    procedure BuildTilesCard;
    procedure BuildSessionsCard;
    procedure BuildMetricsCard;

    function MakeTile(AParent: TWinControl; const ACap: string;
      ALeft, AWidth: Integer): TPanel;
    procedure SetTileValue(ATile: TPanel; const AValue: string;
      AKind: TSemanticKind);

    procedure DoReloadClick(Sender: TObject);
    procedure DoAutoToggle(Sender: TObject);

    function FormatUptime(const ARaw: RawUtf8): string;
    function FormatThou(AValue: Int64): string;
    function FormatThouFloat(AValue: Double): string;
    function FormatMem(AMb: Double): string;
    function FormatTimeOnly(const ARfc3339: RawUtf8): string;
    function RoleLabel(const ASession: TStatusSession): string;
  public
    constructor Create(AOwner: TComponent); override;

    procedure SetStatus(const AStatus: TStatusResult);
    procedure SetStatusText(const AText: string; AKind: Integer);

    function AutoRefreshEnabled: Boolean;

    property OnReload:     TStatusReloadEvent read FOnReload     write FOnReload;
    property OnAutoToggle: TStatusReloadEvent read FOnAutoToggle write FOnAutoToggle;
  end;

implementation

const
  TOPBAR_H        = 56;
  TILES_H         = 152;
  SESSIONS_H      = 168;

  TILE_W          = 200;
  TILE_GAP        = 12;

{ TStatusFrame ────────────────────────────────────────────────────── }

constructor TStatusFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption    := '';

  BuildTopBar;
  BuildTilesCard;
  BuildSessionsCard;
  BuildMetricsCard;
end;

procedure TStatusFrame.BuildTopBar;
begin
  FTopBar := TPanel.Create(Self);
  FTopBar.Parent     := Self;
  FTopBar.Align      := alTop;
  FTopBar.Height     := TOPBAR_H;
  FTopBar.BevelOuter := bvNone;
  FTopBar.Caption    := '';

  FBtnReload := TButton.Create(FTopBar);
  FBtnReload.Parent  := FTopBar;
  FBtnReload.Left    := 16;
  FBtnReload.Top     := 14;
  FBtnReload.Width   := 130;
  FBtnReload.Height  := 30;
  FBtnReload.Caption := 'Refresh now';
  FBtnReload.OnClick := DoReloadClick;
  SetSemantic(FBtnReload, skPrimary);

  FChkAuto := TCheckBox.Create(FTopBar);
  FChkAuto.Parent  := FTopBar;
  FChkAuto.Left    := 160;
  FChkAuto.Top     := 18;
  FChkAuto.Width   := 220;
  FChkAuto.Height  := 22;
  FChkAuto.Caption := 'Auto-refresh every 5 seconds';
  FChkAuto.Checked := True;
  FChkAuto.OnChange := DoAutoToggle;

  FStatusLbl := TLabel.Create(FTopBar);
  FStatusLbl.Parent := FTopBar;
  FStatusLbl.Left   := 400;
  FStatusLbl.Top    := 20;
  FStatusLbl.AutoSize := True;
  FStatusLbl.Caption := '';
  FStatusLbl.Font.Height := -12;
  FStatusLbl.ParentColor := True;
  FStatusLbl.ParentFont  := False;
  SetSemantic(FStatusLbl, skMuted);
end;

function TStatusFrame.MakeTile(AParent: TWinControl;
  const ACap: string; ALeft, AWidth: Integer): TPanel;
var
  capLbl: TLabel;
begin
  result := TPanel.Create(AParent);
  result.Parent     := AParent;
  result.Left       := ALeft;
  result.Top        := 8;
  result.Width      := AWidth;
  result.Height     := TILES_H - 16;
  result.BevelOuter := bvNone;
  result.Caption    := '';
  result.Tag        := -1;     // sentinel; SetTileValue stamps semantic Tag

  capLbl := TLabel.Create(result);
  capLbl.Name    := 'TileCap';
  capLbl.Parent  := result;
  capLbl.Left    := 12;
  capLbl.Top     := 12;
  capLbl.Caption := UpperCase(ACap);
  capLbl.AutoSize := True;
  capLbl.Font.Height := -10;
  capLbl.Font.Style  := [fsBold];
  capLbl.ParentColor := True;
  capLbl.ParentFont  := False;
  SetSemantic(capLbl, skMuted);

  // Value label — name 'TileVal' so SetTileValue can find it without
  // hanging on to a per-tile field.
  with TLabel.Create(result) do
  begin
    Name   := 'TileVal';
    Parent := result;
    Left   := 12;
    Top    := 36;
    Caption := '-';
    AutoSize := True;
    Font.Height := -22;
    Font.Style  := [fsBold];
    ParentColor := True;
    ParentFont  := False;
    SetSemantic(TLabel(Self), skNeutral);
  end;
end;

procedure TStatusFrame.SetTileValue(ATile: TPanel; const AValue: string;
  AKind: TSemanticKind);
var
  i: Integer;
  c: TControl;
begin
  if ATile = nil then exit;
  for i := 0 to ATile.ControlCount - 1 do
  begin
    c := ATile.Controls[i];
    if (c is TLabel) and SameText(c.Name, 'TileVal') then
    begin
      TLabel(c).Caption := AValue;
      SetSemantic(c, AKind);
      exit;
    end;
  end;
end;

procedure TStatusFrame.BuildTilesCard;
var x: Integer;
begin
  FTilesCard := TPanel.Create(Self);
  FTilesCard.Parent     := Self;
  FTilesCard.Align      := alTop;
  FTilesCard.Height     := TILES_H;
  FTilesCard.BevelOuter := bvNone;
  FTilesCard.Caption    := '';

  x := 16;
  FTileUptime       := MakeTile(FTilesCard, 'Uptime',         x, TILE_W); Inc(x, TILE_W + TILE_GAP);
  FTileMem          := MakeTile(FTilesCard, 'Memory',         x, TILE_W); Inc(x, TILE_W + TILE_GAP);
  FTileTicksPerSec  := MakeTile(FTilesCard, 'Ticks / sec (60s)', x, TILE_W); Inc(x, TILE_W + TILE_GAP);
  FTileGoroutines   := MakeTile(FTilesCard, 'Goroutines',     x, TILE_W); Inc(x, TILE_W + TILE_GAP);
  FTileTicksTotal   := MakeTile(FTilesCard, 'Ticks total',    x, TILE_W); Inc(x, TILE_W + TILE_GAP);
  FTileBusSubs      := MakeTile(FTilesCard, 'Bus subs',       x, TILE_W);
end;

procedure TStatusFrame.BuildSessionsCard;
begin
  FSessionsCard := TPanel.Create(Self);
  FSessionsCard.Parent     := Self;
  FSessionsCard.Align      := alTop;
  FSessionsCard.Height     := SESSIONS_H;
  FSessionsCard.BevelOuter := bvNone;
  FSessionsCard.Caption    := '';

  FSessionsLbl := TLabel.Create(FSessionsCard);
  FSessionsLbl.Parent := FSessionsCard;
  FSessionsLbl.Caption := 'ATTACHED SESSIONS';
  FSessionsLbl.Left := 16;
  FSessionsLbl.Top  := 8;
  FSessionsLbl.AutoSize := True;
  FSessionsLbl.Font.Height := -10;
  FSessionsLbl.Font.Style  := [fsBold];
  FSessionsLbl.ParentColor := True;
  FSessionsLbl.ParentFont  := False;
  SetSemantic(FSessionsLbl, skMuted);

  FSessionsGrid := TStringGrid.Create(FSessionsCard);
  FSessionsGrid.Parent       := FSessionsCard;
  FSessionsGrid.Left         := 16;
  FSessionsGrid.Top          := 32;
  FSessionsGrid.Width        := 1080;
  FSessionsGrid.Height       := SESSIONS_H - 48;
  FSessionsGrid.Anchors      := [akLeft, akTop, akRight];
  FSessionsGrid.RowCount     := 2;       // 1 header + 1 placeholder
  FSessionsGrid.ColCount     := 6;
  FSessionsGrid.FixedRows    := 1;
  FSessionsGrid.FixedCols    := 0;
  FSessionsGrid.Cells[0, 0]  := 'Instance';
  FSessionsGrid.Cells[1, 0]  := 'Broker';
  FSessionsGrid.Cells[2, 0]  := 'Role';
  FSessionsGrid.Cells[3, 0]  := 'Catalog rows';
  FSessionsGrid.Cells[4, 0]  := 'Attached at';
  FSessionsGrid.Cells[5, 0]  := 'Adapter';
  FSessionsGrid.ColWidths[0] := 160;
  FSessionsGrid.ColWidths[1] := 100;
  FSessionsGrid.ColWidths[2] := 130;
  FSessionsGrid.ColWidths[3] := 140;
  FSessionsGrid.ColWidths[4] := 220;
  FSessionsGrid.ColWidths[5] := 100;
  FSessionsGrid.DefaultRowHeight := 22;
  FSessionsGrid.Options := FSessionsGrid.Options - [goEditing] + [goVertLine, goHorzLine, goRowSelect];
  FSessionsGrid.ScrollBars := ssAutoVertical;
end;

procedure TStatusFrame.BuildMetricsCard;
begin
  FMetricsCard := TPanel.Create(Self);
  FMetricsCard.Parent     := Self;
  FMetricsCard.Align      := alClient;
  FMetricsCard.BevelOuter := bvNone;
  FMetricsCard.Caption    := '';

  FMetricsLbl := TLabel.Create(FMetricsCard);
  FMetricsLbl.Parent := FMetricsCard;
  FMetricsLbl.Caption := 'DETAILED METRICS';
  FMetricsLbl.Left := 16;
  FMetricsLbl.Top  := 8;
  FMetricsLbl.AutoSize := True;
  FMetricsLbl.Font.Height := -10;
  FMetricsLbl.Font.Style  := [fsBold];
  FMetricsLbl.ParentColor := True;
  FMetricsLbl.ParentFont  := False;
  SetSemantic(FMetricsLbl, skMuted);

  FMetricsGrid := TStringGrid.Create(FMetricsCard);
  FMetricsGrid.Parent       := FMetricsCard;
  FMetricsGrid.Left         := 16;
  FMetricsGrid.Top          := 32;
  FMetricsGrid.Width        := 1080;
  FMetricsGrid.Height       := 240;
  FMetricsGrid.Anchors      := [akLeft, akTop, akRight, akBottom];
  FMetricsGrid.RowCount     := 9;       // 8 metric rows + header
  FMetricsGrid.ColCount     := 2;
  FMetricsGrid.FixedRows    := 1;
  FMetricsGrid.FixedCols    := 0;
  FMetricsGrid.Cells[0, 0]  := 'Metric';
  FMetricsGrid.Cells[1, 0]  := 'Value';
  FMetricsGrid.ColWidths[0] := 280;
  FMetricsGrid.ColWidths[1] := 760;
  FMetricsGrid.DefaultRowHeight := 22;
  FMetricsGrid.Options := FMetricsGrid.Options - [goEditing] + [goVertLine, goHorzLine];
  FMetricsGrid.ScrollBars := ssNone;
  // Pre-populate row labels so the empty state still reads as a form.
  FMetricsGrid.Cells[0, 1] := 'uptime';
  FMetricsGrid.Cells[0, 2] := 'goroutines';
  FMetricsGrid.Cells[0, 3] := 'mem_alloc_mb';
  FMetricsGrid.Cells[0, 4] := 'bus_subscribers';
  FMetricsGrid.Cells[0, 5] := 'ticks_total';
  FMetricsGrid.Cells[0, 6] := 'ticks_per_sec_1s';
  FMetricsGrid.Cells[0, 7] := 'ticks_per_sec_10s';
  FMetricsGrid.Cells[0, 8] := 'ticks_per_sec_60s';
end;

{ ── data binding ──────────────────────────────────────────────────── }

procedure TStatusFrame.SetStatus(const AStatus: TStatusResult);
var
  i: Integer;
  baseRow: Integer;
begin
  // Tiles — primary signal, glance-readable.
  SetTileValue(FTileUptime,      FormatUptime(AStatus.Uptime),      skPrimary);
  SetTileValue(FTileMem,         FormatMem(AStatus.MemAllocMb),     skNeutral);
  SetTileValue(FTileTicksPerSec, FormatThouFloat(AStatus.TicksPerSec60s), skBuy);
  SetTileValue(FTileGoroutines,  FormatThou(AStatus.Goroutines),    skNeutral);
  SetTileValue(FTileTicksTotal,  FormatThou(AStatus.TicksTotal),    skNeutral);
  SetTileValue(FTileBusSubs,     FormatThou(AStatus.BusSubscribers),skNeutral);

  // Sessions read-only summary — same fields the Sessions panel
  // shows but stripped of action buttons.
  if Length(AStatus.Sessions) = 0 then
    FSessionsGrid.RowCount := 2
  else
    FSessionsGrid.RowCount := Length(AStatus.Sessions) + 1;

  if Length(AStatus.Sessions) = 0 then
  begin
    for i := 0 to FSessionsGrid.ColCount - 1 do
      FSessionsGrid.Cells[i, 1] := '';
    FSessionsGrid.Cells[0, 1] := '(no sessions attached)';
  end
  else
    for i := 0 to High(AStatus.Sessions) do
    begin
      FSessionsGrid.Cells[0, i + 1] := string(AStatus.Sessions[i].InstanceId);
      FSessionsGrid.Cells[1, i + 1] := string(AStatus.Sessions[i].Broker);
      FSessionsGrid.Cells[2, i + 1] := RoleLabel(AStatus.Sessions[i]);
      FSessionsGrid.Cells[3, i + 1] := FormatThou(AStatus.Sessions[i].CatalogRows);
      FSessionsGrid.Cells[4, i + 1] := FormatTimeOnly(AStatus.Sessions[i].AttachedAt);
      if AStatus.Sessions[i].AdapterAttached then
        FSessionsGrid.Cells[5, i + 1] := 'attached'
      else
        FSessionsGrid.Cells[5, i + 1] := 'detached';
    end;

  // Detailed metrics grid — every field on TStatusResult, raw values
  // for power users + ML feature export. Order matches the bus
  // contract pinned in Docs/ThoriumdContract.md §3.
  baseRow := 1;
  FMetricsGrid.Cells[1, baseRow + 0] := string(AStatus.Uptime);
  FMetricsGrid.Cells[1, baseRow + 1] := IntToStr(AStatus.Goroutines);
  FMetricsGrid.Cells[1, baseRow + 2] := FormatFloat('0.00', AStatus.MemAllocMb);
  FMetricsGrid.Cells[1, baseRow + 3] := IntToStr(AStatus.BusSubscribers);
  FMetricsGrid.Cells[1, baseRow + 4] := FormatThou(AStatus.TicksTotal);
  FMetricsGrid.Cells[1, baseRow + 5] := FormatFloat('0.0', AStatus.TicksPerSec1s);
  FMetricsGrid.Cells[1, baseRow + 6] := FormatFloat('0.0', AStatus.TicksPerSec10s);
  FMetricsGrid.Cells[1, baseRow + 7] := FormatFloat('0.0', AStatus.TicksPerSec60s);
end;

procedure TStatusFrame.SetStatusText(const AText: string; AKind: Integer);
var k: TSemanticKind;
begin
  case AKind of
    1:  k := skBuy;
    -1: k := skDelete;
  else  k := skMuted;
  end;
  SetSemantic(FStatusLbl, k);
  FStatusLbl.Caption := AText;
end;

function TStatusFrame.AutoRefreshEnabled: Boolean;
begin
  result := FChkAuto.Checked;
end;

procedure TStatusFrame.DoReloadClick(Sender: TObject);
begin
  if Assigned(FOnReload) then FOnReload(Self);
end;

procedure TStatusFrame.DoAutoToggle(Sender: TObject);
begin
  if Assigned(FOnAutoToggle) then FOnAutoToggle(Self);
end;

{ ── small formatters ──────────────────────────────────────────── }

function TStatusFrame.FormatUptime(const ARaw: RawUtf8): string;
begin
  if ARaw = '' then result := '-' else result := string(ARaw);
end;

function TStatusFrame.FormatThou(AValue: Int64): string;
var
  s: string;
  i, gap: Integer;
begin
  s := IntToStr(AValue);
  if AValue < 1000 then exit(s);
  result := '';
  gap := 0;
  for i := Length(s) downto 1 do
  begin
    if gap = 3 then
    begin
      result := ',' + result;
      gap := 0;
    end;
    result := s[i] + result;
    Inc(gap);
  end;
end;

function TStatusFrame.FormatThouFloat(AValue: Double): string;
begin
  if AValue = 0 then exit('0');
  result := FormatFloat('#,##0.0', AValue);
end;

function TStatusFrame.FormatMem(AMb: Double): string;
begin
  if AMb >= 1024 then
    result := FormatFloat('0.00', AMb / 1024) + ' GB'
  else
    result := FormatFloat('0', AMb) + ' MB';
end;

function TStatusFrame.FormatTimeOnly(const ARfc3339: RawUtf8): string;
var s: string; i: Integer;
begin
  s := string(ARfc3339);
  i := Pos('T', s);
  if (i > 0) and (Length(s) >= i + 8) then
    result := Copy(s, i + 1, 8)
  else
    result := s;
end;

function TStatusFrame.RoleLabel(const ASession: TStatusSession): string;
begin
  if ASession.IsFeedBroker then
    result := 'Data + REST'
  else
    result := 'REST only';
end;

end.
