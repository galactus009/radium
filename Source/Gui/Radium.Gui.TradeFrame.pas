unit Radium.Gui.TradeFrame;

{$mode Delphi}{$H+}

// TTradeFrame — the Trade panel: order pad on the left, positions
// grid + tradebook tabs on the right.
//
// Order pad
// ─────────
// Symbol search (autocomplete via OnSymbolSearch host callback) →
// action (BUY/SELL) → product → pricetype → qty/lots → price →
// trigger. Lots-vs-Qty label flips automatically based on the
// resolved instrument's segment.
//
// Validation surface
// ──────────────────
// Every input change re-runs the validator (Radium.Trading.Validator)
// against the cached TRiskConfig + ambient state the host pushes via
// SetAmbient. Findings render live in the panel below the form;
// the Place button locks if any vsBlock finding is present.
//
// Order submission
// ─────────────────
// Place button fires OnPlaceRequested(planned). Host runs the
// confirm dialog + submits the wire call.
//
// Right pane
// ──────────
// TPageControl with three tabs: Positions / Tradebook / Orderbook.
// Each grid is fed by SetPositions / SetTradebook / SetOrderbook
// from the host's refresh cycle. Position rows expose Add / Exit
// click events.

interface

uses
  Classes, SysUtils,
  Controls, ExtCtrls, ComCtrls, StdCtrls, Buttons, Grids,
  Graphics, LCLType,
  mormot.core.base,
  Radium.Api.Types,
  Radium.Trading.Types,
  Radium.Gui.SymbolSearch;

