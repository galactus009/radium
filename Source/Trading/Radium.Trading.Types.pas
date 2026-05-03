unit Radium.Trading.Types;

{$mode Delphi}{$H+}

// Trading-screen value types — TPlannedOrder, TPositionRow, the
// segment classifier, and the validation result the validator returns.
// Pure records and free helpers; no UI, no HTTP. The Trade frame and
// the validator both consume this.

interface

uses
  mormot.core.base;

type

  // TInstrumentSegment — qty-vs-lots discriminator.
  //
  //   isCash      → NSE / BSE / NSE_INDEX. Order field is "Quantity".
  //   isFnoIndex  → NFO / BFO. Order field is "Lots"; total qty is
  //                 lots × lot_size (carried in TPlannedOrder.LotSize).
  //   isFnoCommod → MCX. Same lot semantics as isFnoIndex; kept
  //                 separate so the validator can route to the
  //                 commodity option-lot cap.
  //   isHolding   → CDS / NSE-CDS currency. Cash-style qty.
  //
  // Detection lives in SegmentForExchange — derived from the
  // CidExchange string returned by /api/v1/symbol.
  TInstrumentSegment = (isCash, isFnoIndex, isFnoCommod, isHolding);

  // TOrderAction — buy or sell. Mirrors the wire 'action' field on
  // /api/v1/placeorder.
  TOrderAction = (oaBuy, oaSell);

  // TPriceType — order-book pricing mode. Maps 1:1 to thoriumd's
  // 'pricetype' field.
  TPriceType = (ptMarket, ptLimit, ptStopLoss, ptStopLossMarket);

  // TProductType — broker product code. Different brokers gate
  // different products; we expose the cross-broker superset and let
  // the operator pick.
  TProductType = (
    prMis,     // intraday margin
    prNrml,    // overnight (F&O carry / commodity carry)
    prCnc,     // cash-and-carry (delivery)
    prCo,      // cover order (auto-SL)
    prBo       // bracket order (auto-SL + TP)
  );

  // TPlannedOrder — what the order-pad UI assembles before validation.
  // CID + CidExchange uniquely identify the instrument; thoriumd
  // resolves them to broker-key on the way out.
  TPlannedOrder = record
    Cid:           RawUtf8;
    CidExchange:   RawUtf8;
    DisplayName:   string;          // for the confirm modal
    Segment:       TInstrumentSegment;
    LotSize:       Integer;         // 1 for cash, >1 for F&O
    InstrumentType: RawUtf8;        // 'EQ' / 'CE' / 'PE' / 'FUT' / 'INDEX'
    Underlying:    RawUtf8;         // for option premium-per-lot caps

    Action:    TOrderAction;
    PriceType: TPriceType;
    Product:   TProductType;
    Lots:      Integer;             // populated for F&O; 0 for cash
    Quantity:  Integer;             // total qty on the wire
    Price:     Double;              // limit price (0 for MARKET)
    Trigger:   Double;              // SL trigger (0 for non-SL)
    InstanceId: RawUtf8;            // thoriumd session that places it
  end;

  // TValidationSeverity — drives the colour of each validator finding.
  TValidationSeverity = (
    vsInfo,         // notional shown for context, not a problem
    vsWarn,         // breach of a soft knob; operator may proceed
    vsBlock         // breach of a hard knob; submit button disabled
  );

  TValidationFinding = record
    Severity: TValidationSeverity;
    Field:    RawUtf8;             // 'cutoff_time' / 'hard_max_lots' / etc
    Message:  string;
  end;
  TValidationFindingArray = array of TValidationFinding;

  // TValidationResult — what the validator returns. UI bills the
  // operator: green check on Findings empty + Allowed true, otherwise
  // each finding renders as a row with severity-coded icon and the
  // submit button locks if Allowed = False.
  TValidationResult = record
    Allowed:        Boolean;
    NotionalInr:    Double;        // qty * price-or-ltp; for display
    Findings:       TValidationFindingArray;
  end;

  // TPositionRow — one row of /api/v1/positionbook, decoded for the
  // grid. Mirrors thoriumd's broker-agnostic shape; per-broker quirks
  // (e.g. Fyers' product-suffix on symbol) are normalised upstream.
  TPositionRow = record
    Cid:          RawUtf8;
    CidExchange:  RawUtf8;
    DisplayName:  string;
    Product:      TProductType;
    NetQuantity:  Integer;        // signed: long > 0, short < 0
    AvgPrice:     Double;
    Ltp:          Double;
    Pnl:          Double;
    Segment:      TInstrumentSegment;
    LotSize:      Integer;        // for the "Lots" column on F&O rows
    InstanceId:   RawUtf8;        // session that owns this position
  end;
  TPositionRowArray = array of TPositionRow;

  // TAmbientTrading — non-static state the validator consults
  // alongside TRiskConfig. Caller (TradeFrame) populates from the
  // most recent positionbook + funds snapshot.
  TAmbientTrading = record
    NowIst:               TDateTime; // current local IST time
    OpenOrderCount:       Integer;   // /orderbook count
    TodayPnlInr:          Double;    // realised + MTM
    SymbolPnlInr:         Double;    // for the planned CID specifically
    AvailableMarginInr:   Double;    // /funds.available_balance
    UtilizedMarginInr:    Double;    // /funds.utilised_balance
    PlannedLtp:           Double;    // last-trade price for notional est
  end;

