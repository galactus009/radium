unit Radium.Clerk.Analyzer;

(* ----------------------------------------------------------------------------
  Pascal port of `thoriumd/cmd/clerk/main.go`'s analysis path. The Go
  binary is being removed; this unit is the in-process replacement
  Radium uses to compute round-trips, charges, and per-source / per-
  symbol aggregates from /tradebook + /positionbook + /orderbook.

  Source of truth for the algorithm: clerk's main.go (the version
  Radium ships with). When that file changes the port follows in the
  same diff.

  Decisions that survive from the Go side
  ────────────────────────────────────────
  - Round-trip = run of fills between net-qty-zero states for one
    (symbol, exchange). Open tail → `open` list, computed from
    /positionbook independently.
  - PnL is gross (sell_value - buy_value); NetPnL subtracts an Indian-
    market charges estimate that depends on instrument type.
  - Source classification: orderbook tag → BOT / MAN / TAG. A round-
    trip whose fills span more than one source class becomes MIXED.
  - Verdict = WIN/LOSS/FLAT against NetPnL ± ₹0.50 — same threshold the
    Go binary uses so post-mortem totals match byte-for-byte.

  Coupling
  ────────
  - Pure-Pascal: no HTTP, no SQLite, no file IO. The unit takes raw
    JSON arrays (already pulled from the daemon) and returns a typed
    report. The frame is responsible for driving I/O.
  - Symbol classification uses a callback so the unit doesn't pull in
    TThoriumClient. Pass a lookup that hits /api/v1/symbol when the
    cache misses; pass `nil` to skip server lookup and rely on
    pattern-only classification (cheaper, used in tests).
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  Classes,
  SysUtils,
  DateUtils,
  StrUtils,
  Variants,
  mormot.core.base,
  mormot.core.variants,
  Radium.Clerk.Types;

type
  // Symbol classification result. The lookup callback returns this;
  // missing or unknown fields land at zero/'?' and the analyzer
  // falls back to suffix-based classification.
  TInstrumentClassification = record
    InstType: RawUtf8;   // 'OPT' | 'FUT' | 'EQ' | 'ETF' | '?'
    LotSize:  Integer;   // 0 / 1 for non-derivatives
    Found:    Boolean;
  end;

  // Symbol lookup callback. Returns the canonical classification for
  // (symbol, exchange). Frame wires this to TThoriumClient.SymbolLookup;
  // tests pass a stub.
  TSymbolLookupFn = function(const ASymbol, AExchange: RawUtf8): TInstrumentClassification of object;

// AnalyzeRaw — main entry point. Takes the raw JSON arrays from
// /tradebook + /positionbook + /orderbook (orderbook may be empty);
// returns a fully populated TClerkReport.
//
// ASymbolLookup is invoked once per unique (symbol, exchange) pair;
// pass `nil` to skip server resolution and use suffix heuristics
// only (faster, less accurate for stocks).
function AnalyzeRaw(
  const ATradebookJson, APositionbookJson, AOrderbookJson: RawUtf8;
  ASymbolLookup: TSymbolLookupFn): TClerkReport;

implementation

{ ── charges ─────────────────────────────────────────────────────────

  Indian charges, per instrument class. Constants ported verbatim
  from clerk/main.go — see source of truth there for SEBI / NSE /
  BSE references. }

const
  brokeragePerOrderINR    = 20.0;
  brokeragePctTurnoverFNO = 0.0003;

  sttSellPctOption    = 0.000625;
  txnChargesPctOption = 0.000495;
  stampDutyPctOption  = 0.00003;

  sttSellPctFuture    = 0.000125;
  txnChargesPctFuture = 0.0000019;
  stampDutyPctFuture  = 0.00002;

  sttSellPctEquityIntra    = 0.00025;
  txnChargesPctEquityIntra = 0.0000322;
  stampDutyPctEquityIntra  = 0.00003;

  sebiChargesPct = 0.000001;
  gstPct         = 0.18;

function EstimateCharges(const ART: TClerkRoundTrip): Double;
var
  sellTO, buyTO, totalTO: Double;
  perOrder, alt, brokerage, stt, txn, stamp, sebi, gst: Double;