type
  TPlaceRequestEvent = procedure(Sender: TObject;
    const APlanned: TPlannedOrder) of object;

  TPositionActionEvent = procedure(Sender: TObject;
    const ARow: TPositionRow) of object;

  TRefreshEvent = TNotifyEvent;

  { TTradeFrame }
  TTradeFrame = class(TPanel)
  private
    // ── left: order pad ────────────────────────────────────────
    FPadHost:        TPanel;
      FSymbolSearch: TSymbolSearchEdit;
      FActionRow:    TPanel;
        FBtnBuy:     TButton;
        FBtnSell:    TButton;
      FProductRow:   TPanel;
        FLblProduct: TLabel;
        FCmbProduct: TComboBox;
      FPriceTypeRow: TPanel;
        FLblPType:   TLabel;
        FCmbPType:   TComboBox;
      FQtyRow:       TPanel;
        FLblQty:     TLabel;
        FEdtQty:     TEdit;
        FLblQtyHint: TLabel;     // "= 75 contracts" when lots-mode
      FPriceRow:     TPanel;
        FLblPrice:   TLabel;
        FEdtPrice:   TEdit;
      FTriggerRow:   TPanel;
        FLblTrigger: TLabel;
        FEdtTrigger: TEdit;
      FFindings:     TMemo;
      FPlaceBar:     TPanel;
        FBtnPlace:   TButton;

    // ── right: positions + tabs ───────────────────────────────
    FRightHost:     TPanel;
      FRefreshBar:  TPanel;
        FBtnRefresh: TButton;
        FLblUpdated: TLabel;
      FTabs:        TPageControl;
        FTabPos:    TTabSheet;
          FGridPos: TStringGrid;
          FBtnAddSel: TButton;
          FBtnExitSel: TButton;
        FTabTrades: TTabSheet;
          FGridTrades: TStringGrid;
        FTabOrders: TTabSheet;
          FGridOrders: TStringGrid;

    // ── state ──────────────────────────────────────────────────
    FCurrentInstance: RawUtf8;
    FResolvedInst:    TInstrument;
    FHasResolved:     Boolean;
    FAction:          TOrderAction;
    FRisk:            TRiskConfig;
    FAmbient:         TAmbientTrading;
    FPositions:       TPositionRowArray;

    // ── events ─────────────────────────────────────────────────
    FOnSearch:    TSymbolSearchRequestEvent;
    FOnPlace:     TPlaceRequestEvent;
    FOnAdd:       TPositionActionEvent;
    FOnExit:      TPositionActionEvent;
    FOnRefresh:   TRefreshEvent;

    // ── building ───────────────────────────────────────────────
    procedure BuildPad;
    procedure BuildRight;

    // ── reactions ──────────────────────────────────────────────
    procedure DoSymbolSelected(Sender: TObject;
      const AInst: TInstrument);
    procedure DoBuyClick(Sender: TObject);
    procedure DoSellClick(Sender: TObject);
    procedure DoPriceTypeChange(Sender: TObject);
    procedure DoQtyChange(Sender: TObject);
    procedure DoPriceChange(Sender: TObject);
    procedure DoTriggerChange(Sender: TObject);
    procedure DoPlaceClick(Sender: TObject);
    procedure DoRefreshClick(Sender: TObject);
    procedure DoAddSelClick(Sender: TObject);
    procedure DoExitSelClick(Sender: TObject);

    procedure ApplyActionStyling;
    procedure ApplyVisibilityForPriceType;
    procedure ApplyQtyLabelForSegment;
    function  BuildPlanned: TPlannedOrder;
    procedure RevalidateNow;
    procedure RenderFindings(const AResult: TValidationResult);
    procedure RenderPositionsGrid;

  public
    constructor Create(AOwner: TComponent); override;

    procedure SetInstance(const AInstanceId: RawUtf8);
    procedure SetRiskConfig(const ARisk: TRiskConfig);
    procedure SetAmbient(const AAmbient: TAmbientTrading);
    procedure SetPositions(const AArr: TPositionRowArray);
    procedure SetTradebookText(const ALines: array of string);
    procedure SetOrderbookText(const ALines: array of string);
    procedure SetUpdatedHint(const AText: string);

    // PrefillFromPosition — Add-on-row → order pad pre-fills with the
    // same direction (long → BUY, short → SELL kept as a warning).
    procedure PrefillFromPosition(const ARow: TPositionRow);

    property OnSymbolSearch:   TSymbolSearchRequestEvent
      read FOnSearch  write FOnSearch;
    property OnPlaceRequested: TPlaceRequestEvent
      read FOnPlace   write FOnPlace;
    property OnAddRequested:   TPositionActionEvent
      read FOnAdd     write FOnAdd;
    property OnExitRequested:  TPositionActionEvent
      read FOnExit    write FOnExit;
    property OnRefreshClicked: TRefreshEvent
      read FOnRefresh write FOnRefresh;
  end;

implementation

uses
  Radium.Gui.Theme,
  Radium.Trading.Validator,
  DateUtils;

const
  PAD_WIDTH       = 380;
  ROW_H           = 36;
  ROW_GAP         = 6;
  LBL_W           = 100;

{ TTradeFrame ────────────────────────────────────────────────────── }

constructor TTradeFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption := '';

  BuildPad;
  BuildRight;

  // Defaults: BUY action, MARKET pricetype, MIS product. Mirrors the
  // most common scalper workflow on Indian intraday equity.
  FAction := oaBuy;
  FCmbProduct.ItemIndex := 0; // MIS
  FCmbPType.ItemIndex   := 0; // MARKET
  ApplyActionStyling;
  ApplyVisibilityForPriceType;
end;

procedure TTradeFrame.BuildPad;

  function MakeRow(AParent: TWinControl; ATop: Integer): TPanel;
  begin
    result := TPanel.Create(Self);
    result.Parent := AParent;
    result.Left   := 0;
    result.Top    := ATop;
    result.Width  := PAD_WIDTH;
    result.Height := ROW_H;
    result.BevelOuter := bvNone;
    result.Caption := '';
  end;

  function MakeLabel(AParent: TWinControl; const AText: string): TLabel;
  begin
    result := TLabel.Create(Self);
    result.Parent  := AParent;
    result.Left    := 8;
    result.Top     := 10;
    result.Width   := LBL_W;
    result.Caption := AText;
    result.AutoSize := False;
    SetSemantic(result, skMuted);
  end;