// SegmentForExchange — classify a CidExchange string. Used both at
// search-result time (to drive Lots-vs-Qty in the order pad) and at
// position-render time (to colour the qty column with the right
// unit).
function SegmentForExchange(const ACidExchange: RawUtf8): TInstrumentSegment;

// Wire-string helpers for thoriumd's place_order payload. Centralise
// here so adapter / test code never freelances "BUY" vs "Buy".
function ActionWire(AAction: TOrderAction): RawUtf8;
function PriceTypeWire(APriceType: TPriceType): RawUtf8;
function ProductWire(AProduct: TProductType): RawUtf8;

// ProductFromWire — broker may report PNL with a string product code.
// Inverse of ProductWire.
function ProductFromWire(const AWire: RawUtf8): TProductType;

implementation

uses
  SysUtils;

function SegmentForExchange(const ACidExchange: RawUtf8): TInstrumentSegment;
var
  e: string;
begin
  e := UpperCase(string(ACidExchange));
  if (e = 'NFO') or (e = 'BFO') then
    result := isFnoIndex
  else if e = 'MCX' then
    result := isFnoCommod
  else if e = 'CDS' then
    result := isHolding
  else
    result := isCash;  // NSE / BSE / NSE_INDEX / default
end;

function ActionWire(AAction: TOrderAction): RawUtf8;
begin
  case AAction of
    oaBuy:  result := 'BUY';
    oaSell: result := 'SELL';
  else
    result := 'BUY';
  end;
end;

function PriceTypeWire(APriceType: TPriceType): RawUtf8;
begin
  case APriceType of
    ptMarket:          result := 'MARKET';
    ptLimit:           result := 'LIMIT';
    ptStopLoss:        result := 'SL';
    ptStopLossMarket:  result := 'SL-M';
  else
    result := 'MARKET';
  end;
end;

function ProductWire(AProduct: TProductType): RawUtf8;
begin
  case AProduct of
    prMis:  result := 'MIS';
    prNrml: result := 'NRML';
    prCnc:  result := 'CNC';
    prCo:   result := 'CO';
    prBo:   result := 'BO';
  else
    result := 'MIS';
  end;
end;

function ProductFromWire(const AWire: RawUtf8): TProductType;
var
  s: string;
begin
  s := UpperCase(string(AWire));
  if s = 'NRML' then result := prNrml
  else if s = 'CNC' then result := prCnc
  else if s = 'CO' then result := prCo
  else if s = 'BO' then result := prBo
  else result := prMis;
end;

end.
