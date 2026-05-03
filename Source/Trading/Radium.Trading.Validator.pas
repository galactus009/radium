unit Radium.Trading.Validator;

{$mode Delphi}{$H+}

// Risk validator for one TPlannedOrder against the current TRiskConfig
// + ambient trading state (today's P&L, available margin, current
// open-order count, current open-position size).
//
// Lives client-side so the order pad can surface every breach
// immediately as the operator types — no server round-trip for the
// happy-path "is this within knobs". A future thoriumd
// /orders/validate endpoint would dry-run all 13 policies on the
// canonical engine; this code is the first line of defence and the
// place we surface the operator-readable reason when something blocks.
//
// Knobs covered (TRiskConfig fields → TValidationFinding rules):
//   - CutoffTime           → block placement after the configured
//                            wall-clock time (HH:MM:SS, IST).
//   - MaxOpenOrders        → block when adding this would exceed the
//                            cap. Caller passes the current count.
//   - MaxDailyLoss         → block when planned notional would push
//                            today's realised + unrealised PnL past
//                            the limit. Caller passes today's PnL.
//   - MaxSymbolLoss        → similar but per-CID; caller passes
//                            symbol PnL.
//   - HardMaxLots          → F&O lot cap, ANY product. Block at >cap.
//   - HardMaxNotional      → notional cap across all segments.
//   - MaxOptionLots        → CE/PE-only lot cap. Block at >cap.
//   - MaxPremiumPerLot     → option premium ceiling per lot. Warn,
//                            doesn't block (operator may know better).
//   - MaxOptionNotional    → option notional cap.
//   - IntradayLeverage     → leverage check using planned notional /
//                            available margin. Warn over cap.
//   - ExposureUtilization  → utilised margin / total margin. Warn at
//                            >cap.
//   - MaxMarginUtilization → as above, but blocking severity. (Two
//                            knobs let the operator set a soft and a
//                            hard line.)
//   - MinAvailableMargin   → block when margin falls below floor.
//
// Findings are accumulated in a stable order so the UI can present
// them deterministically. Severity defaults to vsBlock for hard
// knobs, vsWarn for advisory knobs.

interface

uses
  SysUtils,
  mormot.core.base,
  Radium.Api.Types,
  Radium.Trading.Types;

function ValidateOrder(const APlanned: TPlannedOrder;
                       const ARisk:    TRiskConfig;
                       const AAmbient: TAmbientTrading): TValidationResult;

implementation

uses
  DateUtils;

// ── helpers ─────────────────────────────────────────────────────────

function IsOption(AInstrumentType: RawUtf8): Boolean;
var
  s: string;
begin
  s := UpperCase(string(AInstrumentType));
  result := (s = 'CE') or (s = 'PE') or (s = 'OPTIDX') or (s = 'OPTSTK');
end;

function ParseHmsToFraction(const AStr: RawUtf8;
                            out AFraction: Double): Boolean;
var
  s: string;
  h, m, sec: Integer;
  parts: TStringArray;
begin
  result := False;
  s := Trim(string(AStr));
  if s = '' then exit;
  parts := s.Split([':']);
  if Length(parts) < 2 then exit;
  if not TryStrToInt(parts[0], h) then exit;
  if not TryStrToInt(parts[1], m) then exit;
  sec := 0;
  if Length(parts) >= 3 then
    if not TryStrToInt(parts[2], sec) then sec := 0;
  AFraction := (h * 3600 + m * 60 + sec) / 86400.0;
  result := True;
end;

function NotionalFor(const APlanned: TPlannedOrder; ALtp: Double): Double;
var
  px: Double;
begin
  // MARKET / SL-M have no operator price — we substitute the LTP the
  // caller passed so the notional reads true. LIMIT / SL use the
  // operator's price (which is what'll match if filled).
  case APlanned.PriceType of
    ptMarket, ptStopLossMarket: px := ALtp;
  else
    px := APlanned.Price;
  end;
  if (px <= 0) and (ALtp > 0) then px := ALtp;
  if px <= 0 then begin result := 0; exit end;
  result := px * APlanned.Quantity;
end;

procedure AddFinding(var AResult: TValidationResult;
                     ASeverity: TValidationSeverity;
                     const AField: RawUtf8;
                     const AMessage: string);
var
  i: Integer;
begin
  i := Length(AResult.Findings);
  SetLength(AResult.Findings, i + 1);
  AResult.Findings[i].Severity := ASeverity;
  AResult.Findings[i].Field    := AField;
  AResult.Findings[i].Message  := AMessage;
  if ASeverity = vsBlock then AResult.Allowed := False;
end;