var
  topY: Integer;
begin
  FPadHost := TPanel.Create(Self);
  FPadHost.Parent := Self;
  FPadHost.Align  := alLeft;
  FPadHost.Width  := PAD_WIDTH;
  FPadHost.BevelOuter := bvNone;
  FPadHost.Caption := '';

  // Symbol search at the top — variable height (collapsed = 32 vs
  // expanded = 232 with dropdown). It anchors alTop and the pad
  // below adjusts dynamically via TPanel autosize? No — we keep
  // a fixed 232px slot so layout doesn't reflow on every keystroke.
  FSymbolSearch := TSymbolSearchEdit.Create(Self);
  FSymbolSearch.Parent := FPadHost;
  FSymbolSearch.Left   := 8;
  FSymbolSearch.Top    := 8;
  FSymbolSearch.Width  := PAD_WIDTH - 16;
  FSymbolSearch.OnSelected := DoSymbolSelected;

  topY := 8 + 240;  // search box + dropdown area + gap

  // Action row: BUY / SELL toggle.
  FActionRow := MakeRow(FPadHost, topY);
  FBtnBuy := TButton.Create(Self);
  FBtnBuy.Parent  := FActionRow;
  FBtnBuy.Left    := 8;
  FBtnBuy.Top     := 0;
  FBtnBuy.Width   := (PAD_WIDTH - 32) div 2;
  FBtnBuy.Height  := ROW_H;
  FBtnBuy.Caption := 'BUY';
  FBtnBuy.OnClick := DoBuyClick;
  SetSemantic(FBtnBuy, skBuy);

  FBtnSell := TButton.Create(Self);
  FBtnSell.Parent  := FActionRow;
  FBtnSell.Left    := FBtnBuy.Left + FBtnBuy.Width + 8;
  FBtnSell.Top     := 0;
  FBtnSell.Width   := FBtnBuy.Width;
  FBtnSell.Height  := ROW_H;
  FBtnSell.Caption := 'SELL';
  FBtnSell.OnClick := DoSellClick;
  SetSemantic(FBtnSell, skSell);

  Inc(topY, ROW_H + ROW_GAP);

  // Product row.
  FProductRow := MakeRow(FPadHost, topY);
  FLblProduct := MakeLabel(FProductRow, 'Product');
  FCmbProduct := TComboBox.Create(Self);
  FCmbProduct.Parent := FProductRow;
  FCmbProduct.Left   := LBL_W + 16;
  FCmbProduct.Top    := 4;
  FCmbProduct.Width  := PAD_WIDTH - LBL_W - 32;
  FCmbProduct.Height := 28;
  FCmbProduct.Style  := csDropDownList;
  FCmbProduct.Items.Add('MIS  (intraday)');
  FCmbProduct.Items.Add('NRML (carry)');
  FCmbProduct.Items.Add('CNC  (delivery)');
  FCmbProduct.Items.Add('CO   (cover)');
  FCmbProduct.Items.Add('BO   (bracket)');
  FCmbProduct.OnChange := DoQtyChange; // any edit re-validates
  Inc(topY, ROW_H + ROW_GAP);

  // PriceType row.
  FPriceTypeRow := MakeRow(FPadHost, topY);
  FLblPType := MakeLabel(FPriceTypeRow, 'Order type');
  FCmbPType := TComboBox.Create(Self);
  FCmbPType.Parent := FPriceTypeRow;
  FCmbPType.Left   := LBL_W + 16;
  FCmbPType.Top    := 4;
  FCmbPType.Width  := PAD_WIDTH - LBL_W - 32;
  FCmbPType.Height := 28;
  FCmbPType.Style  := csDropDownList;
  FCmbPType.Items.Add('MARKET');
  FCmbPType.Items.Add('LIMIT');
  FCmbPType.Items.Add('SL  (stop-loss limit)');
  FCmbPType.Items.Add('SL-M (stop-loss market)');
  FCmbPType.OnChange := DoPriceTypeChange;
  Inc(topY, ROW_H + ROW_GAP);

  // Qty row — label flips between Quantity/Lots based on segment.
  FQtyRow := MakeRow(FPadHost, topY);
  FLblQty := MakeLabel(FQtyRow, 'Quantity');
  FEdtQty := TEdit.Create(Self);
  FEdtQty.Parent := FQtyRow;
  FEdtQty.Left   := LBL_W + 16;
  FEdtQty.Top    := 4;
  FEdtQty.Width  := 100;
  FEdtQty.Height := 28;
  FEdtQty.Text   := '0';
  FEdtQty.OnChange := DoQtyChange;
  FLblQtyHint := TLabel.Create(Self);
  FLblQtyHint.Parent := FQtyRow;
  FLblQtyHint.Left := LBL_W + 16 + 110;
  FLblQtyHint.Top  := 10;
  FLblQtyHint.Caption := '';
  SetSemantic(FLblQtyHint, skMuted);
  Inc(topY, ROW_H + ROW_GAP);

  // Price row.
  FPriceRow := MakeRow(FPadHost, topY);
  FLblPrice := MakeLabel(FPriceRow, 'Price');
  FEdtPrice := TEdit.Create(Self);
  FEdtPrice.Parent := FPriceRow;
  FEdtPrice.Left   := LBL_W + 16;
  FEdtPrice.Top    := 4;
  FEdtPrice.Width  := 120;
  FEdtPrice.Height := 28;
  FEdtPrice.Text   := '0';
  FEdtPrice.OnChange := DoPriceChange;
  Inc(topY, ROW_H + ROW_GAP);

  // Trigger row.
  FTriggerRow := MakeRow(FPadHost, topY);
  FLblTrigger := MakeLabel(FTriggerRow, 'Trigger');
  FEdtTrigger := TEdit.Create(Self);
  FEdtTrigger.Parent := FTriggerRow;
  FEdtTrigger.Left   := LBL_W + 16;
  FEdtTrigger.Top    := 4;
  FEdtTrigger.Width  := 120;
  FEdtTrigger.Height := 28;
  FEdtTrigger.Text   := '0';
  FEdtTrigger.OnChange := DoTriggerChange;
  Inc(topY, ROW_H + ROW_GAP);

  // Findings memo — readonly multi-line.
  FFindings := TMemo.Create(Self);
  FFindings.Parent := FPadHost;
  FFindings.Left   := 8;
  FFindings.Top    := topY + 8;
  FFindings.Width  := PAD_WIDTH - 16;
  FFindings.Height := 180;
  FFindings.ReadOnly := True;
  FFindings.WordWrap := True;
  FFindings.ScrollBars := ssVertical;
  FFindings.Anchors := [akLeft, akTop, akRight, akBottom];
  FFindings.Font.Height := -11;

  // Place button at the bottom of the pad.
  FPlaceBar := TPanel.Create(Self);
  FPlaceBar.Parent := FPadHost;
  FPlaceBar.Align  := alBottom;
  FPlaceBar.Height := 56;
  FPlaceBar.BevelOuter := bvNone;
  FPlaceBar.Caption := '';

  FBtnPlace := TButton.Create(Self);
  FBtnPlace.Parent  := FPlaceBar;
  FBtnPlace.Left    := 8;
  FBtnPlace.Top     := 8;
  FBtnPlace.Width   := PAD_WIDTH - 16;
  FBtnPlace.Height  := 40;
  FBtnPlace.Caption := 'Place order';
  FBtnPlace.Default := False;
  FBtnPlace.Enabled := False;
  FBtnPlace.OnClick := DoPlaceClick;
  SetSemantic(FBtnPlace, skPrimary);