begin
  sellTO  := ARt.SellValue;
  buyTO   := ARt.BuyValue;
  totalTO := sellTO + buyTO;

  perOrder := brokeragePerOrderINR;
  if (ARt.InstType = 'OPT') or (ARt.InstType = 'FUT') then
  begin
    alt := brokeragePctTurnoverFNO * sellTO;
    if (alt < perOrder) and (alt > 0) then
      perOrder := alt;
  end;
  brokerage := 2 * perOrder;

  if ARt.InstType = 'OPT' then
  begin
    stt   := sttSellPctOption * sellTO;
    txn   := txnChargesPctOption * totalTO;
    stamp := stampDutyPctOption * buyTO;
  end
  else if ARt.InstType = 'FUT' then
  begin
    stt   := sttSellPctFuture * sellTO;
    txn   := txnChargesPctFuture * totalTO;
    stamp := stampDutyPctFuture * buyTO;
  end
  else if (ARt.InstType = 'EQ') or (ARt.InstType = 'ETF') then
  begin
    stt   := sttSellPctEquityIntra * sellTO;
    txn   := txnChargesPctEquityIntra * totalTO;
    stamp := stampDutyPctEquityIntra * buyTO;
  end
  else
  begin
    // Unknown — option rates (most expensive bracket) so we don't
    // underestimate. Same default the Go side uses.
    stt   := sttSellPctOption * sellTO;
    txn   := txnChargesPctOption * totalTO;
    stamp := stampDutyPctOption * buyTO;
  end;

  sebi := sebiChargesPct * totalTO;
  gst  := gstPct * (brokerage + txn + sebi);
  result := brokerage + stt + txn + sebi + stamp + gst;
end;

{ ── classification helpers ─────────────────────────────────────── }

// ClassifyByPattern — last-resort, suffix-based instrument type. Same
// rules the Go side uses: NFO/BFO/MCX/CDS exchanges → derivative;
// CE/PE suffix → option; FUT suffix → future; ETF/BEES suffix → ETF.
function ClassifyByPattern(const ASymbol, AExchange: RawUtf8): RawUtf8;
var
  s, ex: string;
  isFNO: Boolean;
begin
  s  := UpperCase(string(ASymbol));
  ex := UpperCase(string(AExchange));
  isFNO := (ex = 'NFO') or (ex = 'BFO') or (ex = 'MCX') or (ex = 'CDS');
  if isFNO then
  begin
    if EndsStr('CE', s) or EndsStr('PE', s) then
      exit('OPT');
    if EndsStr('FUT', s) then
      exit('FUT');
    exit('OPT');
  end;
  if EndsStr('ETF', s) or EndsStr('BEES', s) or
     EndsStr('GOLDETF', s) or (Pos('LIQUIDETF', s) > 0) then
    exit('ETF');
  result := 'EQ';
end;

// MapInstrumentType — collapses thoriumd/cid's strings into clerk's
// short codes. 'OPT_CE'/'OPT_PE'/'OPT' → 'OPT'; 'FUT_*' → 'FUT';
// 'EQ'/'EQUITY' → 'EQ'; 'ETF' → 'ETF'; anything else → '?'.
function MapInstrumentType(const ARaw: RawUtf8): RawUtf8;
var
  s: string;
begin
  s := UpperCase(string(ARaw));
  if StartsStr('OPT', s) then exit('OPT');
  if StartsStr('FUT', s) then exit('FUT');
  if (s = 'EQ') or (s = 'EQUITY') then exit('EQ');
  if s = 'ETF' then exit('ETF');
  result := '?';
end;

// OptionUnderlying — 'NIFTY05MAY2623600CE' → 'NIFTY'. Stops at the
// first digit; underlies the per-symbol aggregation so all NIFTY
// strikes roll up under one row.
function OptionUnderlying(const ASymbol: RawUtf8): string;
var
  s: string;
  i: Integer;
begin
  s := string(ASymbol);
  for i := 1 to Length(s) do
    if (s[i] >= '0') and (s[i] <= '9') then
    begin
      result := Copy(s, 1, i - 1);
      exit;
    end;
  result := s;
end;

