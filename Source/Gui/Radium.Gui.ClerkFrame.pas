unit Radium.Gui.ClerkFrame;

(* ----------------------------------------------------------------------------
  Clerk frame — centre-host content for the "Clerk" sidebar destination.
  Pascal port of `cmd/clerk` (the Go binary is going away — see memory:
  clerk_in_radium.md). Reads /tradebook + /positionbook + /orderbook +
  /symbol via TThoriumClient, runs the analysis in-process, renders.

  Layout:

    +- Clerk: Trade Analyzer ─────────────────────────────────────────+
    |  Date: [ 2026-05-02 ▼ ]  Session: [▼ All sessions]  [Run]      |
    |  status: live run · 14:32 IST                                   |
    |                                                                 |
    |  TOTALS                                                         |
    |   Net realized     Gross PnL    Charges    Open unrealized     |
    |   +₹X              +₹Y          ₹Z         +₹W                 |
    |   Trips: 12 (7W / 4L / 1F) · Win-rate 63.6%                    |
    |                                                                 |
    |  [Tabs: Round-trips · By source · By symbol · Open positions]  |
    |  [grid for active tab]                                          |
    +-----------------------------------------------------------------+

  Date picker drives where the report comes from:
    today      → run analysis live (TThoriumClient + analyzer)
    past       → load from SQLite store (next iteration); today the
                 frame shows a clear "stored reports require the
                 SQLite layer" notice so we never fake history.

  Session dropdown restricts /tradebook + /positionbook to one
  instance_id when set. "All sessions" leaves it blank.

  Frame raises events so MainForm owns I/O — same pattern as
  SessionsFrame / PlansFrame / RiskFrame.
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  Classes,
  SysUtils,
  Math,
  DateUtils,
  Forms,
  Controls,
  Graphics,
  ComCtrls,
  Grids,
  ExtCtrls,
  StdCtrls,
  EditBtn,
  mormot.core.base,
  Radium.Api.Types,
  Radium.Clerk.Types;

type
  // RunRequest — frame asks MainForm to fetch + analyze. The frame
  // doesn't know about TThoriumClient / SQLite / the analyzer.
  TClerkRunRequest = record
    DateIst:    TDateTime;
    InstanceId: RawUtf8;
    IsToday:    Boolean;       // true → live run; false → history (stored)
  end;

  TClerkRunEvent = procedure(Sender: TObject;
    const ARequest: TClerkRunRequest) of object;

  { TClerkFrame }
  TClerkFrame = class(TPanel)
  private
    FTopBar:        TPanel;
      FLblDate:     TLabel;
      FDate:        TDateEdit;
      FLblInstance: TLabel;
      FCmbInstance: TComboBox;
      FBtnRun:      TButton;
      FStatusLbl:   TLabel;

    FTotalsCard:    TPanel;
      FLblNetVal:        TLabel;   FLblNetCap:    TLabel;
      FLblGrossVal:      TLabel;   FLblGrossCap:  TLabel;
      FLblChargesVal:    TLabel;   FLblChargesCap: TLabel;
      FLblUnrealVal:     TLabel;   FLblUnrealCap: TLabel;
      FLblTripsLine:     TLabel;
      FLblWinRateLine:   TLabel;

    FTabs:          TTabControl;
    FBody:          TPanel;
      FTripsGrid:   TStringGrid;
      FSourceGrid:  TStringGrid;
      FSymbolGrid:  TStringGrid;
      FOpenGrid:    TStringGrid;

    FOnRunRequested: TClerkRunEvent;

    FInstanceIds:   array of RawUtf8;

    procedure BuildTopBar;
    procedure BuildTotalsCard;
    procedure BuildTabs;
    procedure BuildGrids;

    procedure DoRunClick(Sender: TObject);
    procedure DoTabChange(Sender: TObject);
    procedure DoDateChange(Sender: TObject);

    procedure ApplyTabVisibility;
    procedure FillTripsGrid(const ATrips: TClerkRoundTripArray);
    procedure FillSourceGrid(const ASource: TClerkSourceStatArray);
    procedure FillSymbolGrid(const ASymbol: TClerkSymbolStatArray);
    procedure FillOpenGrid(const AOpen: TClerkOpenPositionArray);

    function FormatRupee(AValue: Double): string;
    function FormatNetRupee(AValue: Double): string;
    function FormatPctValue(AValue: Double): string;
    function ShortTimeOfRfc(const ARaw: RawUtf8): string;
    function HoldDuration(const AOpened, AClosed: RawUtf8): string;
  public
    constructor Create(AOwner: TComponent); override;

    procedure SetInstanceOptions(const AInstanceIds: array of RawUtf8);
    function  SelectedInstance: RawUtf8;
    function  SelectedDate: TDateTime;
    function  SelectedDateIsToday: Boolean;

    // Render a freshly-computed report (or a no-op clear when ARun
    // is empty). Caller fetches data + runs the analyzer; the frame
    // is purely visual.
    procedure SetReport(const AReport: TClerkReport);

    procedure SetStatusText(const AText: string; AKind: Integer);

    property OnRunRequested: TClerkRunEvent read FOnRunRequested write FOnRunRequested;
  end;

implementation

uses
  Radium.Gui.Theme;

const
  TOPBAR_H        = 80;
  TOTALS_H        = 132;
  TABS_H          = 36;

  TAB_TRIPS  = 0;
  TAB_SOURCE = 1;
  TAB_SYMBOL = 2;
  TAB_OPEN   = 3;

{ TClerkFrame ──────────────────────────────────────────────────────── }

constructor TClerkFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption    := '';

  BuildTopBar;
  BuildTotalsCard;
  BuildTabs;
  BuildGrids;

  ApplyTabVisibility;
end;

procedure TClerkFrame.BuildTopBar;
begin
  FTopBar := TPanel.Create(Self);
  FTopBar.Parent     := Self;
  FTopBar.Align      := alTop;
  FTopBar.Height     := TOPBAR_H;
  FTopBar.BevelOuter := bvNone;
  FTopBar.Caption    := '';

  FLblDate := TLabel.Create(FTopBar);
  FLblDate.Parent  := FTopBar;
  FLblDate.Caption := 'Date';
  FLblDate.Left := 16; FLblDate.Top := 8;
  FLblDate.AutoSize := True;
  FLblDate.Font.Height := -10;
  FLblDate.Font.Style := [fsBold];
  FLblDate.ParentColor := True;
  FLblDate.ParentFont := False;
  SetSemantic(FLblDate, skMuted);

  FDate := TDateEdit.Create(FTopBar);
  FDate.Parent := FTopBar;
  FDate.Left := 16;
  FDate.Top  := 28;
  FDate.Width := 160;
  FDate.Height := 28;
  FDate.Date := SysUtils.Date;     // default today
  FDate.OnChange := DoDateChange;

  FLblInstance := TLabel.Create(FTopBar);
  FLblInstance.Parent  := FTopBar;
  FLblInstance.Caption := 'Session';
  FLblInstance.Left := 200; FLblInstance.Top := 8;
  FLblInstance.AutoSize := True;
  FLblInstance.Font.Height := -10;
  FLblInstance.Font.Style := [fsBold];
  FLblInstance.ParentColor := True;
  FLblInstance.ParentFont := False;
  SetSemantic(FLblInstance, skMuted);

  FCmbInstance := TComboBox.Create(FTopBar);
  FCmbInstance.Parent := FTopBar;
  FCmbInstance.Left := 200;
  FCmbInstance.Top  := 28;
  FCmbInstance.Width := 240;
  FCmbInstance.Height := 28;
  FCmbInstance.Style := csDropDownList;
  FCmbInstance.Items.Add('All sessions');
  FCmbInstance.ItemIndex := 0;

  FBtnRun := TButton.Create(FTopBar);
  FBtnRun.Parent := FTopBar;
  FBtnRun.Left   := 460;
  FBtnRun.Top    := 26;
  FBtnRun.Width  := 130;
  FBtnRun.Height := 32;
  FBtnRun.Caption := 'Run analysis';
  FBtnRun.Default := True;
  FBtnRun.Font.Style := [fsBold];
  FBtnRun.ParentFont := False;
  FBtnRun.OnClick := DoRunClick;
  SetSemantic(FBtnRun, skPrimary);

  FStatusLbl := TLabel.Create(FTopBar);
  FStatusLbl.Parent := FTopBar;
  FStatusLbl.Left := 16;
  FStatusLbl.Top  := 60;
  FStatusLbl.AutoSize := False;
  FStatusLbl.Width := 1100;
  FStatusLbl.Height := 16;
  FStatusLbl.Caption := 'Pick a date and click "Run analysis". Today runs live; ' +
                       'past dates require the SQLite store (next iteration).';
  FStatusLbl.Font.Height := -11;
  FStatusLbl.ParentColor := True;
  FStatusLbl.ParentFont := False;
  SetSemantic(FStatusLbl, skMuted);
end;

procedure TClerkFrame.BuildTotalsCard;
  function MakeCap(AParent: TWinControl;
    const ACap: string; ALeft, ATop: Integer): TLabel;
  begin
    result := TLabel.Create(AParent);
    result.Parent := AParent;
    result.Caption := UpperCase(ACap);
    result.Left := ALeft; result.Top := ATop;
    result.AutoSize := True;
    result.Font.Height := -10;
    result.Font.Style := [fsBold];
    result.ParentColor := True;
    result.ParentFont := False;
    SetSemantic(result, skMuted);
  end;
  function MakeBig(AParent: TWinControl;
    ALeft, ATop: Integer): TLabel;
  begin
    result := TLabel.Create(AParent);
    result.Parent := AParent;
    result.Caption := '-';
    result.Left := ALeft; result.Top := ATop;
    result.AutoSize := True;
    result.Font.Height := -22;
    result.Font.Style := [fsBold];
    result.ParentColor := True;
    result.ParentFont := False;
    SetSemantic(result, skNeutral);
  end;
begin
  FTotalsCard := TPanel.Create(Self);
  FTotalsCard.Parent     := Self;
  FTotalsCard.Align      := alTop;
  FTotalsCard.Height     := TOTALS_H;
  FTotalsCard.BevelOuter := bvNone;
  FTotalsCard.Caption    := '';

  FLblNetCap     := MakeCap(FTotalsCard, 'Net realized',     16,  12);
  FLblNetVal     := MakeBig(FTotalsCard,                     16,  30);

  FLblGrossCap   := MakeCap(FTotalsCard, 'Gross PnL',        260, 12);
  FLblGrossVal   := MakeBig(FTotalsCard,                     260, 30);

  FLblChargesCap := MakeCap(FTotalsCard, 'Charges',          480, 12);
  FLblChargesVal := MakeBig(FTotalsCard,                     480, 30);

  FLblUnrealCap  := MakeCap(FTotalsCard, 'Open unrealized',  700, 12);
  FLblUnrealVal  := MakeBig(FTotalsCard,                     700, 30);

  FLblTripsLine := TLabel.Create(FTotalsCard);
  FLblTripsLine.Parent  := FTotalsCard;
  FLblTripsLine.Caption := 'Trips: -';
  FLblTripsLine.Left    := 16;
  FLblTripsLine.Top     := 80;
  FLblTripsLine.AutoSize := True;
  FLblTripsLine.Font.Height := -13;
  FLblTripsLine.ParentColor := True;
  FLblTripsLine.ParentFont := False;
  SetSemantic(FLblTripsLine, skNeutral);

  FLblWinRateLine := TLabel.Create(FTotalsCard);
  FLblWinRateLine.Parent  := FTotalsCard;
  FLblWinRateLine.Caption := 'Win-rate: -';
  FLblWinRateLine.Left    := 16;
  FLblWinRateLine.Top     := 102;
  FLblWinRateLine.AutoSize := True;
  FLblWinRateLine.Font.Height := -13;
  FLblWinRateLine.ParentColor := True;
  FLblWinRateLine.ParentFont := False;
  SetSemantic(FLblWinRateLine, skMuted);
end;

procedure TClerkFrame.BuildTabs;
begin
  FTabs := TTabControl.Create(Self);
  FTabs.Parent := Self;
  FTabs.Align  := alTop;
  FTabs.Height := TABS_H;
  FTabs.Tabs.Add('Round-trips');
  FTabs.Tabs.Add('By source');
  FTabs.Tabs.Add('By symbol');
  FTabs.Tabs.Add('Open positions');
  FTabs.TabIndex := 0;
  FTabs.OnChange := DoTabChange;

  FBody := TPanel.Create(Self);
  FBody.Parent     := Self;
  FBody.Align      := alClient;
  FBody.BevelOuter := bvNone;
  FBody.Caption    := '';
end;

procedure TClerkFrame.BuildGrids;
  function MakeGrid(AParent: TWinControl): TStringGrid;
  begin
    result := TStringGrid.Create(AParent);
    result.Parent := AParent;
    result.Align  := alClient;
    result.FixedRows := 1;
    result.FixedCols := 0;
    result.RowCount  := 1;
    result.DefaultRowHeight := 22;
    result.Options := result.Options - [goEditing] + [goVertLine, goHorzLine, goRowSelect];
    result.ScrollBars := ssAutoBoth;
    result.Visible := False;
  end;
begin
  FTripsGrid := MakeGrid(FBody);
  FTripsGrid.ColCount := 10;
  FTripsGrid.Cells[0, 0] := 'Src';
  FTripsGrid.Cells[1, 0] := 'Verdict';
  FTripsGrid.Cells[2, 0] := 'Symbol';
  FTripsGrid.Cells[3, 0] := 'Ex';
  FTripsGrid.Cells[4, 0] := 'Type';
  FTripsGrid.Cells[5, 0] := 'Qty';
  FTripsGrid.Cells[6, 0] := 'Opened';
  FTripsGrid.Cells[7, 0] := 'Closed';
  FTripsGrid.Cells[8, 0] := 'Hold';
  FTripsGrid.Cells[9, 0] := 'Net ₹';
  FTripsGrid.ColWidths[0] := 50;
  FTripsGrid.ColWidths[1] := 70;
  FTripsGrid.ColWidths[2] := 220;
  FTripsGrid.ColWidths[3] := 50;
  FTripsGrid.ColWidths[4] := 50;
  FTripsGrid.ColWidths[5] := 100;
  FTripsGrid.ColWidths[6] := 80;
  FTripsGrid.ColWidths[7] := 80;
  FTripsGrid.ColWidths[8] := 70;
  FTripsGrid.ColWidths[9] := 110;

  FSourceGrid := MakeGrid(FBody);
  FSourceGrid.ColCount := 5;
  FSourceGrid.Cells[0, 0] := 'Source';
  FSourceGrid.Cells[1, 0] := 'Trips';
  FSourceGrid.Cells[2, 0] := 'Wins';
  FSourceGrid.Cells[3, 0] := 'Realized ₹';
  FSourceGrid.Cells[4, 0] := 'Charges ₹';
  FSourceGrid.ColWidths[0] := 100;
  FSourceGrid.ColWidths[1] := 80;
  FSourceGrid.ColWidths[2] := 100;
  FSourceGrid.ColWidths[3] := 160;
  FSourceGrid.ColWidths[4] := 160;

  FSymbolGrid := MakeGrid(FBody);
  FSymbolGrid.ColCount := 8;
  FSymbolGrid.Cells[0, 0] := 'Symbol';
  FSymbolGrid.Cells[1, 0] := 'Type';
  FSymbolGrid.Cells[2, 0] := 'Trips';
  FSymbolGrid.Cells[3, 0] := 'Wins';
  FSymbolGrid.Cells[4, 0] := 'Realized ₹';
  FSymbolGrid.Cells[5, 0] := 'Charges ₹';
  FSymbolGrid.Cells[6, 0] := 'Open qty';
  FSymbolGrid.Cells[7, 0] := 'Unrealized ₹';
  FSymbolGrid.ColWidths[0] := 140;
  FSymbolGrid.ColWidths[1] := 60;
  FSymbolGrid.ColWidths[2] := 70;
  FSymbolGrid.ColWidths[3] := 70;
  FSymbolGrid.ColWidths[4] := 140;
  FSymbolGrid.ColWidths[5] := 130;
  FSymbolGrid.ColWidths[6] := 90;
  FSymbolGrid.ColWidths[7] := 140;

  FOpenGrid := MakeGrid(FBody);
  FOpenGrid.ColCount := 7;
  FOpenGrid.Cells[0, 0] := 'Symbol';
  FOpenGrid.Cells[1, 0] := 'Ex';
  FOpenGrid.Cells[2, 0] := 'Type';
  FOpenGrid.Cells[3, 0] := 'Qty';
  FOpenGrid.Cells[4, 0] := 'Avg';
  FOpenGrid.Cells[5, 0] := 'LTP';
  FOpenGrid.Cells[6, 0] := 'Unrealized ₹';
  FOpenGrid.ColWidths[0] := 220;
  FOpenGrid.ColWidths[1] := 60;
  FOpenGrid.ColWidths[2] := 60;
  FOpenGrid.ColWidths[3] := 90;
  FOpenGrid.ColWidths[4] := 100;
  FOpenGrid.ColWidths[5] := 100;
  FOpenGrid.ColWidths[6] := 160;
end;

procedure TClerkFrame.SetInstanceOptions(const AInstanceIds: array of RawUtf8);
var i: Integer;
begin
  SetLength(FInstanceIds, Length(AInstanceIds));
  for i := 0 to High(AInstanceIds) do
    FInstanceIds[i] := AInstanceIds[i];

  FCmbInstance.Items.BeginUpdate;
  try
    FCmbInstance.Items.Clear;
    FCmbInstance.Items.Add('All sessions');
    for i := 0 to High(AInstanceIds) do
      FCmbInstance.Items.Add(string(AInstanceIds[i]));
  finally
    FCmbInstance.Items.EndUpdate;
  end;
  if FCmbInstance.ItemIndex < 0 then
    FCmbInstance.ItemIndex := 0;
end;

function TClerkFrame.SelectedInstance: RawUtf8;
begin
  if (FCmbInstance.ItemIndex <= 0) or
     (FCmbInstance.ItemIndex - 1 > High(FInstanceIds)) then
    result := ''
  else
    result := FInstanceIds[FCmbInstance.ItemIndex - 1];
end;

function TClerkFrame.SelectedDate: TDateTime;
begin
  result := FDate.Date;
end;

function TClerkFrame.SelectedDateIsToday: Boolean;
begin
  result := DateOf(FDate.Date) = DateOf(SysUtils.Date);
end;

procedure TClerkFrame.SetStatusText(const AText: string; AKind: Integer);
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

procedure TClerkFrame.SetReport(const AReport: TClerkReport);
var
  scored: Integer;
  winRate: Double;
begin
  FLblNetVal.Caption     := FormatNetRupee(AReport.Realized);
  FLblGrossVal.Caption   := FormatNetRupee(AReport.GrossPnL);
  FLblChargesVal.Caption := FormatRupee(AReport.ChargesTotal);
  FLblUnrealVal.Caption  := FormatNetRupee(AReport.Unrealized);

  // Colour the net + unrealized values by sign — green positive, red
  // negative — so the operator's eye lands on the answer first.
  if AReport.Realized > 0 then SetSemantic(FLblNetVal, skBuy)
  else if AReport.Realized < 0 then SetSemantic(FLblNetVal, skDelete)
  else SetSemantic(FLblNetVal, skNeutral);

  if AReport.Unrealized > 0 then SetSemantic(FLblUnrealVal, skBuy)
  else if AReport.Unrealized < 0 then SetSemantic(FLblUnrealVal, skDelete)
  else SetSemantic(FLblUnrealVal, skNeutral);

  FLblTripsLine.Caption := Format(
    'Trips: %d  (%d win / %d loss / %d flat)',
    [Length(AReport.Trips), AReport.Wins, AReport.Losses, AReport.Flats]);
  scored := AReport.Wins + AReport.Losses;
  if scored > 0 then
    winRate := AReport.Wins / scored * 100
  else
    winRate := 0;
  FLblWinRateLine.Caption := Format(
    'Win-rate: %.1f%%  ·  Open positions: %d',
    [winRate, Length(AReport.Open)]);

  FillTripsGrid(AReport.Trips);
  FillSourceGrid(AReport.PerSource);
  FillSymbolGrid(AReport.PerSymbol);
  FillOpenGrid(AReport.Open);

  Radium.Gui.Theme.Apply(Self);
end;

procedure TClerkFrame.FillTripsGrid(const ATrips: TClerkRoundTripArray);
var
  i: Integer;
  qty: Integer;
begin
  FTripsGrid.RowCount := Math.Max(2, Length(ATrips) + 1);
  if Length(ATrips) = 0 then
  begin
    for i := 0 to FTripsGrid.ColCount - 1 do
      FTripsGrid.Cells[i, 1] := '';
    FTripsGrid.Cells[2, 1] := '(no closed round-trips)';
    exit;
  end;
  for i := 0 to High(ATrips) do
  begin
    qty := ATrips[i].BuyQty;
    if ATrips[i].SellQty < qty then qty := ATrips[i].SellQty;

    FTripsGrid.Cells[0, i + 1] := string(ATrips[i].SourceTag);
    if ATrips[i].NetPnL > 0.5 then
      FTripsGrid.Cells[1, i + 1] := 'WIN'
    else if ATrips[i].NetPnL < -0.5 then
      FTripsGrid.Cells[1, i + 1] := 'LOSS'
    else
      FTripsGrid.Cells[1, i + 1] := 'FLAT';
    FTripsGrid.Cells[2, i + 1] := string(ATrips[i].Symbol);
    FTripsGrid.Cells[3, i + 1] := string(ATrips[i].Exchange);
    FTripsGrid.Cells[4, i + 1] := string(ATrips[i].InstType);
    if (ATrips[i].LotSize > 1) and
       ((ATrips[i].InstType = 'OPT') or (ATrips[i].InstType = 'FUT')) then
      FTripsGrid.Cells[5, i + 1] := Format('%d (%d lots)',
        [qty, qty div ATrips[i].LotSize])
    else
      FTripsGrid.Cells[5, i + 1] := IntToStr(qty);
    FTripsGrid.Cells[6, i + 1] := ShortTimeOfRfc(ATrips[i].OpenedAt);
    FTripsGrid.Cells[7, i + 1] := ShortTimeOfRfc(ATrips[i].ClosedAt);
    FTripsGrid.Cells[8, i + 1] := HoldDuration(ATrips[i].OpenedAt, ATrips[i].ClosedAt);
    FTripsGrid.Cells[9, i + 1] := FormatNetRupee(ATrips[i].NetPnL);
  end;
end;

procedure TClerkFrame.FillSourceGrid(const ASource: TClerkSourceStatArray);
var i: Integer;
begin
  FSourceGrid.RowCount := Math.Max(2, Length(ASource) + 1);
  if Length(ASource) = 0 then
  begin
    for i := 0 to FSourceGrid.ColCount - 1 do
      FSourceGrid.Cells[i, 1] := '';
    FSourceGrid.Cells[0, 1] := '(no rows)';
    exit;
  end;
  for i := 0 to High(ASource) do
  begin
    FSourceGrid.Cells[0, i + 1] := string(ASource[i].Source);
    FSourceGrid.Cells[1, i + 1] := IntToStr(ASource[i].Trips);
    FSourceGrid.Cells[2, i + 1] := IntToStr(ASource[i].Wins);
    FSourceGrid.Cells[3, i + 1] := FormatNetRupee(ASource[i].Realized);
    FSourceGrid.Cells[4, i + 1] := FormatRupee(ASource[i].Charges);
  end;
end;

procedure TClerkFrame.FillSymbolGrid(const ASymbol: TClerkSymbolStatArray);
var i: Integer;
begin
  FSymbolGrid.RowCount := Math.Max(2, Length(ASymbol) + 1);
  if Length(ASymbol) = 0 then
  begin
    for i := 0 to FSymbolGrid.ColCount - 1 do
      FSymbolGrid.Cells[i, 1] := '';
    FSymbolGrid.Cells[0, 1] := '(no rows)';
    exit;
  end;
  for i := 0 to High(ASymbol) do
  begin
    FSymbolGrid.Cells[0, i + 1] := string(ASymbol[i].Symbol);
    FSymbolGrid.Cells[1, i + 1] := string(ASymbol[i].InstType);
    FSymbolGrid.Cells[2, i + 1] := IntToStr(ASymbol[i].Trips);
    FSymbolGrid.Cells[3, i + 1] := IntToStr(ASymbol[i].Wins);
    FSymbolGrid.Cells[4, i + 1] := FormatNetRupee(ASymbol[i].Realized);
    FSymbolGrid.Cells[5, i + 1] := FormatRupee(ASymbol[i].Charges);
    FSymbolGrid.Cells[6, i + 1] := IntToStr(ASymbol[i].OpenQty);
    FSymbolGrid.Cells[7, i + 1] := FormatNetRupee(ASymbol[i].Unrealized);
  end;
end;

procedure TClerkFrame.FillOpenGrid(const AOpen: TClerkOpenPositionArray);
var i: Integer;
begin
  FOpenGrid.RowCount := Math.Max(2, Length(AOpen) + 1);
  if Length(AOpen) = 0 then
  begin
    for i := 0 to FOpenGrid.ColCount - 1 do
      FOpenGrid.Cells[i, 1] := '';
    FOpenGrid.Cells[0, 1] := '(no open positions)';
    exit;
  end;
  for i := 0 to High(AOpen) do
  begin
    FOpenGrid.Cells[0, i + 1] := string(AOpen[i].Symbol);
    FOpenGrid.Cells[1, i + 1] := string(AOpen[i].Exchange);
    FOpenGrid.Cells[2, i + 1] := string(AOpen[i].InstType);
    FOpenGrid.Cells[3, i + 1] := IntToStr(AOpen[i].Qty);
    FOpenGrid.Cells[4, i + 1] := FormatRupee(AOpen[i].AvgPrice);
    FOpenGrid.Cells[5, i + 1] := FormatRupee(AOpen[i].Ltp);
    FOpenGrid.Cells[6, i + 1] := FormatNetRupee(AOpen[i].Unrealized);
  end;
end;

procedure TClerkFrame.ApplyTabVisibility;
begin
  FTripsGrid.Visible  := FTabs.TabIndex = TAB_TRIPS;
  FSourceGrid.Visible := FTabs.TabIndex = TAB_SOURCE;
  FSymbolGrid.Visible := FTabs.TabIndex = TAB_SYMBOL;
  FOpenGrid.Visible   := FTabs.TabIndex = TAB_OPEN;
end;

procedure TClerkFrame.DoTabChange(Sender: TObject);
begin
  ApplyTabVisibility;
end;

procedure TClerkFrame.DoDateChange(Sender: TObject);
begin
  if SelectedDateIsToday then
    FBtnRun.Caption := 'Run analysis'
  else
    FBtnRun.Caption := 'Load report';
end;

procedure TClerkFrame.DoRunClick(Sender: TObject);
var
  req: TClerkRunRequest;
begin
  if not Assigned(FOnRunRequested) then exit;
  req.DateIst    := DateOf(FDate.Date);
  req.InstanceId := SelectedInstance;
  req.IsToday    := SelectedDateIsToday;
  FOnRunRequested(Self, req);
end;

{ ── small formatters ──────────────────────────────────────────── }

function TClerkFrame.FormatRupee(AValue: Double): string;
begin
  if AValue = 0 then exit('-');
  result := '₹' + FormatFloat('#,##0.00', AValue);
end;

function TClerkFrame.FormatNetRupee(AValue: Double): string;
begin
  if AValue = 0 then exit('₹0');
  if AValue > 0 then
    result := '+₹' + FormatFloat('#,##0.00', AValue)
  else
    result := '-₹' + FormatFloat('#,##0.00', -AValue);
end;

function TClerkFrame.FormatPctValue(AValue: Double): string;
begin
  result := FormatFloat('0.0', AValue) + '%';
end;

function TClerkFrame.ShortTimeOfRfc(const ARaw: RawUtf8): string;
var s: string; i: Integer;
begin
  s := string(ARaw);
  i := Pos('T', s);
  if (i > 0) and (Length(s) >= i + 5) then
    result := Copy(s, i + 1, 5)
  else
    result := s;
end;

function TClerkFrame.HoldDuration(const AOpened, AClosed: RawUtf8): string;
  function ToTime(const ARaw: RawUtf8): TDateTime;
  var s: string; i: Integer; hh, mm, ss, code: Integer;
  begin
    result := 0;
    s := string(ARaw);
    i := Pos('T', s);
    if i = 0 then exit;
    if Length(s) < i + 8 then exit;
    Val(Copy(s, i + 1, 2), hh, code); if code <> 0 then exit;
    Val(Copy(s, i + 4, 2), mm, code); if code <> 0 then exit;
    Val(Copy(s, i + 7, 2), ss, code); if code <> 0 then exit;
    result := EncodeTime(hh, mm, ss, 0);
  end;
var
  d: TDateTime;
  secs: Integer;
begin
  d := ToTime(AClosed) - ToTime(AOpened);
  if d <= 0 then exit('-');
  secs := Round(d * 86400);
  if secs < 60 then
    result := IntToStr(secs) + 's'
  else if secs < 3600 then
    result := Format('%dm%02ds', [secs div 60, secs mod 60])
  else
    result := Format('%dh%02dm', [secs div 3600, (secs mod 3600) div 60]);
end;

end.