end;

procedure TTradeFrame.BuildRight;

  procedure SetGridDefaults(AGrid: TStringGrid; AColCount: Integer);
  begin
    AGrid.Align    := alClient;
    AGrid.RowCount := 2;
    AGrid.ColCount := AColCount;
    AGrid.FixedRows := 1;
    AGrid.FixedCols := 0;
    AGrid.Options := AGrid.Options - [goEditing] + [goVertLine, goHorzLine,
                                                    goRowSelect];
    AGrid.DefaultRowHeight := 22;
  end;

begin
  FRightHost := TPanel.Create(Self);
  FRightHost.Parent := Self;
  FRightHost.Align  := alClient;
  FRightHost.BevelOuter := bvNone;
  FRightHost.Caption := '';

  // Refresh bar at top of the right pane.
  FRefreshBar := TPanel.Create(Self);
  FRefreshBar.Parent := FRightHost;
  FRefreshBar.Align  := alTop;
  FRefreshBar.Height := 40;
  FRefreshBar.BevelOuter := bvNone;
  FRefreshBar.Caption := '';

  FBtnRefresh := TButton.Create(Self);
  FBtnRefresh.Parent := FRefreshBar;
  FBtnRefresh.Left   := 8;
  FBtnRefresh.Top    := 6;
  FBtnRefresh.Width  := 110;
  FBtnRefresh.Height := 28;
  FBtnRefresh.Caption := 'Refresh';
  FBtnRefresh.OnClick := DoRefreshClick;
  SetSemantic(FBtnRefresh, skNeutral);

  FLblUpdated := TLabel.Create(Self);
  FLblUpdated.Parent := FRefreshBar;
  FLblUpdated.Left   := 130;
  FLblUpdated.Top    := 12;
  FLblUpdated.Caption := '(not loaded)';
  SetSemantic(FLblUpdated, skMuted);

  // Tabs below.
  FTabs := TPageControl.Create(Self);
  FTabs.Parent := FRightHost;
  FTabs.Align  := alClient;

  FTabPos := TTabSheet.Create(FTabs);
  FTabPos.PageControl := FTabs;
  FTabPos.Caption := 'Positions';

  FGridPos := TStringGrid.Create(Self);
  FGridPos.Parent := FTabPos;
  SetGridDefaults(FGridPos, 8);
  FGridPos.Cells[0, 0] := 'Symbol';
  FGridPos.Cells[1, 0] := 'Exchange';
  FGridPos.Cells[2, 0] := 'Product';
  FGridPos.Cells[3, 0] := 'Net qty';
  FGridPos.Cells[4, 0] := 'Lots';
  FGridPos.Cells[5, 0] := 'Avg';
  FGridPos.Cells[6, 0] := 'LTP';
  FGridPos.Cells[7, 0] := 'P&L';

  // Action buttons below the grid — operate on the selected row.
  // Avoids per-row buttons (which TStringGrid doesn't host gracefully).
  FBtnAddSel := TButton.Create(Self);
  FBtnAddSel.Parent := FTabPos;
  FBtnAddSel.Align  := alBottom;
  FBtnAddSel.Height := 36;
  FBtnAddSel.Caption := 'Add to selected';
  FBtnAddSel.OnClick := DoAddSelClick;
  SetSemantic(FBtnAddSel, skBuy);

  FBtnExitSel := TButton.Create(Self);
  FBtnExitSel.Parent := FTabPos;
  FBtnExitSel.Align  := alBottom;
  FBtnExitSel.Height := 36;
  FBtnExitSel.Caption := 'Exit selected';
  FBtnExitSel.OnClick := DoExitSelClick;
  SetSemantic(FBtnExitSel, skSell);

  FTabTrades := TTabSheet.Create(FTabs);
  FTabTrades.PageControl := FTabs;
  FTabTrades.Caption := 'Tradebook';

  FGridTrades := TStringGrid.Create(Self);
  FGridTrades.Parent := FTabTrades;
  SetGridDefaults(FGridTrades, 1);
  FGridTrades.Cells[0, 0] := 'Trades (raw)';

  FTabOrders := TTabSheet.Create(FTabs);
  FTabOrders.PageControl := FTabs;
  FTabOrders.Caption := 'Orderbook';

  FGridOrders := TStringGrid.Create(Self);
  FGridOrders.Parent := FTabOrders;
  SetGridDefaults(FGridOrders, 1);
  FGridOrders.Cells[0, 0] := 'Orders (raw)';