// ── rules ──────────────────────────────────────────────────────────

procedure CheckCutoff(var AResult: TValidationResult;
                      const ARisk: TRiskConfig;
                      const AAmbient: TAmbientTrading);
var
  cutoffFrac, nowFrac: Double;
begin
  if ARisk.CutoffTime = '' then exit;
  if not ParseHmsToFraction(ARisk.CutoffTime, cutoffFrac) then exit;
  // We compare the time-of-day fractions only — a pre-market spike
  // (e.g. 09:14:59) sails through, the cutoff is "no orders after
  // HH:MM" not "no orders today after the first time we passed
  // HH:MM", which would be wrong on a session-rollover day.
  nowFrac := Frac(AAmbient.NowIst);
  if nowFrac > cutoffFrac then
    AddFinding(AResult, vsBlock, 'cutoff_time',
      Format('After cutoff %s — no new orders allowed',
        [string(ARisk.CutoffTime)]));
end;

procedure CheckOpenOrders(var AResult: TValidationResult;
                          const ARisk: TRiskConfig;
                          const AAmbient: TAmbientTrading);
begin
  if ARisk.MaxOpenOrders <= 0 then exit;
  if AAmbient.OpenOrderCount + 1 > ARisk.MaxOpenOrders then
    AddFinding(AResult, vsBlock, 'max_open_orders',
      Format('Already %d open orders (cap %d) — close some first',
        [AAmbient.OpenOrderCount, ARisk.MaxOpenOrders]));
end;

procedure CheckDailyLoss(var AResult: TValidationResult;
                          const ARisk: TRiskConfig;
                          const AAmbient: TAmbientTrading);
begin
  // MaxDailyLoss is stored as a positive number ("rupees"). Today's
  // P&L is signed; a loss is negative. We block when the loss has
  // already breached the limit; opening a new trade can't directly
  // breach a P&L knob (only fills can), but if we're already past
  // the limit refusing new orders is the right behaviour.
  if ARisk.MaxDailyLoss <= 0 then exit;
  if AAmbient.TodayPnlInr < -ARisk.MaxDailyLoss then
    AddFinding(AResult, vsBlock, 'max_daily_loss',
      Format('Today P&L %.0f INR is past loss cap %.0f',
        [AAmbient.TodayPnlInr, -ARisk.MaxDailyLoss]));
end;

procedure CheckSymbolLoss(var AResult: TValidationResult;
                           const ARisk: TRiskConfig;
                           const AAmbient: TAmbientTrading);
begin
  if ARisk.MaxSymbolLoss <= 0 then exit;
  if AAmbient.SymbolPnlInr < -ARisk.MaxSymbolLoss then
    AddFinding(AResult, vsBlock, 'max_symbol_loss',
      Format('Symbol P&L %.0f INR is past per-symbol cap %.0f',
        [AAmbient.SymbolPnlInr, -ARisk.MaxSymbolLoss]));
end;

procedure CheckLotsAndNotional(var AResult: TValidationResult;
                                const APlanned: TPlannedOrder;
                                const ARisk: TRiskConfig;
                                ANotional: Double);
var
  isFno: Boolean;
  isOpt: Boolean;
begin
  isFno := APlanned.Segment in [isFnoIndex, isFnoCommod];
  isOpt := IsOption(APlanned.InstrumentType);

  if isFno and (ARisk.HardMaxLots > 0) and (APlanned.Lots > ARisk.HardMaxLots) then
    AddFinding(AResult, vsBlock, 'hard_max_lots',
      Format('%d lots exceeds hard cap %d',
        [APlanned.Lots, ARisk.HardMaxLots]));

  if (ARisk.HardMaxNotional > 0) and (ANotional > ARisk.HardMaxNotional) then
    AddFinding(AResult, vsBlock, 'hard_max_notional',
      Format('Notional %.0f INR exceeds cap %.0f',
        [ANotional, ARisk.HardMaxNotional]));

  if isOpt then
  begin
    if (ARisk.MaxOptionLots > 0) and (APlanned.Lots > ARisk.MaxOptionLots) then
      AddFinding(AResult, vsBlock, 'max_option_lots',
        Format('%d option lots exceeds cap %d',
          [APlanned.Lots, ARisk.MaxOptionLots]));
    if (ARisk.MaxOptionNotional > 0) and (ANotional > ARisk.MaxOptionNotional) then
      AddFinding(AResult, vsBlock, 'max_option_notional',
        Format('Option notional %.0f exceeds cap %.0f',
          [ANotional, ARisk.MaxOptionNotional]));
    if (ARisk.MaxPremiumPerLot > 0) and (APlanned.LotSize > 0) and
       (APlanned.Price * APlanned.LotSize > ARisk.MaxPremiumPerLot) then
      AddFinding(AResult, vsWarn, 'max_premium_per_lot',
        Format('Premium-per-lot %.0f over advisory cap %.0f',
          [APlanned.Price * APlanned.LotSize, ARisk.MaxPremiumPerLot]));
  end;