// ClassifySource — fyers-style "<digits>:<tag>" → tag classification.
// Matches optionsbuddy / gammabuddy stamps (`scalper`, `closeposition`,
// `rollback`).
function ClassifySource(const ATag: RawUtf8): RawUtf8;
var
  s, bare: string;
  i, j: Integer;
  digitsOnly: Boolean;
begin
  s := string(ATag);
  if s = '' then exit('MAN');
  bare := s;
  i := Pos(':', bare);
  if i > 1 then
  begin
    digitsOnly := True;
    for j := 1 to i - 1 do
      if (bare[j] < '0') or (bare[j] > '9') then
      begin
        digitsOnly := False;
        break;
      end;
    if digitsOnly then
      bare := Copy(bare, i + 1, MaxInt);
  end;
  if StartsStr('scalper', bare) or
     (bare = 'closeposition') or (bare = 'rollback') then
    exit('BOT');
  result := 'TAG';
end;

{ ── timestamp parsing ────────────────────────────────────────────── }

// ParseTimestamp — fyers /tradebook serialises '30-Apr-2026 09:49:57'
// in IST. We try a few common shapes and fall back to "now in IST" so
// a malformed row sorts at the end rather than at epoch (which would
// shift round-trip bucketing).
function ParseTimestamp(const ARaw: string): TDateTime;
const
  IstOffsetMin = 330;
var
  s, mon: string;
  yy, mm, dd, hh, mn, ss, code: Integer;
  d, t: TDateTime;
begin
  result := 0;
  s := Trim(ARaw);
  if s = '' then exit;

  // Layout 1: '02-Jan-2006 15:04:05'.
  if (Length(s) >= 20) and (s[3] = '-') and (s[7] = '-') and (s[12] = ' ') then
  begin
    Val(Copy(s, 1, 2), dd, code);  if code <> 0 then exit;
    mon := UpperCase(Copy(s, 4, 3));
    if      mon = 'JAN' then mm := 1
    else if mon = 'FEB' then mm := 2
    else if mon = 'MAR' then mm := 3
    else if mon = 'APR' then mm := 4
    else if mon = 'MAY' then mm := 5
    else if mon = 'JUN' then mm := 6
    else if mon = 'JUL' then mm := 7
    else if mon = 'AUG' then mm := 8
    else if mon = 'SEP' then mm := 9
    else if mon = 'OCT' then mm := 10
    else if mon = 'NOV' then mm := 11
    else if mon = 'DEC' then mm := 12
    else mm := 0;
    if mm = 0 then exit;
    Val(Copy(s, 8, 4), yy, code);   if code <> 0 then exit;
    Val(Copy(s, 13, 2), hh, code);  if code <> 0 then exit;
    Val(Copy(s, 16, 2), mn, code);  if code <> 0 then exit;
    Val(Copy(s, 19, 2), ss, code);  if code <> 0 then exit;
    d := EncodeDate(yy, mm, dd);
    t := EncodeTime(hh, mn, ss, 0);
    result := d + t;
    exit;
  end;

  // Layout 2: ISO '2006-01-02T15:04:05[Z|+05:30]'.
  if TryStrToDateTime(s, result, DefaultFormatSettings) then exit;

  // Layout 3: '2006-01-02 15:04:05'.
  if (Length(s) >= 19) and (s[5] = '-') and (s[8] = '-') and (s[11] = ' ') then
  begin
    Val(Copy(s, 1, 4), yy, code);   if code <> 0 then exit;
    Val(Copy(s, 6, 2), mm, code);   if code <> 0 then exit;
    Val(Copy(s, 9, 2), dd, code);   if code <> 0 then exit;
    Val(Copy(s, 12, 2), hh, code);  if code <> 0 then exit;
    Val(Copy(s, 15, 2), mn, code);  if code <> 0 then exit;
    Val(Copy(s, 18, 2), ss, code);  if code <> 0 then exit;
    result := EncodeDate(yy, mm, dd) + EncodeTime(hh, mn, ss, 0);
  end;
end;