end;

// ── reactions ──────────────────────────────────────────────────

procedure TTradeFrame.DoSymbolSelected(Sender: TObject;
  const AInst: TInstrument);
begin
  FResolvedInst := AInst;
  FHasResolved  := True;
  ApplyQtyLabelForSegment;
  RevalidateNow;
end;

procedure TTradeFrame.DoBuyClick(Sender: TObject);
begin
  FAction := oaBuy;
  ApplyActionStyling;
  RevalidateNow;
end;

procedure TTradeFrame.DoSellClick(Sender: TObject);
begin
  FAction := oaSell;
  ApplyActionStyling;
  RevalidateNow;
end;

procedure TTradeFrame.DoPriceTypeChange(Sender: TObject);
begin
  ApplyVisibilityForPriceType;
  RevalidateNow;
end;

procedure TTradeFrame.DoQtyChange(Sender: TObject);
begin
  ApplyQtyLabelForSegment;
  RevalidateNow;
end;

procedure TTradeFrame.DoPriceChange(Sender: TObject);
begin
  RevalidateNow;
end;

procedure TTradeFrame.DoTriggerChange(Sender: TObject);
begin
  RevalidateNow;
end;

procedure TTradeFrame.DoPlaceClick(Sender: TObject);
var
  planned: TPlannedOrder;