end;

procedure CheckMargin(var AResult: TValidationResult;
                      const ARisk: TRiskConfig;
                      const AAmbient: TAmbientTrading;
                      ANotional: Double);
var
  utilPct, leverage, plannedAvail: Double;
begin
  // Available margin is the floor we mustn't cross.
  if ARisk.MinAvailableMargin > 0 then
  begin
    plannedAvail := AAmbient.AvailableMarginInr - ANotional;
    if plannedAvail < ARisk.MinAvailableMargin then
      AddFinding(AResult, vsBlock, 'min_available_margin',
        Format('Available margin would drop to %.0f, below floor %.0f',
          [plannedAvail, ARisk.MinAvailableMargin]));
  end;

  // Utilisation pct (utilised + thisorder) / (utilised + available).
  // Need denom > 0 to avoid div-by-zero on a zero-balance account.
  if (ARisk.MaxMarginUtilization > 0) and
     (AAmbient.UtilizedMarginInr + AAmbient.AvailableMarginInr > 0) then
  begin
    utilPct :=
      (AAmbient.UtilizedMarginInr + ANotional) /
      (AAmbient.UtilizedMarginInr + AAmbient.AvailableMarginInr);
    if utilPct > ARisk.MaxMarginUtilization then
      AddFinding(AResult, vsBlock, 'max_margin_utilization',
        Format('Margin utilisation would hit %.1f%%, above %.1f%% cap',
          [utilPct * 100.0, ARisk.MaxMarginUtilization * 100.0]));
  end;

  if (ARisk.ExposureUtilization > 0) and
     (AAmbient.UtilizedMarginInr + AAmbient.AvailableMarginInr > 0) then
  begin
    utilPct :=
      (AAmbient.UtilizedMarginInr + ANotional) /
      (AAmbient.UtilizedMarginInr + AAmbient.AvailableMarginInr);
    if utilPct > ARisk.ExposureUtilization then
      AddFinding(AResult, vsWarn, 'exposure_utilization',
        Format('Exposure %.1f%% over advisory %.1f%%',
          [utilPct * 100.0, ARisk.ExposureUtilization * 100.0]));
  end;

  if (ARisk.IntradayLeverage > 0) and (AAmbient.AvailableMarginInr > 0) then
  begin
    leverage := ANotional / AAmbient.AvailableMarginInr;
    if leverage > ARisk.IntradayLeverage then
      AddFinding(AResult, vsWarn, 'intraday_leverage',
        Format('Implied leverage %.2fx over %.2fx cap',
          [leverage, ARisk.IntradayLeverage]));
  end;
end;

// ── entrypoint ─────────────────────────────────────────────────────

function ValidateOrder(const APlanned: TPlannedOrder;
                       const ARisk:    TRiskConfig;
                       const AAmbient: TAmbientTrading): TValidationResult;
begin
  result.Allowed := True;
  result.NotionalInr := NotionalFor(APlanned, AAmbient.PlannedLtp);
  SetLength(result.Findings, 0);

  // Sanity gates first — before risk knobs, refuse obviously broken
  // input. UI shouldn't even let these through but defence in depth.
  if APlanned.Quantity <= 0 then
    AddFinding(result, vsBlock, 'quantity',
      'Quantity must be positive');
  if (APlanned.PriceType in [ptLimit, ptStopLoss]) and (APlanned.Price <= 0) then
    AddFinding(result, vsBlock, 'price',
      'LIMIT / SL needs a price > 0');
  if (APlanned.PriceType in [ptStopLoss, ptStopLossMarket]) and (APlanned.Trigger <= 0) then
    AddFinding(result, vsBlock, 'trigger',
      'SL / SL-M needs a trigger > 0');
  if APlanned.Cid = '' then
    AddFinding(result, vsBlock, 'cid',
      'Symbol must be selected from the search dropdown');

  // Risk knobs.
  CheckCutoff      (result, ARisk, AAmbient);
  CheckOpenOrders  (result, ARisk, AAmbient);
  CheckDailyLoss   (result, ARisk, AAmbient);
  CheckSymbolLoss  (result, ARisk, AAmbient);
  CheckLotsAndNotional(result, APlanned, ARisk, result.NotionalInr);
  CheckMargin      (result, ARisk, AAmbient, result.NotionalInr);
end;

end.
