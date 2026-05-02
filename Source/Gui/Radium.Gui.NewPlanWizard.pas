unit Radium.Gui.NewPlanWizard;

(* ----------------------------------------------------------------------------
  New-plan wizard. One modal, seven steps:

      1. Bot         — confirm or switch capability (Options / Gamma)
      2. Session     — pick instance (broker auto-displayed)
      3. Markets     — underlyings, lots, exchange, product
      4. Money       — max premium, max open legs, max strikes, loss caps,
                       dry-run toggle
      5. Time        — entry window, stop-entries-at, hard exit, monitor-until
      6. Tuning      — capability-specific (SL/TP/trail for options;
                       VIX thresholds + mode for gamma) plus an advanced
                       free-form key/value grid for everything we don't
                       surface yet
      7. Review      — narrative summary + Create button

  Why a wizard: TradePlan submission has eight conceptually different
  decision groups (bot, where, what, money, time, tuning, advanced,
  confirm). Cramming them onto one screen reads like a tax form. A
  stepped flow lets the operator answer one question at a time, keeps
  copy plain-language, and gives us a natural place to surface
  defaults + helper text.

  The wizard is HTTP-free: it produces a `TPlanCreateRequest` (typed
  data, no mORMot / variant types) and the caller decides whether to
  submit it to thoriumd via `TThoriumClient.PlanCreateTyped` or — when
  the in-process Pascal runner lands — execute it locally. Per the
  pinned design constraint (memory: plan_execution_target.md),
  TPlanCreateRequest stays decoupled from the wire codec.

  Layout (programmatic, no .lfm):

    +- New plan: Options Scalper ────────────────────────────────────+
    |                                                                 |
    |  ●─○─○─○─○─○─○             Step 1 of 7 · Bot                   |
    |                                                                 |
    |  Big card that swaps per step                                   |
    |  ...                                                            |
    |                                                                 |
    |                                                                 |
    +-----------------------------------------------------------------+
    |  [< Back]                                  [Cancel]  [Next >]   |
    +-----------------------------------------------------------------+

  After ShowModal = mrOk, read the public Result property.
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  Classes,
  SysUtils,
  DateUtils,
  StrUtils,
  Forms,
  Controls,
  Graphics,
  StdCtrls,
  ExtCtrls,
  Grids,
  Buttons,
  Dialogs,
  mormot.core.base,
  Radium.Api.Types;

type
  { TNewPlanWizard }
  TNewPlanWizard = class(TForm)
  private
    // ── inputs from caller ──────────────────────────────────────
    FInitialCapability: TPlanCapability;
    FAttachedSessions:  TStatusSessionArray;

    // ── output ─────────────────────────────────────────────────
    FResult:            TPlanCreateRequest;

    // ── chrome ─────────────────────────────────────────────────
    FHeader:            TPanel;
      FStepDots:        TPanel;
      FStepLabel:       TLabel;
      FCardTitle:       TLabel;
      FCardSubtitle:    TLabel;
    FBody:              TPanel;
    FFooter:            TPanel;
      FBtnBack:         TButton;
      FBtnCancel:       TButton;
      FBtnNext:         TButton;

    FCurrentStep:       Integer;
    FStepPanels:        array[0..6] of TPanel;

    // ── step 1: bot ────────────────────────────────────────────
    FCmbBot:            TComboBox;
    FLblBotDesc:        TLabel;

    // ── step 2: session ────────────────────────────────────────
    FCmbInstance:       TComboBox;
    FLblBrokerVal:      TLabel;

    // ── step 3: markets ────────────────────────────────────────
    FEdtUnderlyings:    TEdit;
    FEdtLots:           TEdit;
    FCmbProduct:        TComboBox;
    FCmbUndExchange:    TComboBox;
    FCmbOptExchange:    TComboBox;

    // ── step 4: money ──────────────────────────────────────────
    FEdtMaxPremium:     TEdit;
    FEdtStrikeCount:    TEdit;
    FEdtMaxOpenLegs:    TEdit;
    FEdtMaxDailyLoss:   TEdit;
    FEdtMaxSymbolLoss:  TEdit;
    FChkDryRun:         TCheckBox;

    // ── step 5: time ───────────────────────────────────────────
    FEdtEntryStart:     TEdit;
    FEdtEntryEnd:       TEdit;
    FEdtCutoffTime:     TEdit;
    FEdtHardExit:       TEdit;
    FEdtMonitorUntil:   TEdit;
    FCmbOnExpire:       TComboBox;

    // ── step 6: tuning ─────────────────────────────────────────
    // shared (options-shaped, but gamma reuses SLPct/TPPct)
    FEdtSLPct:          TEdit;
    FEdtTPPct:          TEdit;
    FEdtTrailTrigger:   TEdit;
    FEdtTrailGiveBack:  TEdit;
    // gamma-only
    FLblGammaHeader:    TLabel;
    FCmbGammaMode:      TComboBox;
    FEdtVIXSell:        TEdit;
    FEdtVIXBuy:         TEdit;
    FChkExpiryOnly:     TCheckBox;
    // advanced grid
    FAdvHeader:         TLabel;
    FAdvHint:           TLabel;
    FAdvGrid:           TStringGrid;
    FBtnAdvAdd:         TButton;
    FBtnAdvDel:         TButton;

    // ── step 7: review ─────────────────────────────────────────
    FReviewMemo:        TMemo;

    procedure BuildHeader;
    procedure BuildFooter;
    procedure BuildStepBot;
    procedure BuildStepSession;
    procedure BuildStepMarkets;
    procedure BuildStepMoney;
    procedure BuildStepTime;
    procedure BuildStepTuning;
    procedure BuildStepReview;

    procedure ShowStep(AIndex: Integer);
    function  ValidateStep(AIndex: Integer; out AMsg: string): Boolean;
    procedure ApplyCapabilitySpecificVisibility;

    procedure DoBackClick(Sender: TObject);
    procedure DoNextClick(Sender: TObject);
    procedure DoCancelClick(Sender: TObject);
    procedure DoBotChange(Sender: TObject);
    procedure DoAdvAddClick(Sender: TObject);
    procedure DoAdvDelClick(Sender: TObject);

    function  CurrentCapability: TPlanCapability;
    function  SelectedSession: TStatusSession;

    // BuildResult — converts every form field into the typed
    // TPlanCreateRequest the caller submits. Called once on the final
    // "Create plan" click; doesn't mutate state on partial fills.
    procedure BuildResult;
    function  BuildReviewText: string;

    // SetSemanticHeader — the small grey "WHERE / WHAT / HOW MUCH"
    // section captions inside each step card. Plain-language overlay
    // on the wizard's bones.
    function MakeSectionHeader(AParent: TWinControl;
      const ACaption: string; ATop: Integer): TLabel;
    function MakeFieldLabel(AParent: TWinControl;
      const ACaption: string; ALeft, ATop: Integer): TLabel;
    function MakeFieldEdit(AParent: TWinControl;
      ALeft, ATop, AWidth: Integer; const AHint: string): TEdit;
    function MakeFieldCombo(AParent: TWinControl;
      ALeft, ATop, AWidth: Integer): TComboBox;
    function MakeHelperText(AParent: TWinControl;
      const ACaption: string; ALeft, ATop, AWidth: Integer): TLabel;
  public
    // Constructor — caller hands over the initial capability (chosen
    // from the Plans frame's "+ New plan" dropdown) and the list of
    // attached sessions (so the Session step can picker-pick one).
    constructor CreateWizard(AOwner: TComponent;
      ACapability: TPlanCapability;
      const ASessions: TStatusSessionArray);

    // Read after ShowModal = mrOk. Carries the entire plan submission
    // request as typed data — no JSON, no mORMot variants.
    property Result: TPlanCreateRequest read FResult;
  end;

implementation

uses
  Radium.Gui.Theme;

const
  WIZARD_WIDTH      = 740;
  WIZARD_HEIGHT     = 720;
  HEADER_HEIGHT     = 96;
  FOOTER_HEIGHT     = 64;
  STEP_COUNT        = 7;
  STEP_NAMES: array[0..STEP_COUNT-1] of string = (
    'Bot', 'Session', 'Markets', 'Money', 'Time', 'Tuning', 'Review');

type
  TStrArr = array of string;

// ── tiny helpers ────────────────────────────────────────────────────

// SafeStrToInt — returns ADefault when AText doesn't parse. Used
// throughout BuildResult so a blank field falls back to the engine's
// default rather than crashing the submit.
function SafeStrToInt(const AText: string; ADefault: Integer): Integer;
var v, code: Integer;
begin
  Val(Trim(AText), v, code);
  if code = 0 then result := v else result := ADefault;
end;

function SafeStrToFloat(const AText: string; ADefault: Double): Double;
var
  s: string;
  v: Double;
begin
  s := Trim(AText);
  if s = '' then begin result := ADefault; exit; end;
  // Accept '8000' or '8000.0'; locale-independent.
  if not TryStrToFloat(s, v, DefaultFormatSettings) then
    if not TryStrToFloat(StringReplace(s, ',', '.', [rfReplaceAll]),
                         v, DefaultFormatSettings) then
    begin
      result := ADefault;
      exit;
    end;
  result := v;
end;

// ParseUnderlyings — splits comma- / newline- / semicolon-separated
// symbols into a clean list. Trims and uppercases (NIFTY, banknifty
// → NIFTY, BANKNIFTY). Empty entries dropped.
function ParseUnderlyings(const AText: string): TStrArr;
var
  i: Integer;
  buf: string;
  procedure Flush;
  begin
    buf := Trim(buf);
    if buf <> '' then
    begin
      SetLength(result, Length(result) + 1);
      result[High(result)] := UpperCase(buf);
    end;
    buf := '';
  end;
begin
  result := nil;
  buf := '';
  for i := 1 to Length(AText) do
    case AText[i] of
      ',', ';', #10, #13: Flush;
    else
      buf := buf + AText[i];
    end;
  Flush;
end;

// ValidIstHHMM — '14:45' → true; '1445' / '14h45' → false. Helper text
// under each time field tells operators the format up front so this
// only fires on real typos.
function ValidIstHHMM(const AText: string): Boolean;
var
  s: string;
  hh, mm, code: Integer;
begin
  s := Trim(AText);
  if s = '' then begin result := True; exit; end;  // empty = unset
  result := False;
  if (Length(s) <> 5) or (s[3] <> ':') then exit;
  Val(Copy(s, 1, 2), hh, code);  if code <> 0 then exit;
  Val(Copy(s, 4, 2), mm, code);  if code <> 0 then exit;
  result := (hh >= 0) and (hh <= 23) and (mm >= 0) and (mm <= 59);
end;

// ParseHHMMToTodayUtc — 'HH:MM' (IST) + today's IST date → UTC. The
// engine deserialises monitor_until as time.Time and re-zones to IST
// internally, so the wire shape is just an absolute UTC instant. We
// compute today's IST date by taking UTC-now + 5:30, then snap to the
// requested HH:MM, then subtract 5:30 to land back in UTC.
function ParseHHMMToTodayUtc(const AHHMM: string; out AUtc: TDateTime): Boolean;
const
  IST_OFFSET_MIN = 330;
var
  hh, mm, code: Integer;
  utcNow, istNow, istCutoff: TDateTime;
begin
  result := False;
  AUtc := 0;
  if not ValidIstHHMM(AHHMM) or (Trim(AHHMM) = '') then exit;
  Val(Copy(AHHMM, 1, 2), hh, code); if code <> 0 then exit;
  Val(Copy(AHHMM, 4, 2), mm, code); if code <> 0 then exit;
  utcNow := LocalTimeToUniversal(Now);
  istNow := IncMinute(utcNow, IST_OFFSET_MIN);
  istCutoff := DateOf(istNow) + EncodeTime(hh, mm, 0, 0);
  AUtc := IncMinute(istCutoff, -IST_OFFSET_MIN);
  result := True;
end;

{ TNewPlanWizard ───────────────────────────────────────────────────── }

constructor TNewPlanWizard.CreateWizard(AOwner: TComponent;
  ACapability: TPlanCapability;
  const ASessions: TStatusSessionArray);
var
  i: Integer;
begin
  inherited CreateNew(AOwner);
  FInitialCapability := ACapability;
  SetLength(FAttachedSessions, Length(ASessions));
  for i := 0 to High(ASessions) do
    FAttachedSessions[i] := ASessions[i];

  BorderStyle  := bsDialog;
  Position     := poScreenCenter;
  Width        := WIZARD_WIDTH;
  Height       := WIZARD_HEIGHT;
  Caption      := 'New plan';

  BuildHeader;

  FBody := TPanel.Create(Self);
  FBody.Parent     := Self;
  FBody.Align      := alClient;
  FBody.BevelOuter := bvNone;
  FBody.Caption    := '';

  BuildFooter;

  // Build every step panel up front; ShowStep flips visibility so the
  // user sees one at a time. State persists when the user clicks Back.
  BuildStepBot;
  BuildStepSession;
  BuildStepMarkets;
  BuildStepMoney;
  BuildStepTime;
  BuildStepTuning;
  BuildStepReview;

  ApplyCapabilitySpecificVisibility;
  ShowStep(0);

  Radium.Gui.Theme.Apply(Self);
end;

procedure TNewPlanWizard.BuildHeader;
var
  i: Integer;
  dot: TShape;
begin
  FHeader := TPanel.Create(Self);
  FHeader.Parent     := Self;
  FHeader.Align      := alTop;
  FHeader.Height     := HEADER_HEIGHT;
  FHeader.BevelOuter := bvNone;
  FHeader.Caption    := '';

  // Step dot row — visual progress; updates as ShowStep moves. Each
  // dot is a small TShape; ShowStep paints them via SetSemantic.
  FStepDots := TPanel.Create(FHeader);
  FStepDots.Parent     := FHeader;
  FStepDots.Left       := 32;
  FStepDots.Top        := 16;
  FStepDots.Width      := 280;
  FStepDots.Height     := 14;
  FStepDots.BevelOuter := bvNone;
  FStepDots.Caption    := '';

  for i := 0 to STEP_COUNT - 1 do
  begin
    dot := TShape.Create(FStepDots);
    dot.Parent := FStepDots;
    dot.Left   := i * 32;
    dot.Top    := 0;
    dot.Width  := 12;
    dot.Height := 12;
    dot.Shape  := stCircle;
    dot.Tag    := i;     // index into STEP_NAMES; ShowStep reads this
    dot.Pen.Color := Token(tBorderStrong);
    dot.Brush.Color := Token(tBgCanvas);
  end;

  FStepLabel := TLabel.Create(FHeader);
  FStepLabel.Parent  := FHeader;
  FStepLabel.Left    := 340;
  FStepLabel.Top     := 18;
  FStepLabel.AutoSize := True;
  FStepLabel.Font.Height := -12;
  FStepLabel.ParentColor := True;
  FStepLabel.ParentFont  := False;
  SetSemantic(FStepLabel, skMuted);

  FCardTitle := TLabel.Create(FHeader);
  FCardTitle.Parent  := FHeader;
  FCardTitle.Left    := 32;
  FCardTitle.Top     := 42;
  FCardTitle.AutoSize := True;
  FCardTitle.Font.Height := -22;
  FCardTitle.Font.Style  := [fsBold];
  FCardTitle.ParentColor := True;
  FCardTitle.ParentFont  := False;
  SetSemantic(FCardTitle, skNeutral);

  FCardSubtitle := TLabel.Create(FHeader);
  FCardSubtitle.Parent  := FHeader;
  FCardSubtitle.Left    := 32;
  FCardSubtitle.Top     := 72;
  FCardSubtitle.AutoSize := False;
  FCardSubtitle.Width   := WIZARD_WIDTH - 64;
  FCardSubtitle.Height  := 18;
  FCardSubtitle.WordWrap := False;
  FCardSubtitle.Font.Height := -12;
  FCardSubtitle.ParentColor := True;
  FCardSubtitle.ParentFont  := False;
  SetSemantic(FCardSubtitle, skMuted);
end;

procedure TNewPlanWizard.BuildFooter;
begin
  FFooter := TPanel.Create(Self);
  FFooter.Parent     := Self;
  FFooter.Align      := alBottom;
  FFooter.Height     := FOOTER_HEIGHT;
  FFooter.BevelOuter := bvNone;
  FFooter.Caption    := '';

  FBtnBack := TButton.Create(FFooter);
  FBtnBack.Parent  := FFooter;
  FBtnBack.Left    := 32;
  FBtnBack.Top     := 14;
  FBtnBack.Width   := 100;
  FBtnBack.Height  := 36;
  FBtnBack.Caption := '< Back';
  FBtnBack.OnClick := DoBackClick;
  SetSemantic(FBtnBack, skNeutral);

  FBtnCancel := TButton.Create(FFooter);
  FBtnCancel.Parent  := FFooter;
  FBtnCancel.Left    := WIZARD_WIDTH - 250;
  FBtnCancel.Top     := 14;
  FBtnCancel.Width   := 100;
  FBtnCancel.Height  := 36;
  FBtnCancel.Caption := 'Cancel';
  FBtnCancel.OnClick := DoCancelClick;
  SetSemantic(FBtnCancel, skMuted);

  FBtnNext := TButton.Create(FFooter);
  FBtnNext.Parent  := FFooter;
  FBtnNext.Left    := WIZARD_WIDTH - 140;
  FBtnNext.Top     := 14;
  FBtnNext.Width   := 110;
  FBtnNext.Height  := 36;
  FBtnNext.Caption := 'Next >';
  FBtnNext.Default := True;
  FBtnNext.Font.Style := [fsBold];
  FBtnNext.OnClick := DoNextClick;
  SetSemantic(FBtnNext, skPrimary);
end;

{ ── small builders ─────────────────────────────────────────────────── }

function TNewPlanWizard.MakeSectionHeader(AParent: TWinControl;
  const ACaption: string; ATop: Integer): TLabel;
begin
  result := TLabel.Create(AParent);
  result.Parent  := AParent;
  result.Caption := UpperCase(ACaption);
  result.Left    := 16;
  result.Top     := ATop;
  result.AutoSize := True;
  result.Font.Height := -10;
  result.Font.Style  := [fsBold];
  result.ParentColor := True;
  result.ParentFont  := False;
  SetSemantic(result, skMuted);
end;

function TNewPlanWizard.MakeFieldLabel(AParent: TWinControl;
  const ACaption: string; ALeft, ATop: Integer): TLabel;
begin
  result := TLabel.Create(AParent);
  result.Parent  := AParent;
  result.Caption := ACaption;
  result.Left    := ALeft;
  result.Top     := ATop;
  result.AutoSize := True;
  result.Font.Height := -12;
  result.Font.Style  := [fsBold];
  result.ParentColor := True;
  result.ParentFont  := False;
  SetSemantic(result, skNeutral);
end;

function TNewPlanWizard.MakeFieldEdit(AParent: TWinControl;
  ALeft, ATop, AWidth: Integer; const AHint: string): TEdit;
begin
  result := TEdit.Create(AParent);
  result.Parent := AParent;
  result.Left   := ALeft;
  result.Top    := ATop;
  result.Width  := AWidth;
  result.Height := 28;
  if AHint <> '' then
    result.TextHint := AHint;
end;

function TNewPlanWizard.MakeFieldCombo(AParent: TWinControl;
  ALeft, ATop, AWidth: Integer): TComboBox;
begin
  result := TComboBox.Create(AParent);
  result.Parent := AParent;
  result.Left   := ALeft;
  result.Top    := ATop;
  result.Width  := AWidth;
  result.Height := 28;
  result.Style  := csDropDownList;
end;

function TNewPlanWizard.MakeHelperText(AParent: TWinControl;
  const ACaption: string; ALeft, ATop, AWidth: Integer): TLabel;
begin
  result := TLabel.Create(AParent);
  result.Parent  := AParent;
  result.Caption := ACaption;
  result.Left    := ALeft;
  result.Top     := ATop;
  result.Width   := AWidth;
  result.AutoSize := False;
  result.Height  := 30;
  result.WordWrap := True;
  result.Font.Height := -11;
  result.ParentColor := True;
  result.ParentFont  := False;
  SetSemantic(result, skMuted);
end;

{ ── step builders ──────────────────────────────────────────────────── }

procedure TNewPlanWizard.BuildStepBot;
var
  panel: TPanel;
  i: Integer;
  cat: TPlanCapabilityInfoArray;
begin
  panel := TPanel.Create(FBody);
  panel.Parent     := FBody;
  panel.Align      := alClient;
  panel.BevelOuter := bvNone;
  panel.Caption    := '';
  panel.Visible    := False;
  FStepPanels[0] := panel;

  MakeSectionHeader(panel, 'Choose a bot', 16);

  MakeFieldLabel(panel, 'Bot', 16, 44);
  FCmbBot := MakeFieldCombo(panel, 16, 64, 280);
  cat := PlanCapabilityCatalog;
  for i := 0 to High(cat) do
    FCmbBot.Items.Add(cat[i].Title);
  FCmbBot.ItemIndex := Ord(FInitialCapability);
  FCmbBot.OnChange := DoBotChange;

  FLblBotDesc := TLabel.Create(panel);
  FLblBotDesc.Parent := panel;
  FLblBotDesc.Left   := 16;
  FLblBotDesc.Top    := 110;
  FLblBotDesc.Width  := WIZARD_WIDTH - 80;
  FLblBotDesc.Height := 80;
  FLblBotDesc.AutoSize := False;
  FLblBotDesc.WordWrap := True;
  FLblBotDesc.Font.Height := -13;
  FLblBotDesc.ParentColor := True;
  FLblBotDesc.ParentFont  := False;
  SetSemantic(FLblBotDesc, skNeutral);
  // Initial caption set by DoBotChange via ShowStep.
end;

procedure TNewPlanWizard.BuildStepSession;
var
  panel: TPanel;
  i: Integer;
begin
  panel := TPanel.Create(FBody);
  panel.Parent     := FBody;
  panel.Align      := alClient;
  panel.BevelOuter := bvNone;
  panel.Caption    := '';
  panel.Visible    := False;
  FStepPanels[1] := panel;

  MakeSectionHeader(panel, 'Where', 16);

  MakeFieldLabel(panel, 'Broker session', 16, 44);
  FCmbInstance := MakeFieldCombo(panel, 16, 64, 280);
  for i := 0 to High(FAttachedSessions) do
    FCmbInstance.Items.Add(
      Format('%s  (%s)',
        [string(FAttachedSessions[i].InstanceId),
         string(FAttachedSessions[i].Broker)]));
  if Length(FAttachedSessions) > 0 then
    FCmbInstance.ItemIndex := 0;
  FCmbInstance.OnChange := DoBotChange; // shared rebind so broker label refreshes

  MakeFieldLabel(panel, 'Broker', 320, 44);
  FLblBrokerVal := TLabel.Create(panel);
  FLblBrokerVal.Parent := panel;
  FLblBrokerVal.Left   := 320;
  FLblBrokerVal.Top    := 68;
  FLblBrokerVal.AutoSize := True;
  FLblBrokerVal.Caption  := '-';
  FLblBrokerVal.Font.Height := -13;
  FLblBrokerVal.ParentColor := True;
  FLblBrokerVal.ParentFont  := False;
  SetSemantic(FLblBrokerVal, skPrimary);

  MakeHelperText(panel,
    'The bot trades through this broker session. Plans are scoped to ' +
    'one session — to run the same plan against another broker, attach ' +
    'that broker first and create a new plan there.',
    16, 110, WIZARD_WIDTH - 80);
end;

procedure TNewPlanWizard.BuildStepMarkets;
var
  panel: TPanel;
begin
  panel := TPanel.Create(FBody);
  panel.Parent     := FBody;
  panel.Align      := alClient;
  panel.BevelOuter := bvNone;
  panel.Caption    := '';
  panel.Visible    := False;
  FStepPanels[2] := panel;

  MakeSectionHeader(panel, 'What to trade', 16);

  MakeFieldLabel(panel, 'Underlyings', 16, 44);
  FEdtUnderlyings := MakeFieldEdit(panel, 16, 64, WIZARD_WIDTH - 80,
    'NIFTY, BANKNIFTY');
  MakeHelperText(panel,
    'Comma-separated. The bot manages each underlying as its own basket. ' +
    'Index names work today; equity tickers when the engine grows there.',
    16, 96, WIZARD_WIDTH - 80);

  MakeFieldLabel(panel, 'Lots per leg', 16, 150);
  FEdtLots := MakeFieldEdit(panel, 16, 170, 100, '');
  FEdtLots.Text := '1';
  MakeHelperText(panel,
    '1 lot = NIFTY 75 / BANKNIFTY 35 contracts. Test with 1 first.',
    16, 200, 280);

  MakeFieldLabel(panel, 'Product', 200, 150);
  FCmbProduct := MakeFieldCombo(panel, 200, 170, 140);
  FCmbProduct.Items.Add('MIS  (intraday)');
  FCmbProduct.Items.Add('NRML (carry)');
  FCmbProduct.ItemIndex := 0;

  MakeFieldLabel(panel, 'Underlying exchange', 16, 250);
  FCmbUndExchange := MakeFieldCombo(panel, 16, 270, 200);
  FCmbUndExchange.Items.Add('NSE_INDEX');
  FCmbUndExchange.Items.Add('NSE');
  FCmbUndExchange.Items.Add('BSE');
  FCmbUndExchange.ItemIndex := 0;

  MakeFieldLabel(panel, 'Options exchange', 240, 250);
  FCmbOptExchange := MakeFieldCombo(panel, 240, 270, 160);
  FCmbOptExchange.Items.Add('NFO');
  FCmbOptExchange.Items.Add('BFO');
  FCmbOptExchange.ItemIndex := 0;

  MakeHelperText(panel,
    'Index options live on NFO (NSE F&O) for NIFTY/BANKNIFTY and BFO ' +
    '(BSE F&O) for SENSEX. The bot picks specific strikes; you only ' +
    'tell it where to look.',
    16, 310, WIZARD_WIDTH - 80);
end;

procedure TNewPlanWizard.BuildStepMoney;
var
  panel: TPanel;
begin
  panel := TPanel.Create(FBody);
  panel.Parent     := FBody;
  panel.Align      := alClient;
  panel.BevelOuter := bvNone;
  panel.Caption    := '';
  panel.Visible    := False;
  FStepPanels[3] := panel;

  MakeSectionHeader(panel, 'How much', 16);

  MakeFieldLabel(panel, 'Max premium per leg (₹)', 16, 44);
  FEdtMaxPremium := MakeFieldEdit(panel, 16, 64, 160, '8000');
  FEdtMaxPremium.Text := '8000';

  MakeFieldLabel(panel, 'Strikes per side', 200, 44);
  FEdtStrikeCount := MakeFieldEdit(panel, 200, 64, 100, '5');
  FEdtStrikeCount.Text := '5';

  MakeFieldLabel(panel, 'Max open legs', 320, 44);
  FEdtMaxOpenLegs := MakeFieldEdit(panel, 320, 64, 100, '4');
  FEdtMaxOpenLegs.Text := '4';

  MakeHelperText(panel,
    'Premium cap is the most you''re willing to pay (or collect) per leg. ' +
    'Strikes-per-side is how many strikes either side of spot the bot can ' +
    'evaluate. Max open legs caps total live structures across all underlyings.',
    16, 100, WIZARD_WIDTH - 80);

  MakeSectionHeader(panel, 'Loss caps', 160);

  MakeFieldLabel(panel, 'Max daily loss (₹)', 16, 188);
  FEdtMaxDailyLoss := MakeFieldEdit(panel, 16, 208, 160, 'optional');

  MakeFieldLabel(panel, 'Max symbol loss (₹)', 200, 188);
  FEdtMaxSymbolLoss := MakeFieldEdit(panel, 200, 208, 160, 'optional');

  MakeHelperText(panel,
    'Leave blank to inherit the instance-level caps from /admin/risk. ' +
    'Daily loss flattens everything when breached; symbol loss blocks ' +
    'further entries on that underlying.',
    16, 244, WIZARD_WIDTH - 80);

  FChkDryRun := TCheckBox.Create(panel);
  FChkDryRun.Parent  := panel;
  FChkDryRun.Left    := 16;
  FChkDryRun.Top     := 300;
  FChkDryRun.Width   := WIZARD_WIDTH - 80;
  FChkDryRun.Caption := 'Dry run  (paper trade only — no orders sent to the broker)';
  FChkDryRun.Checked := True;  // safer default; operator opts in to live
  FChkDryRun.Font.Style := [fsBold];
  FChkDryRun.ParentFont := False;

  MakeHelperText(panel,
    'Dry run logs every decision the bot would make without placing real ' +
    'orders. Recommended for the first run of any new plan.',
    16, 326, WIZARD_WIDTH - 80);
end;

procedure TNewPlanWizard.BuildStepTime;
var
  panel: TPanel;
begin
  panel := TPanel.Create(FBody);
  panel.Parent     := FBody;
  panel.Align      := alClient;
  panel.BevelOuter := bvNone;
  panel.Caption    := '';
  panel.Visible    := False;
  FStepPanels[4] := panel;

  MakeSectionHeader(panel, 'Trading window', 16);

  MakeFieldLabel(panel, 'Earliest entry (IST)', 16, 44);
  FEdtEntryStart := MakeFieldEdit(panel, 16, 64, 100, 'HH:MM');

  MakeFieldLabel(panel, 'Latest entry (IST)', 140, 44);
  FEdtEntryEnd := MakeFieldEdit(panel, 140, 64, 100, 'HH:MM');

  MakeHelperText(panel,
    'New entries fire only inside this window. Leave blank for no floor / ceiling.',
    16, 96, WIZARD_WIDTH - 80);

  MakeSectionHeader(panel, 'Stop & close', 140);

  MakeFieldLabel(panel, 'Stop entries after (IST)', 16, 168);
  FEdtCutoffTime := MakeFieldEdit(panel, 16, 188, 100, '14:45');
  FEdtCutoffTime.Text := '14:45';

  MakeFieldLabel(panel, 'Hard exit at (IST)', 160, 168);
  FEdtHardExit := MakeFieldEdit(panel, 160, 188, 100, '15:15');
  FEdtHardExit.Text := '15:15';

  MakeFieldLabel(panel, 'Monitor until (IST)', 304, 168);
  FEdtMonitorUntil := MakeFieldEdit(panel, 304, 188, 100, '15:25');

  MakeHelperText(panel,
    'After "stop entries" the bot won''t open new positions but will manage ' +
    'live ones. "Hard exit" closes everything unconditionally. "Monitor until" ' +
    'is when the plan stops being managed at all (defaults to end-of-day).',
    16, 224, WIZARD_WIDTH - 80);

  MakeFieldLabel(panel, 'When monitor ends', 16, 290);
  FCmbOnExpire := MakeFieldCombo(panel, 16, 310, 220);
  FCmbOnExpire.Items.Add('Flatten — close everything');
  FCmbOnExpire.Items.Add('Drain — let SL/TP run');
  FCmbOnExpire.Items.Add('Detach — operator owns positions');
  FCmbOnExpire.ItemIndex := 0;

  MakeHelperText(panel,
    'Most-conservative default is Flatten. Drain is for when you want SL/TP ' +
    'to take care of exits. Detach hands positions back to you.',
    16, 346, WIZARD_WIDTH - 80);
end;

procedure TNewPlanWizard.BuildStepTuning;
var
  panel: TPanel;
  optTop: Integer;
begin
  panel := TPanel.Create(FBody);
  panel.Parent     := FBody;
  panel.Align      := alClient;
  panel.BevelOuter := bvNone;
  panel.Caption    := '';
  panel.Visible    := False;
  FStepPanels[5] := panel;

  // ── shared exits (both bots use SL/TP) ───────────────────────
  MakeSectionHeader(panel, 'Per-leg exits', 8);

  MakeFieldLabel(panel, 'Stop loss (%)', 16, 36);
  FEdtSLPct := MakeFieldEdit(panel, 16, 56, 100, '30');

  MakeFieldLabel(panel, 'Take profit (%)', 140, 36);
  FEdtTPPct := MakeFieldEdit(panel, 140, 56, 100, '60');

  MakeFieldLabel(panel, 'Trail trigger (%)', 264, 36);
  FEdtTrailTrigger := MakeFieldEdit(panel, 264, 56, 100, 'optional');

  MakeFieldLabel(panel, 'Trail give-back (%)', 388, 36);
  FEdtTrailGiveBack := MakeFieldEdit(panel, 388, 56, 100, 'optional');

  MakeHelperText(panel,
    'SL / TP are percentages of entry premium per leg. Trailing kicks in ' +
    'once the leg hits "trigger" gain, then exits if it gives back "give-back" ' +
    'from the high.',
    16, 90, WIZARD_WIDTH - 80);

  // ── gamma-only knobs ────────────────────────────────────────
  optTop := 140;

  FLblGammaHeader := MakeSectionHeader(panel, 'Gamma rules', optTop);

  MakeFieldLabel(panel, 'Strategy mode', 16, optTop + 28);
  FCmbGammaMode := MakeFieldCombo(panel, 16, optTop + 48, 220);
  FCmbGammaMode.Items.Add('Auto — VIX-gated');
  FCmbGammaMode.Items.Add('Sell only — short straddle');
  FCmbGammaMode.Items.Add('Buy only — long straddle');
  FCmbGammaMode.ItemIndex := 0;

  MakeFieldLabel(panel, 'VIX sell ceiling', 260, optTop + 28);
  FEdtVIXSell := MakeFieldEdit(panel, 260, optTop + 48, 100, '14.00');
  FEdtVIXSell.Text := '14.00';

  MakeFieldLabel(panel, 'VIX buy floor', 384, optTop + 28);
  FEdtVIXBuy := MakeFieldEdit(panel, 384, optTop + 48, 100, '22.00');
  FEdtVIXBuy.Text := '22.00';

  FChkExpiryOnly := TCheckBox.Create(panel);
  FChkExpiryOnly.Parent  := panel;
  FChkExpiryOnly.Left    := 16;
  FChkExpiryOnly.Top     := optTop + 90;
  FChkExpiryOnly.Width   := WIZARD_WIDTH - 80;
  FChkExpiryOnly.Caption := 'Trade on expiry day only';
  FChkExpiryOnly.Checked := True;

  MakeHelperText(panel,
    'Auto sells short straddles when VIX is below the ceiling, buys long ' +
    'straddles above the floor, and stays flat between. Expiry-only is the ' +
    'safest gamma scalper default.',
    16, optTop + 116, WIZARD_WIDTH - 80);

  // ── advanced KV grid (shared) ────────────────────────────────
  FAdvHeader := MakeSectionHeader(panel, 'Advanced parameters', optTop + 170);

  FAdvHint := MakeHelperText(panel,
    'Drop in any extra knob the bot reads from its params bag (decision_every, ' +
    'cooldown, expiry_offset, force_strategy, …). Most operators leave this empty.',
    16, optTop + 198, WIZARD_WIDTH - 80);

  FAdvGrid := TStringGrid.Create(panel);
  FAdvGrid.Parent     := panel;
  FAdvGrid.Left       := 16;
  FAdvGrid.Top        := optTop + 234;
  FAdvGrid.Width      := WIZARD_WIDTH - 240;
  FAdvGrid.Height     := 100;
  FAdvGrid.RowCount   := 1;
  FAdvGrid.ColCount   := 2;
  FAdvGrid.FixedRows  := 1;
  FAdvGrid.FixedCols  := 0;
  FAdvGrid.ColWidths[0] := 220;
  FAdvGrid.ColWidths[1] := 200;
  FAdvGrid.Cells[0, 0] := 'Key';
  FAdvGrid.Cells[1, 0] := 'Value';
  FAdvGrid.Options := FAdvGrid.Options + [goEditing, goTabs];

  FBtnAdvAdd := TButton.Create(panel);
  FBtnAdvAdd.Parent  := panel;
  FBtnAdvAdd.Left    := WIZARD_WIDTH - 200;
  FBtnAdvAdd.Top     := optTop + 234;
  FBtnAdvAdd.Width   := 110;
  FBtnAdvAdd.Height  := 28;
  FBtnAdvAdd.Caption := '+ Add row';
  FBtnAdvAdd.OnClick := DoAdvAddClick;
  SetSemantic(FBtnAdvAdd, skNeutral);

  FBtnAdvDel := TButton.Create(panel);
  FBtnAdvDel.Parent  := panel;
  FBtnAdvDel.Left    := WIZARD_WIDTH - 200;
  FBtnAdvDel.Top     := optTop + 268;
  FBtnAdvDel.Width   := 110;
  FBtnAdvDel.Height  := 28;
  FBtnAdvDel.Caption := 'Remove row';
  FBtnAdvDel.OnClick := DoAdvDelClick;
  SetSemantic(FBtnAdvDel, skMuted);
end;

procedure TNewPlanWizard.BuildStepReview;
var
  panel: TPanel;
begin
  panel := TPanel.Create(FBody);
  panel.Parent     := FBody;
  panel.Align      := alClient;
  panel.BevelOuter := bvNone;
  panel.Caption    := '';
  panel.Visible    := False;
  FStepPanels[6] := panel;

  MakeSectionHeader(panel, 'Review', 16);

  FReviewMemo := TMemo.Create(panel);
  FReviewMemo.Parent     := panel;
  FReviewMemo.Left       := 16;
  FReviewMemo.Top        := 44;
  FReviewMemo.Width      := WIZARD_WIDTH - 80;
  FReviewMemo.Height     := 360;
  FReviewMemo.ReadOnly   := True;
  FReviewMemo.Font.Name  := 'Menlo';
  FReviewMemo.Font.Height := -12;
  FReviewMemo.ParentFont := False;
  FReviewMemo.ScrollBars := ssAutoVertical;
end;

{ ── lifecycle / step plumbing ──────────────────────────────────────── }

procedure TNewPlanWizard.ApplyCapabilitySpecificVisibility;
var
  isGamma: Boolean;
begin
  isGamma := CurrentCapability = pcGammaScalper;
  // Gamma-specific block is only meaningful for the gamma capability.
  if FLblGammaHeader <> nil then FLblGammaHeader.Visible := isGamma;
  if FCmbGammaMode <> nil  then FCmbGammaMode.Visible  := isGamma;
  if FEdtVIXSell <> nil    then FEdtVIXSell.Visible    := isGamma;
  if FEdtVIXBuy <> nil     then FEdtVIXBuy.Visible     := isGamma;
  if FChkExpiryOnly <> nil then FChkExpiryOnly.Visible := isGamma;
end;

procedure TNewPlanWizard.ShowStep(AIndex: Integer);
var
  i: Integer;
  cat: TPlanCapabilityInfoArray;
  cap: TPlanCapability;
  s: string;
  dot: TShape;
begin
  if (AIndex < 0) or (AIndex > High(FStepPanels)) then exit;
  FCurrentStep := AIndex;

  for i := 0 to High(FStepPanels) do
    FStepPanels[i].Visible := (i = AIndex);

  // Step dots — past = primary, current = primary outlined, future = subtle.
  for i := 0 to FStepDots.ControlCount - 1 do
    if FStepDots.Controls[i] is TShape then
    begin
      dot := TShape(FStepDots.Controls[i]);
      if dot.Tag < AIndex then
        dot.Brush.Color := Token(tAccentPrimary)
      else if dot.Tag = AIndex then
        dot.Brush.Color := Token(tAccentPrimary)
      else
        dot.Brush.Color := Token(tBgCanvas);
      dot.Pen.Color := Token(tAccentPrimary);
    end;

  FStepLabel.Caption := Format('Step %d of %d  ·  %s',
    [AIndex + 1, STEP_COUNT, STEP_NAMES[AIndex]]);

  cap := CurrentCapability;
  cat := PlanCapabilityCatalog;

  case AIndex of
    0:
      begin
        FCardTitle.Caption    := 'Choose a bot';
        FCardSubtitle.Caption := 'Pick which bot drives this plan. ' +
                                 'Each bot has its own playbook.';
        if (FCmbBot.ItemIndex >= 0) and (FCmbBot.ItemIndex <= High(cat)) then
          FLblBotDesc.Caption := cat[FCmbBot.ItemIndex].OneLine;
      end;
    1:
      begin
        FCardTitle.Caption    := 'Pick a session';
        FCardSubtitle.Caption := 'Which broker session should run this plan?';
        if (FCmbInstance.ItemIndex >= 0) and
           (FCmbInstance.ItemIndex <= High(FAttachedSessions)) then
          FLblBrokerVal.Caption :=
            string(FAttachedSessions[FCmbInstance.ItemIndex].Broker);
      end;
    2:
      begin
        FCardTitle.Caption    := 'What to trade';
        FCardSubtitle.Caption :=
          'Tell the bot which underlyings to watch and how big each leg is.';
      end;
    3:
      begin
        FCardTitle.Caption    := 'How much money';
        FCardSubtitle.Caption :=
          'Set the per-leg, per-symbol, and per-day spend limits.';
      end;
    4:
      begin
        FCardTitle.Caption    := 'When to trade';
        FCardSubtitle.Caption :=
          'Window your bot to market hours that match the strategy.';
      end;
    5:
      begin
        FCardTitle.Caption    := 'Tuning';
        if cap = pcGammaScalper then
          FCardSubtitle.Caption :=
            'Per-leg exits + gamma-specific rules. ' +
            'Most operators take the defaults.'
        else
          FCardSubtitle.Caption :=
            'Per-leg exits + advanced parameters. Defaults work for most.';
        ApplyCapabilitySpecificVisibility;
      end;
    6:
      begin
        FCardTitle.Caption    := 'Review';
        FCardSubtitle.Caption := 'Confirm what you''re about to start.';
        s := BuildReviewText;
        FReviewMemo.Text := s;
      end;
  end;

  // Footer button states.
  FBtnBack.Visible := AIndex > 0;
  if AIndex = High(FStepPanels) then
    FBtnNext.Caption := 'Create plan'
  else
    FBtnNext.Caption := 'Next >';
end;

function TNewPlanWizard.CurrentCapability: TPlanCapability;
begin
  // FCmbBot might not exist on the first ApplyCapabilitySpecificVisibility
  // call (during construction); fall back to the initial value then.
  if (FCmbBot = nil) or (FCmbBot.ItemIndex < 0) then
    result := FInitialCapability
  else
    result := TPlanCapability(FCmbBot.ItemIndex);
end;

function TNewPlanWizard.SelectedSession: TStatusSession;
var
  idx: Integer;
begin
  FillChar(result, SizeOf(result), 0);
  if FCmbInstance = nil then exit;
  idx := FCmbInstance.ItemIndex;
  if (idx < 0) or (idx > High(FAttachedSessions)) then exit;
  result := FAttachedSessions[idx];
end;

function TNewPlanWizard.ValidateStep(AIndex: Integer; out AMsg: string): Boolean;
var
  unders: TStrArr;
begin
  result := False;
  AMsg := '';
  case AIndex of
    1:
      begin
        if Length(FAttachedSessions) = 0 then
          AMsg := 'No broker sessions attached. Attach a broker first ' +
                  'from the Broker Sessions panel.'
        else if FCmbInstance.ItemIndex < 0 then
          AMsg := 'Pick a broker session.';
      end;
    2:
      begin
        unders := ParseUnderlyings(FEdtUnderlyings.Text);
        if Length(unders) = 0 then
          AMsg := 'Enter at least one underlying (e.g. NIFTY).'
        else if SafeStrToInt(FEdtLots.Text, 0) < 1 then
          AMsg := 'Lots per leg must be 1 or more.';
      end;
    3:
      begin
        if SafeStrToFloat(FEdtMaxPremium.Text, 0) <= 0 then
          AMsg := 'Max premium per leg must be greater than 0.';
      end;
    4:
      begin
        if not ValidIstHHMM(FEdtEntryStart.Text) then
          AMsg := 'Earliest entry must be in HH:MM 24-hour format.'
        else if not ValidIstHHMM(FEdtEntryEnd.Text) then
          AMsg := 'Latest entry must be in HH:MM 24-hour format.'
        else if not ValidIstHHMM(FEdtCutoffTime.Text) then
          AMsg := 'Stop-entries-after must be in HH:MM 24-hour format.'
        else if not ValidIstHHMM(FEdtHardExit.Text) then
          AMsg := 'Hard exit must be in HH:MM 24-hour format.'
        else if not ValidIstHHMM(FEdtMonitorUntil.Text) then
          AMsg := 'Monitor-until must be in HH:MM 24-hour format.';
      end;
  end;
  result := AMsg = '';
end;

procedure TNewPlanWizard.DoBackClick(Sender: TObject);
begin
  if FCurrentStep > 0 then
    ShowStep(FCurrentStep - 1);
end;

procedure TNewPlanWizard.DoNextClick(Sender: TObject);
var
  msg: string;
begin
  if not ValidateStep(FCurrentStep, msg) then
  begin
    ShowMessage(msg);
    exit;
  end;
  if FCurrentStep < High(FStepPanels) then
  begin
    ShowStep(FCurrentStep + 1);
    exit;
  end;
  // Last step: build result and close.
  BuildResult;
  ModalResult := mrOk;
end;

procedure TNewPlanWizard.DoCancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

procedure TNewPlanWizard.DoBotChange(Sender: TObject);
var
  cat: TPlanCapabilityInfoArray;
begin
  cat := PlanCapabilityCatalog;
  if (Sender = FCmbBot) and (FLblBotDesc <> nil) and
     (FCmbBot.ItemIndex >= 0) and (FCmbBot.ItemIndex <= High(cat)) then
    FLblBotDesc.Caption := cat[FCmbBot.ItemIndex].OneLine;

  if (Sender = FCmbInstance) and (FLblBrokerVal <> nil) and
     (FCmbInstance.ItemIndex >= 0) and
     (FCmbInstance.ItemIndex <= High(FAttachedSessions)) then
    FLblBrokerVal.Caption :=
      string(FAttachedSessions[FCmbInstance.ItemIndex].Broker);

  ApplyCapabilitySpecificVisibility;
end;

procedure TNewPlanWizard.DoAdvAddClick(Sender: TObject);
begin
  FAdvGrid.RowCount := FAdvGrid.RowCount + 1;
  FAdvGrid.Row := FAdvGrid.RowCount - 1;
  FAdvGrid.Col := 0;
end;

procedure TNewPlanWizard.DoAdvDelClick(Sender: TObject);
begin
  if FAdvGrid.Row >= FAdvGrid.FixedRows then
  begin
    FAdvGrid.DeleteRow(FAdvGrid.Row);
    if FAdvGrid.RowCount = FAdvGrid.FixedRows then
      // Keep one editable row visible so the grid never reads as empty
      // (which the user might mistake for "advanced is broken").
      FAdvGrid.RowCount := FAdvGrid.FixedRows + 1;
  end;
end;

{ ── result + review ────────────────────────────────────────────────── }

procedure TNewPlanWizard.BuildResult;
var
  unders: TStrArr;
  i: Integer;
  ses: TStatusSession;
  premium, sl, tp, trailT, trailG, vixSell, vixBuy: Double;
  monitorUtc: TDateTime;
  optExch, undExch, productWire: RawUtf8;
  k, v: string;

  procedure AddParam(const AKey: RawUtf8; AKind: TPlanParamKind;
    const AStrVal: RawUtf8; AIntVal: Int64; AFltVal: Double; ABoolVal: Boolean);
  var n: Integer;
  begin
    n := Length(FResult.Params);
    SetLength(FResult.Params, n + 1);
    FResult.Params[n].Key := AKey;
    FResult.Params[n].Kind := AKind;
    FResult.Params[n].AsStr := AStrVal;
    FResult.Params[n].AsInt := AIntVal;
    FResult.Params[n].AsFlt := AFltVal;
    FResult.Params[n].AsBool := ABoolVal;
  end;

  procedure AddStrParam(const AKey, AVal: RawUtf8);
  begin AddParam(AKey, kPkString, AVal, 0, 0.0, False); end;
  procedure AddIntParam(const AKey: RawUtf8; AVal: Int64);
  begin AddParam(AKey, kPkInt, '', AVal, 0.0, False); end;
  procedure AddFloatParam(const AKey: RawUtf8; AVal: Double);
  begin AddParam(AKey, kPkFloat, '', 0, AVal, False); end;
  procedure AddBoolParam(const AKey: RawUtf8; AVal: Boolean);
  begin AddParam(AKey, kPkBool, '', 0, 0.0, AVal); end;

  function ProductWireFromCombo: RawUtf8;
  begin
    case FCmbProduct.ItemIndex of
      0: result := 'MIS';
      1: result := 'NRML';
    else
      result := 'MIS';
    end;
  end;

  function OnExpireWireFromCombo: RawUtf8;
  begin
    case FCmbOnExpire.ItemIndex of
      0: result := 'flatten';
      1: result := 'drain';
      2: result := 'detach';
    else
      result := 'flatten';
    end;
  end;

begin
  FillChar(FResult, SizeOf(FResult), 0);
  ses := SelectedSession;
  FResult.InstanceId := ses.InstanceId;
  FResult.Broker     := ses.Broker;
  FResult.Capability := CurrentCapability;

  unders := ParseUnderlyings(FEdtUnderlyings.Text);
  productWire := ProductWireFromCombo;
  undExch := RawUtf8(FCmbUndExchange.Text);

  SetLength(FResult.Instruments, Length(unders));
  for i := 0 to High(unders) do
  begin
    FResult.Instruments[i].InstrumentType := 'options_underlying';
    FResult.Instruments[i].Symbol         := RawUtf8(unders[i]);
    FResult.Instruments[i].Exchange       := undExch;
    FResult.Instruments[i].Lots           := SafeStrToInt(FEdtLots.Text, 1);
    FResult.Instruments[i].Qty            := 0;
    FResult.Instruments[i].Product        := productWire;
  end;

  // ── risk caps ────────────────────────────────────────────────
  if Trim(FEdtMaxDailyLoss.Text) <> '' then
  begin
    FResult.Risk.MaxDailyLoss := SafeStrToFloat(FEdtMaxDailyLoss.Text, 0);
    FResult.Risk.HasMaxDailyLoss := True;
  end;
  if Trim(FEdtMaxSymbolLoss.Text) <> '' then
  begin
    FResult.Risk.MaxSymbolLoss := SafeStrToFloat(FEdtMaxSymbolLoss.Text, 0);
    FResult.Risk.HasMaxSymbolLoss := True;
  end;
  if Trim(FEdtCutoffTime.Text) <> '' then
  begin
    FResult.Risk.CutoffTime := RawUtf8(Trim(FEdtCutoffTime.Text));
    FResult.Risk.HasCutoffTime := True;
  end;

  // ── validity ─────────────────────────────────────────────────
  FResult.Validity.EntryStartHHMM := RawUtf8(Trim(FEdtEntryStart.Text));
  FResult.Validity.EntryEndHHMM   := RawUtf8(Trim(FEdtEntryEnd.Text));
  FResult.Validity.OnExpire       := OnExpireWireFromCombo;

  if ParseHHMMToTodayUtc(FEdtMonitorUntil.Text, monitorUtc) then
  begin
    FResult.Validity.HasMonitorUntil := True;
    FResult.Validity.MonitorUntilUtc := monitorUtc;
  end;

  // ── params bag (typed knobs the form surfaces) ──────────────
  // Common bot knobs first.
  premium := SafeStrToFloat(FEdtMaxPremium.Text, 8000);
  AddFloatParam('max_premium', premium);
  AddIntParam  ('strike_count',   SafeStrToInt(FEdtStrikeCount.Text, 5));
  AddIntParam  ('max_open_legs',  SafeStrToInt(FEdtMaxOpenLegs.Text, 4));
  AddBoolParam ('dry_run',        FChkDryRun.Checked);

  optExch := RawUtf8(FCmbOptExchange.Text);
  if optExch <> '' then
    AddStrParam('options_exchange', optExch);

  if Trim(FEdtHardExit.Text) <> '' then
    AddStrParam('hard_exit_time', RawUtf8(Trim(FEdtHardExit.Text)));

  if Trim(FEdtCutoffTime.Text) <> '' then
    AddStrParam('entry_cutoff', RawUtf8(Trim(FEdtCutoffTime.Text)));

  // Per-leg exits.
  sl := SafeStrToFloat(FEdtSLPct.Text, 0);
  if sl > 0 then AddFloatParam('sl_pct', sl);
  tp := SafeStrToFloat(FEdtTPPct.Text, 0);
  if tp > 0 then AddFloatParam('tp_pct', tp);
  trailT := SafeStrToFloat(FEdtTrailTrigger.Text, 0);
  if trailT > 0 then AddFloatParam('trail_trigger_pct', trailT);
  trailG := SafeStrToFloat(FEdtTrailGiveBack.Text, 0);
  if trailG > 0 then AddFloatParam('trail_give_back_pct', trailG);

  // Capability-specific knobs.
  if CurrentCapability = pcGammaScalper then
  begin
    case FCmbGammaMode.ItemIndex of
      1: AddBoolParam('gamma_allow_buy', False);  // sell-only
      2:
        begin
          // buy-only is encoded as allow_buy=true + force_strategy hint
          AddBoolParam('gamma_allow_buy', True);
          AddStrParam('force_strategy', 'long_straddle');
        end;
    else
      AddBoolParam('gamma_allow_buy', True);  // auto: VIX gates
    end;

    vixSell := SafeStrToFloat(FEdtVIXSell.Text, 0);
    if vixSell > 0 then AddFloatParam('gamma_vix_sell', vixSell);
    vixBuy := SafeStrToFloat(FEdtVIXBuy.Text, 0);
    if vixBuy > 0 then AddFloatParam('gamma_vix_buy', vixBuy);
    AddBoolParam('expiry_only', FChkExpiryOnly.Checked);
  end;

  // ── advanced free-form rows ─────────────────────────────────
  // Treat every advanced row as kPkString — the bot side coerces
  // strings to int/float/duration permissively. Operators get
  // raw access to any param without us pre-classifying them.
  for i := FAdvGrid.FixedRows to FAdvGrid.RowCount - 1 do
  begin
    k := Trim(FAdvGrid.Cells[0, i]);
    v := Trim(FAdvGrid.Cells[1, i]);
    if (k <> '') and (v <> '') then
      AddStrParam(RawUtf8(k), RawUtf8(v));
  end;
end;

function TNewPlanWizard.BuildReviewText: string;
var
  cap: TPlanCapability;
  cat: TPlanCapabilityInfoArray;
  unders: TStrArr;
  ses: TStatusSession;
  i: Integer;
  symbolList, riskLine, windowLine, tuningLine, advLine: string;
  symbol, k, v: string;
  isDry: Boolean;
begin
  cap := CurrentCapability;
  cat := PlanCapabilityCatalog;
  ses := SelectedSession;
  unders := ParseUnderlyings(FEdtUnderlyings.Text);

  symbolList := '';
  for i := 0 to High(unders) do
  begin
    symbol := unders[i];
    if i = 0 then symbolList := symbol
    else symbolList := symbolList + ', ' + symbol;
  end;
  if symbolList = '' then symbolList := '(none)';

  riskLine := '';
  if Trim(FEdtMaxDailyLoss.Text) <> '' then
    riskLine := riskLine + 'Daily loss cap: ₹' + Trim(FEdtMaxDailyLoss.Text) + LineEnding;
  if Trim(FEdtMaxSymbolLoss.Text) <> '' then
    riskLine := riskLine + 'Symbol loss cap: ₹' + Trim(FEdtMaxSymbolLoss.Text) + LineEnding;
  if riskLine = '' then
    riskLine := 'Loss caps: inherit from instance' + LineEnding;

  windowLine := '';
  if (Trim(FEdtEntryStart.Text) <> '') or (Trim(FEdtEntryEnd.Text) <> '') then
    windowLine := windowLine + 'Entries: ' +
      IfThen(Trim(FEdtEntryStart.Text) = '', 'open', Trim(FEdtEntryStart.Text)) +
      ' - ' +
      IfThen(Trim(FEdtEntryEnd.Text) = '', 'open', Trim(FEdtEntryEnd.Text)) +
      ' IST' + LineEnding;
  if Trim(FEdtCutoffTime.Text) <> '' then
    windowLine := windowLine + 'Stop entries after: ' + Trim(FEdtCutoffTime.Text) + ' IST' + LineEnding;
  if Trim(FEdtHardExit.Text) <> '' then
    windowLine := windowLine + 'Hard exit at: ' + Trim(FEdtHardExit.Text) + ' IST' + LineEnding;
  if Trim(FEdtMonitorUntil.Text) <> '' then
    windowLine := windowLine + 'Monitor until: ' + Trim(FEdtMonitorUntil.Text) + ' IST' + LineEnding;

  tuningLine := 'Stop loss: ' + Trim(FEdtSLPct.Text) + '%   ' +
                'Take profit: ' + Trim(FEdtTPPct.Text) + '%' + LineEnding;
  if cap = pcGammaScalper then
  begin
    tuningLine := tuningLine + 'Gamma mode: ' + FCmbGammaMode.Items[FCmbGammaMode.ItemIndex] + LineEnding;
    tuningLine := tuningLine + 'VIX gates: sell <' + Trim(FEdtVIXSell.Text) +
                  '   buy >' + Trim(FEdtVIXBuy.Text) + LineEnding;
    if FChkExpiryOnly.Checked then
      tuningLine := tuningLine + 'Expiry day only' + LineEnding;
  end;

  advLine := '';
  for i := FAdvGrid.FixedRows to FAdvGrid.RowCount - 1 do
  begin
    k := Trim(FAdvGrid.Cells[0, i]);
    v := Trim(FAdvGrid.Cells[1, i]);
    if (k <> '') and (v <> '') then
      advLine := advLine + '  ' + k + ' = ' + v + LineEnding;
  end;
  if advLine = '' then
    advLine := '  (none)' + LineEnding;

  isDry := FChkDryRun.Checked;

  result :=
    'BOT' + LineEnding +
    '  ' + cat[Ord(cap)].Title + LineEnding +
    '  ' + cat[Ord(cap)].OneLine + LineEnding +
    LineEnding +
    'SESSION' + LineEnding +
    '  Instance: ' + string(ses.InstanceId) + LineEnding +
    '  Broker:   ' + string(ses.Broker) + LineEnding +
    LineEnding +
    'MARKETS' + LineEnding +
    '  Underlyings: ' + symbolList + LineEnding +
    '  Lots / leg:  ' + Trim(FEdtLots.Text) + LineEnding +
    '  Product:     ' + FCmbProduct.Items[FCmbProduct.ItemIndex] + LineEnding +
    '  Underlying:  ' + FCmbUndExchange.Text + LineEnding +
    '  Options:     ' + FCmbOptExchange.Text + LineEnding +
    LineEnding +
    'MONEY' + LineEnding +
    '  Max premium / leg: ₹' + Trim(FEdtMaxPremium.Text) + LineEnding +
    '  Strikes per side:  ' + Trim(FEdtStrikeCount.Text) + LineEnding +
    '  Max open legs:     ' + Trim(FEdtMaxOpenLegs.Text) + LineEnding +
    '  ' + riskLine +
    '  Mode: ' + IfThen(isDry, 'DRY RUN  (paper trade only)',
                                'LIVE  (real orders will be sent)') + LineEnding +
    LineEnding +
    'TIME' + LineEnding +
    windowLine +
    '  When monitor ends: ' + FCmbOnExpire.Items[FCmbOnExpire.ItemIndex] + LineEnding +
    LineEnding +
    'TUNING' + LineEnding +
    '  ' + tuningLine +
    LineEnding +
    'ADVANCED' + LineEnding +
    advLine;
end;

end.