begin
  planned := BuildPlanned;
  if Assigned(FOnPlace) then FOnPlace(Self, planned);
end;

procedure TTradeFrame.DoRefreshClick(Sender: TObject);
begin
  if Assigned(FOnRefresh) then FOnRefresh(Self);
end;

procedure TTradeFrame.DoAddSelClick(Sender: TObject);
begin
  if (FGridPos.Row <= 0) or (FGridPos.Row - 1 > High(FPositions)) then exit;
  if Assigned(FOnAdd) then FOnAdd(Self, FPositions[FGridPos.Row - 1]);
end;

procedure TTradeFrame.DoExitSelClick(Sender: TObject);
begin
  if (FGridPos.Row <= 0) or (FGridPos.Row - 1 > High(FPositions)) then exit;
  if Assigned(FOnExit) then FOnExit(Self, FPositions[FGridPos.Row - 1]);
end;

// ── styling helpers ────────────────────────────────────────────

procedure TTradeFrame.ApplyActionStyling;
begin
  // Active button gets brighter weight; inactive dims to muted. Both
  // remain coloured by their semantic kind so meaning never gets lost.
  if FAction = oaBuy then
  begin
    FBtnBuy.Font.Style  := [fsBold];
    FBtnSell.Font.Style := [];
  end
  else
  begin
    FBtnBuy.Font.Style  := [];
    FBtnSell.Font.Style := [fsBold];
  end;
end;

procedure TTradeFrame.ApplyVisibilityForPriceType;
var
  pt: TPriceType;
begin
  pt := TPriceType(FCmbPType.ItemIndex);
  // Price visible for LIMIT / SL.
  FPriceRow.Visible   := pt in [ptLimit, ptStopLoss];
  // Trigger visible for SL / SL-M.
  FTriggerRow.Visible := pt in [ptStopLoss, ptStopLossMarket];
end;

procedure TTradeFrame.ApplyQtyLabelForSegment;
var
  qty: Integer;
  seg: TInstrumentSegment;