function FormatRfc3339(ADt: TDateTime): RawUtf8;
begin
  if ADt = 0 then exit('');
  // We don't track per-fill timezone so report the IST clock as-is
  // (no Z suffix). Frame's status line carries the IST tag.
  result := RawUtf8(FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', ADt));
end;

{ ── intermediate fill record ─────────────────────────────────────── }

type
  TFillSource = (fsManual, fsBot, fsTagged);

  TFill = record
    Symbol:   RawUtf8;
    Exchange: RawUtf8;
    Side:     RawUtf8;       // 'BUY' | 'SELL'
    Qty:      Integer;
    Price:    Double;
    OrderId:  RawUtf8;
    Tag:      RawUtf8;
    Source:   TFillSource;
    TimeAt:   TDateTime;
  end;
  TFillArray = array of TFill;

function SourceTagOf(AFs: TFillSource): RawUtf8;
begin
  case AFs of
    fsBot:    result := 'BOT';
    fsTagged: result := 'TAG';
  else
    result := 'MAN';
  end;
end;

function SourceFromTagString(const ATag: RawUtf8): TFillSource;
var s: RawUtf8;
begin
  if ATag = '' then exit(fsManual);
  s := ClassifySource(ATag);
  if s = 'BOT' then result := fsBot
  else if s = 'TAG' then result := fsTagged
  else result := fsManual;
end;

{ ── variant helpers (small, scoped) ─────────────────────────────── }

function SafeArr(const A: variant): PDocVariantData;
begin
  result := _Safe(A);
end;

function FirstStr(const AObj: variant; const AKeys: array of RawUtf8): RawUtf8;
var
  d: PDocVariantData;
  i, idx: Integer;
  v: variant;
begin
  result := '';
  d := _Safe(AObj);
  for i := 0 to High(AKeys) do
  begin
    idx := d^.GetValueIndex(string(AKeys[i]));
    if idx >= 0 then
    begin
      v := d^.Values[idx];
      if VarIsStr(v) then
      begin
        result := RawUtf8(string(v));
        if result <> '' then exit;
      end;
    end;
  end;
end;

function FirstInt(const AObj: variant; const AKeys: array of RawUtf8): Integer;
var
  d: PDocVariantData;
  i, idx: Integer;
  v: variant;
begin
  result := 0;
  d := _Safe(AObj);
  for i := 0 to High(AKeys) do
  begin
    idx := d^.GetValueIndex(string(AKeys[i]));
    if idx >= 0 then
    begin
      v := d^.Values[idx];
      if VarIsNumeric(v) then
      begin
        result := Integer(v);
        if result <> 0 then exit;
      end;
    end;
  end;
end;

function FirstFloat(const AObj: variant; const AKeys: array of RawUtf8): Double;
var
  d: PDocVariantData;
  i, idx: Integer;
  v: variant;
begin
  result := 0;
  d := _Safe(AObj);
  for i := 0 to High(AKeys) do
  begin
    idx := d^.GetValueIndex(string(AKeys[i]));
    if idx >= 0 then
    begin
      v := d^.Values[idx];
      if VarIsNumeric(v) then
      begin
        result := Double(v);
        if result <> 0 then exit;
      end;
    end;
  end;
end;

{ ── normalise, split, aggregate ─────────────────────────────────── }

type
  TTagMap = record
    OrderId: RawUtf8;
    Tag:     RawUtf8;
  end;
  TTagMapArray = array of TTagMap;

function BuildTagMap(const AOrderbookJson: RawUtf8): TTagMapArray;
var
  arr: variant;
  d: PDocVariantData;
  i: Integer;
  oid, tag: RawUtf8;
begin
  result := nil;
  if AOrderbookJson = '' then exit;
  arr := _Json(AOrderbookJson);
  if VarIsEmptyOrNull(arr) then exit;
  d := _Safe(arr);
  if d^.Kind <> dvArray then exit;
  for i := 0 to d^.Count - 1 do
  begin
    oid := FirstStr(d^.Values[i], ['order_id', 'orderid', 'id']);
    tag := FirstStr(d^.Values[i], ['tag', 'ordertag']);
    if oid <> '' then
    begin
      SetLength(result, Length(result) + 1);
      result[High(result)].OrderId := oid;
      result[High(result)].Tag := tag;
    end;
  end;
end;

function LookupTag(const AMap: TTagMapArray; const AOrderId: RawUtf8): RawUtf8;
var i: Integer;
begin
  result := '';
  for i := 0 to High(AMap) do
    if AMap[i].OrderId = AOrderId then
    begin
      result := AMap[i].Tag;
      exit;
    end;
end;

function NormaliseFills(const ATradebookJson: RawUtf8;
  const ATagMap: TTagMapArray): TFillArray;
var
  arr: variant;
  d: PDocVariantData;
  i: Integer;
  f: TFill;
  side: string;
begin
  result := nil;
  arr := _Json(ATradebookJson);
  if VarIsEmptyOrNull(arr) then exit;
  d := _Safe(arr);
  if d^.Kind <> dvArray then exit;

  for i := 0 to d^.Count - 1 do
  begin
    FillChar(f, SizeOf(f), 0);
    f.Symbol   := FirstStr  (d^.Values[i], ['symbol', 'tradingsymbol']);
    f.Exchange := FirstStr  (d^.Values[i], ['exchange']);
    side       := UpperCase(string(FirstStr(d^.Values[i], ['side', 'transaction_type'])));
    f.Side     := RawUtf8(side);
    f.Qty      := FirstInt  (d^.Values[i], ['quantity', 'filled_quantity', 'traded_qty']);
    f.Price    := FirstFloat(d^.Values[i], ['price', 'trade_price', 'traded_price']);
    f.OrderId  := FirstStr  (d^.Values[i], ['order_id', 'orderid']);
    f.TimeAt   := ParseTimestamp(string(FirstStr(d^.Values[i],
      ['timestamp', 'trade_time', 'order_time'])));

    if (f.Symbol = '') or (f.Side = '') or (f.Qty = 0) or (f.Price = 0) then
      continue;

    f.Tag := LookupTag(ATagMap, f.OrderId);
    f.Source := SourceFromTagString(f.Tag);

    SetLength(result, Length(result) + 1);
    result[High(result)] := f;
  end;
end;

procedure SortFillsByTime(var AFills: TFillArray);
var
  i, j: Integer;
  tmp: TFill;
begin
  // Insertion sort — small N (a session's tradebook rarely > 200 rows).
  for i := 1 to High(AFills) do
  begin
    tmp := AFills[i];
    j := i - 1;
    while (j >= 0) and (AFills[j].TimeAt > tmp.TimeAt) do
    begin
      AFills[j + 1] := AFills[j];
      Dec(j);
    end;
    AFills[j + 1] := tmp;
  end;
end;

function GroupKey(const AFill: TFill): string;
begin
  result := string(AFill.Symbol) + '|' + string(AFill.Exchange);
end;

type
  TGroup = record
    Key:   string;
    Fills: TFillArray;
  end;
  TGroupArray = array of TGroup;

procedure GroupFills(const AFills: TFillArray; out AGroups: TGroupArray);
var
  i, j: Integer;
  found: Boolean;
  k: string;
begin
  AGroups := nil;
  for i := 0 to High(AFills) do
  begin
    k := GroupKey(AFills[i]);
    found := False;
    for j := 0 to High(AGroups) do
      if AGroups[j].Key = k then
      begin
        SetLength(AGroups[j].Fills, Length(AGroups[j].Fills) + 1);
        AGroups[j].Fills[High(AGroups[j].Fills)] := AFills[i];
        found := True;
        break;
      end;
    if not found then
    begin
      SetLength(AGroups, Length(AGroups) + 1);
      AGroups[High(AGroups)].Key := k;
      SetLength(AGroups[High(AGroups)].Fills, 1);
      AGroups[High(AGroups)].Fills[0] := AFills[i];
    end;
  end;
end;

function CombineSourceTags(AHasMan, AHasBot, AHasTag: Boolean): RawUtf8;
var
  count: Integer;
begin
  count := Ord(AHasMan) + Ord(AHasBot) + Ord(AHasTag);
  if count > 1 then exit('MIXED');
  if AHasBot then exit('BOT');
  if AHasTag then exit('TAG');
  result := 'MAN';
end;

procedure SplitRoundTrips(const AGroup: TFillArray;
  var AOut: TClerkRoundTripArray);
var
  cur: TClerkRoundTrip;
  netQty, i, n: Integer;
  hasMan, hasBot, hasTag: Boolean;
begin
  netQty := 0;
  hasMan := False; hasBot := False; hasTag := False;
  FillChar(cur, SizeOf(cur), 0);
  for i := 0 to High(AGroup) do
  begin
    if netQty = 0 then
    begin
      FillChar(cur, SizeOf(cur), 0);
      cur.Symbol   := AGroup[i].Symbol;
      cur.Exchange := AGroup[i].Exchange;
      cur.OpenedAt := FormatRfc3339(AGroup[i].TimeAt);
      hasMan := False; hasBot := False; hasTag := False;
    end;

    if AGroup[i].Side = 'BUY' then
    begin
      Inc(netQty, AGroup[i].Qty);
      Inc(cur.BuyQty, AGroup[i].Qty);
      cur.BuyValue := cur.BuyValue + AGroup[i].Qty * AGroup[i].Price;
    end
    else if AGroup[i].Side = 'SELL' then
    begin
      Dec(netQty, AGroup[i].Qty);
      Inc(cur.SellQty, AGroup[i].Qty);
      cur.SellValue := cur.SellValue + AGroup[i].Qty * AGroup[i].Price;
    end;

    case AGroup[i].Source of
      fsManual: hasMan := True;
      fsBot:    hasBot := True;
      fsTagged: hasTag := True;
    end;

    if netQty = 0 then
    begin
      cur.ClosedAt := FormatRfc3339(AGroup[i].TimeAt);
      cur.GrossPnL := cur.SellValue - cur.BuyValue;
      cur.SourceTag := CombineSourceTags(hasMan, hasBot, hasTag);
      // InstType + LotSize get filled in the caller via the symbol
      // resolver (one lookup per round-trip key, not per fill).
      n := Length(AOut);
      SetLength(AOut, n + 1);
      AOut[n] := cur;
    end;
  end;
end;

function VerdictOf(const ART: TClerkRoundTrip): string;
begin
  if ART.NetPnL > 0.5 then exit('WIN');
  if ART.NetPnL < -0.5 then exit('LOSS');
  result := 'FLAT';
end;

procedure NormaliseOpenPositions(const APositionbookJson: RawUtf8;
  ASymbolLookup: TSymbolLookupFn;
  var AOut: TClerkOpenPositionArray);
var
  arr: variant;
  d: PDocVariantData;
  i, n, qty: Integer;
  sym, ex: RawUtf8;
  cls: TInstrumentClassification;
  pos: TClerkOpenPosition;
begin
  AOut := nil;
  if APositionbookJson = '' then exit;
  arr := _Json(APositionbookJson);
  if VarIsEmptyOrNull(arr) then exit;
  d := _Safe(arr);
  if d^.Kind <> dvArray then exit;

  for i := 0 to d^.Count - 1 do
  begin
    qty := FirstInt(d^.Values[i], ['quantity', 'netqty', 'net_qty']);
    if qty = 0 then continue;
    sym := FirstStr(d^.Values[i], ['symbol', 'tradingsymbol']);
    ex  := FirstStr(d^.Values[i], ['exchange']);

    cls.Found := False;
    if Assigned(ASymbolLookup) then
      cls := ASymbolLookup(sym, ex);
    if not cls.Found then
    begin
      cls.InstType := ClassifyByPattern(sym, ex);
      if cls.LotSize = 0 then cls.LotSize := 1;
    end;

    FillChar(pos, SizeOf(pos), 0);
    pos.Symbol     := sym;
    pos.Exchange   := ex;
    pos.InstType   := cls.InstType;
    pos.LotSize    := cls.LotSize;
    pos.Qty        := qty;
    pos.AvgPrice   := FirstFloat(d^.Values[i], ['avg_price', 'netavg', 'average_price']);
    pos.Ltp        := FirstFloat(d^.Values[i], ['ltp', 'last_price']);
    pos.Unrealized := FirstFloat(d^.Values[i], ['pnl', 'unrealizedprofit', 'unrealized_profit']);

    n := Length(AOut);
    SetLength(AOut, n + 1);
    AOut[n] := pos;
  end;
end;

{ ── aggregate ────────────────────────────────────────────────────── }

procedure AggregateBySource(var AReport: TClerkReport);
var
  i, j, n: Integer;
  found: Boolean;
  src: RawUtf8;
  v: string;
begin
  for i := 0 to High(AReport.Trips) do
  begin
    src := AReport.Trips[i].SourceTag;
    found := False;
    for j := 0 to High(AReport.PerSource) do
      if AReport.PerSource[j].Source = src then
      begin
        Inc(AReport.PerSource[j].Trips);
        v := VerdictOf(AReport.Trips[i]);
        if v = 'WIN' then Inc(AReport.PerSource[j].Wins);
        AReport.PerSource[j].Realized := AReport.PerSource[j].Realized + AReport.Trips[i].NetPnL;
        AReport.PerSource[j].Charges  := AReport.PerSource[j].Charges  + AReport.Trips[i].Charges;
        found := True;
        break;
      end;
    if not found then
    begin
      n := Length(AReport.PerSource);
      SetLength(AReport.PerSource, n + 1);
      AReport.PerSource[n].Source := src;
      AReport.PerSource[n].Trips := 1;
      v := VerdictOf(AReport.Trips[i]);
      if v = 'WIN' then AReport.PerSource[n].Wins := 1;
      AReport.PerSource[n].Realized := AReport.Trips[i].NetPnL;
      AReport.PerSource[n].Charges  := AReport.Trips[i].Charges;
    end;
  end;
end;

procedure AggregateBySymbol(var AReport: TClerkReport);
  function FindOrAdd(const ASym, AType: RawUtf8): Integer;
  var k: Integer;
  begin
    for k := 0 to High(AReport.PerSymbol) do
      if AReport.PerSymbol[k].Symbol = ASym then
        exit(k);
    SetLength(AReport.PerSymbol, Length(AReport.PerSymbol) + 1);
    result := High(AReport.PerSymbol);
    AReport.PerSymbol[result].Symbol   := ASym;
    AReport.PerSymbol[result].InstType := AType;
  end;
var
  i, idx: Integer;
  base: RawUtf8;
  v: string;
begin
  for i := 0 to High(AReport.Trips) do
  begin
    base := RawUtf8(OptionUnderlying(AReport.Trips[i].Symbol));
    idx := FindOrAdd(base, AReport.Trips[i].InstType);
    Inc(AReport.PerSymbol[idx].Trips);
    v := VerdictOf(AReport.Trips[i]);
    if v = 'WIN' then Inc(AReport.PerSymbol[idx].Wins);
    AReport.PerSymbol[idx].Realized := AReport.PerSymbol[idx].Realized + AReport.Trips[i].NetPnL;
    AReport.PerSymbol[idx].Charges  := AReport.PerSymbol[idx].Charges  + AReport.Trips[i].Charges;
  end;
  for i := 0 to High(AReport.Open) do
  begin
    base := RawUtf8(OptionUnderlying(AReport.Open[i].Symbol));
    idx := FindOrAdd(base, AReport.Open[i].InstType);
    if AReport.Open[i].Qty < 0 then
      Inc(AReport.PerSymbol[idx].OpenQty, -AReport.Open[i].Qty)
    else
      Inc(AReport.PerSymbol[idx].OpenQty, AReport.Open[i].Qty);
    AReport.PerSymbol[idx].Unrealized := AReport.PerSymbol[idx].Unrealized + AReport.Open[i].Unrealized;
  end;
end;

{ ── classification cache for the analyzer ───────────────────────── }

type
  TClassifyEntry = record
    Symbol, Exchange: RawUtf8;
    Cls:              TInstrumentClassification;
  end;

procedure CacheGet(var ACache: array of TClassifyEntry;
  const ASymbol, AExchange: RawUtf8; out AHit: Boolean;
  out ACls: TInstrumentClassification);
var i: Integer;
begin
  AHit := False;
  for i := 0 to High(ACache) do
    if (ACache[i].Symbol = ASymbol) and (ACache[i].Exchange = AExchange) then
    begin
      AHit := True;
      ACls := ACache[i].Cls;
      exit;
    end;
end;

procedure CachePut(var ACache: array of TClassifyEntry; var ALen: Integer;
  const ASymbol, AExchange: RawUtf8; const ACls: TInstrumentClassification);
begin
  // ACache is preallocated; ALen is the live count. Caller sizes it
  // generously; we don't grow on the fly.
  if ALen >= Length(ACache) then exit;
  ACache[ALen].Symbol   := ASymbol;
  ACache[ALen].Exchange := AExchange;
  ACache[ALen].Cls      := ACls;
  Inc(ALen);
end;

{ ── main entry ──────────────────────────────────────────────────── }

function AnalyzeRaw(
  const ATradebookJson, APositionbookJson, AOrderbookJson: RawUtf8;
  ASymbolLookup: TSymbolLookupFn): TClerkReport;
var
  tagMap: TTagMapArray;
  fills: TFillArray;
  groups: TGroupArray;
  i, j: Integer;
  trips: TClerkRoundTripArray;
  cls: TInstrumentClassification;
  hit: Boolean;
  cache: array of TClassifyEntry;
  cacheLen: Integer;
  v: string;
begin
  FillChar(result, SizeOf(result), 0);

  tagMap := BuildTagMap(AOrderbookJson);
  fills  := NormaliseFills(ATradebookJson, tagMap);
  SortFillsByTime(fills);
  GroupFills(fills, groups);

  // Generous cache — at most one entry per (symbol, exchange) group
  // plus one per open position. 256 covers every realistic session.
  SetLength(cache, 256);
  cacheLen := 0;

  for i := 0 to High(groups) do
  begin
    trips := nil;
    SplitRoundTrips(groups[i].Fills, trips);
    if Length(trips) = 0 then continue;

    // Classify the group's instrument once.
    CacheGet(cache, trips[0].Symbol, trips[0].Exchange, hit, cls);
    if not hit then
    begin
      cls.Found := False;
      if Assigned(ASymbolLookup) then
        cls := ASymbolLookup(trips[0].Symbol, trips[0].Exchange);
      if not cls.Found then
      begin
        cls.InstType := ClassifyByPattern(trips[0].Symbol, trips[0].Exchange);
        if cls.LotSize = 0 then cls.LotSize := 1;
      end;
      CachePut(cache, cacheLen, trips[0].Symbol, trips[0].Exchange, cls);
    end;

    for j := 0 to High(trips) do
    begin
      trips[j].InstType := cls.InstType;
      trips[j].LotSize  := cls.LotSize;
      trips[j].Charges  := EstimateCharges(trips[j]);
      trips[j].NetPnL   := trips[j].GrossPnL - trips[j].Charges;
    end;

    SetLength(result.Trips, Length(result.Trips) + Length(trips));
    for j := 0 to High(trips) do
      result.Trips[Length(result.Trips) - Length(trips) + j] := trips[j];
  end;

  NormaliseOpenPositions(APositionbookJson, ASymbolLookup, result.Open);

  // Totals.
  for i := 0 to High(result.Trips) do
  begin
    v := VerdictOf(result.Trips[i]);
    if v = 'WIN' then
    begin
      Inc(result.Wins);
      result.GrossWin := result.GrossWin + result.Trips[i].NetPnL;
    end
    else if v = 'LOSS' then
    begin
      Inc(result.Losses);
      result.GrossLoss := result.GrossLoss + result.Trips[i].NetPnL;
    end
    else
      Inc(result.Flats);
    result.GrossPnL     := result.GrossPnL     + result.Trips[i].GrossPnL;
    result.ChargesTotal := result.ChargesTotal + result.Trips[i].Charges;
    result.Realized     := result.Realized     + result.Trips[i].NetPnL;
  end;
  for i := 0 to High(result.Open) do
    result.Unrealized := result.Unrealized + result.Open[i].Unrealized;

  AggregateBySource(result);
  AggregateBySymbol(result);

  result.GeneratedAt := RawUtf8(FormatDateTime('yyyy-mm-dd"T"hh:nn:ss', Now));
  result.SourceLabel := RawUtf8('live run · ' + FormatDateTime('hh:nn', Now) + ' IST');
end;

end.