begin
  if FHasResolved then
    seg := SegmentForExchange(FResolvedInst.CidExchange)
  else
    seg := isCash;

  if seg in [isFnoIndex, isFnoCommod] then
  begin
    FLblQty.Caption := 'Lots';
    if FHasResolved then
    begin
      qty := StrToIntDef(FEdtQty.Text, 0) * FResolvedInst.LotSize;
      FLblQtyHint.Caption := Format('= %d contracts', [qty]);
    end
    else
      FLblQtyHint.Caption := '';
  end
  else
  begin
    FLblQty.Caption := 'Quantity';
    FLblQtyHint.Caption := '';
  end;
end;

function TTradeFrame.BuildPlanned: TPlannedOrder;
var
  lots, qty: Integer;
  seg: TInstrumentSegment;
begin
  FillChar(result, SizeOf(result), 0);
  if not FHasResolved then exit;

  seg := SegmentForExchange(FResolvedInst.CidExchange);

  result.Cid           := FResolvedInst.Cid;
  result.CidExchange   := FResolvedInst.CidExchange;
  result.DisplayName   := string(FResolvedInst.TradingSymbol);
  result.Segment       := seg;
  result.LotSize       := FResolvedInst.LotSize;
  result.InstrumentType := FResolvedInst.InstrumentType;
  result.Underlying    := FResolvedInst.Underlying;
  result.Action        := FAction;
  result.PriceType     := TPriceType(FCmbPType.ItemIndex);
  result.Product       := TProductType(FCmbProduct.ItemIndex);
  result.Price         := StrToFloatDef(FEdtPrice.Text,   0);
  result.Trigger       := StrToFloatDef(FEdtTrigger.Text, 0);
  result.InstanceId    := FCurrentInstance;

  qty := StrToIntDef(FEdtQty.Text, 0);
  if seg in [isFnoIndex, isFnoCommod] then
  begin
    lots := qty;
    result.Lots     := lots;
    if FResolvedInst.LotSize > 0 then
      result.Quantity := lots * FResolvedInst.LotSize
    else
      result.Quantity := lots;
  end
  else
  begin
    result.Lots     := 0;
    result.Quantity := qty;
  end;
end;

procedure TTradeFrame.RevalidateNow;
var
  planned: TPlannedOrder;
  res:     TValidationResult;
begin
  planned := BuildPlanned;
  res := ValidateOrder(planned, FRisk, FAmbient);
  RenderFindings(res);
  FBtnPlace.Enabled := res.Allowed and (planned.Quantity > 0);
end;

procedure TTradeFrame.RenderFindings(const AResult: TValidationResult);
var
  i: Integer;
  prefix: string;
begin
  FFindings.Lines.BeginUpdate;
  try
    FFindings.Lines.Clear;
    if AResult.NotionalInr > 0 then
      FFindings.Lines.Add(
        Format('Notional ~%.0f INR', [AResult.NotionalInr]));
    for i := 0 to High(AResult.Findings) do
    begin
      case AResult.Findings[i].Severity of
        vsBlock: prefix := '[BLOCK]';
        vsWarn:  prefix := '[WARN] ';
        vsInfo:  prefix := '[INFO] ';
      else       prefix := '       ';
      end;
      FFindings.Lines.Add(prefix + ' ' +
        string(AResult.Findings[i].Field) + ': ' +
        AResult.Findings[i].Message);
    end;
    if (AResult.Allowed) and (Length(AResult.Findings) = 0) then
      FFindings.Lines.Add('OK — no risk findings');
  finally
    FFindings.Lines.EndUpdate;
  end;
end;

procedure TTradeFrame.RenderPositionsGrid;
var
  i: Integer;
  r: TPositionRow;
  productLbl: string;
begin
  if Length(FPositions) = 0 then
    FGridPos.RowCount := 2
  else
    FGridPos.RowCount := Length(FPositions) + 1;

  if Length(FPositions) = 0 then
  begin
    for i := 0 to FGridPos.ColCount - 1 do
      FGridPos.Cells[i, 1] := '';
    FGridPos.Cells[0, 1] := '(no open positions)';
    exit;
  end;

  for i := 0 to High(FPositions) do
  begin
    r := FPositions[i];
    productLbl := string(ProductWire(r.Product));
    FGridPos.Cells[0, i + 1] := r.DisplayName;
    FGridPos.Cells[1, i + 1] := string(r.CidExchange);
    FGridPos.Cells[2, i + 1] := productLbl;
    FGridPos.Cells[3, i + 1] := IntToStr(r.NetQuantity);
    if (r.Segment in [isFnoIndex, isFnoCommod]) and (r.LotSize > 0) then
      FGridPos.Cells[4, i + 1] := IntToStr(r.NetQuantity div r.LotSize)
    else
      FGridPos.Cells[4, i + 1] := '';
    FGridPos.Cells[5, i + 1] := FormatFloat('0.00', r.AvgPrice);
    FGridPos.Cells[6, i + 1] := FormatFloat('0.00', r.Ltp);
    FGridPos.Cells[7, i + 1] := FormatFloat('0.00', r.Pnl);
  end;
end;

// ── public surface ─────────────────────────────────────────────

procedure TTradeFrame.SetInstance(const AInstanceId: RawUtf8);
begin
  FCurrentInstance := AInstanceId;
end;

procedure TTradeFrame.SetRiskConfig(const ARisk: TRiskConfig);
begin
  FRisk := ARisk;
  RevalidateNow;
end;

procedure TTradeFrame.SetAmbient(const AAmbient: TAmbientTrading);
begin
  FAmbient := AAmbient;
  RevalidateNow;
end;

procedure TTradeFrame.SetPositions(const AArr: TPositionRowArray);
begin
  FPositions := AArr;
  RenderPositionsGrid;
end;

procedure TTradeFrame.SetTradebookText(const ALines: array of string);
var
  i: Integer;
begin
  if Length(ALines) = 0 then
  begin
    FGridTrades.RowCount := 2;
    FGridTrades.Cells[0, 1] := '(no trades)';
    exit;
  end;
  FGridTrades.RowCount := Length(ALines) + 1;
  for i := 0 to High(ALines) do
    FGridTrades.Cells[0, i + 1] := ALines[i];
end;

procedure TTradeFrame.SetOrderbookText(const ALines: array of string);
var
  i: Integer;
begin
  if Length(ALines) = 0 then
  begin
    FGridOrders.RowCount := 2;
    FGridOrders.Cells[0, 1] := '(no orders)';
    exit;
  end;
  FGridOrders.RowCount := Length(ALines) + 1;
  for i := 0 to High(ALines) do
    FGridOrders.Cells[0, i + 1] := ALines[i];
end;

procedure TTradeFrame.SetUpdatedHint(const AText: string);
begin
  FLblUpdated.Caption := AText;
end;

procedure TTradeFrame.PrefillFromPosition(const ARow: TPositionRow);
begin
  // Build a synthetic instrument from the position row so the same
  // selection plumbing works. CID + exchange + lot-size are what the
  // validator + place wire path need.
  FillChar(FResolvedInst, SizeOf(FResolvedInst), 0);
  FResolvedInst.Cid           := ARow.Cid;
  FResolvedInst.CidExchange   := ARow.CidExchange;
  FResolvedInst.TradingSymbol := RawUtf8(ARow.DisplayName);
  FResolvedInst.LotSize       := ARow.LotSize;
  FHasResolved := True;
  FSymbolSearch.SetText(ARow.DisplayName);

  // Same direction as existing position. Long → BUY (add), short →
  // SELL (add). Operator switches if they meant exit (but we have a
  // dedicated Exit button for that).
  if ARow.NetQuantity >= 0 then FAction := oaBuy
  else                          FAction := oaSell;
  ApplyActionStyling;
  ApplyQtyLabelForSegment;
  RevalidateNow;
end;

end.
