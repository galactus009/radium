unit Radium.Gui.RiskFrame;

(* ----------------------------------------------------------------------------
  Risk frame — centre-host content for the "Risk" sidebar destination.
  Mirrors thoriumctl's `risk get` / `risk set`:

    risk get    — show the effective + persisted risk knobs
    risk set    — patch one or more knobs; thoriumd writes risk.json

  Risk is instance-wide (not per-plan), so this panel doesn't depend
  on session selection. The view is split into two visually distinct
  regions:

    +- Risk ─────────────────────────────────────────────────────────+
    |  CURRENT (read-only summary card)                              |
    |    Cutoff time              14:45 IST                          |
    |    Max daily loss           ₹50,000                            |
    |    ...                                                         |
    |                                                                |
    |  EDIT  (only fields you change get sent to thoriumd)           |
    |    [tabs: Daily / Margin / Options / Cutoff]                   |
    |                                                                |
    |    field grid for the active tab                               |
    |                                                                |
    |  [Discard changes]                            [Save changes]   |
    +-----------------------------------------------------------------+

  Wire semantics: a TRiskPatch sends only fields the operator
  explicitly touched (each field has a paired Has<Field> flag,
  matching thoriumctl's flagWasSet). This frame tracks edits per-
  field by comparing current text to the value loaded from /admin/risk;
  Save builds a patch with only the deltas.

  Tabs (per Docs/LookAndFeel.md): a single 13-field grid would be a
  cognitive wall. Splitting into Daily / Margin / Options / Cutoff
  groups what an operator usually changes together.
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  Classes,
  SysUtils,
  StrUtils,
  Forms,
  Controls,
  Graphics,
  Grids,
  ComCtrls,
  ExtCtrls,
  StdCtrls,
  mormot.core.base,
  Radium.Api.Types;

type
  // Frame raises events; MainForm owns the client. Same separation as
  // SessionsFrame / PlansFrame.
  TRiskLoadEvent = procedure(Sender: TObject) of object;
  TRiskSaveEvent = procedure(Sender: TObject;
    const APatch: TRiskPatch) of object;

  { TRiskFrame }
  TRiskFrame = class(TPanel)
  private
    FTopBar:        TPanel;
      FBtnReload:   TButton;
      FStatusLbl:   TLabel;

    // Read-only "current" section
    FCurrentCard:   TPanel;
      FCurrentGrid: TStringGrid;

    // Edit section
    FEditTabs:      TTabControl;
    FEditPanel:     TPanel;        // hosts the active edit page
    // Single set of editors; the active tab dictates which subset is
    // visible. Simpler than building four panels — fewer surprises
    // when a knob moves between tabs in the future.
    FFieldRows:     array of record
      Key:    RawUtf8;
      Tab:    Integer;       // index into FEditTabs
      Lbl:    TLabel;
      Edit:   TEdit;
      Hint:   TLabel;
      IsInt:  Boolean;
      OrigStr: RawUtf8;      // value as displayed when last loaded
    end;

    FBtnSave:       TButton;
    FBtnDiscard:    TButton;

    FOnLoad:        TRiskLoadEvent;
    FOnSave:        TRiskSaveEvent;

    // FInstanceScope — '' = global, otherwise the instance_id the
    // operator picked. Today the RiskGet/RiskSet wire endpoints
    // ignore this; when thoriumd grows /admin/risk?instance_id=X
    // the query param is added in TThoriumClient and this field
    // becomes load-bearing without any frame-side rewrite.
    FInstanceScope: RawUtf8;
    FCmbScope:      TComboBox;

    FLoaded:        TRiskConfig;   // last server snapshot

    procedure BuildTopBar;
    procedure BuildCurrentCard;
    procedure BuildEditSection;
    procedure AddField(ATab: Integer; const AKey: RawUtf8;
      const ALabel: string; AIsInt: Boolean; const AHint: string);

    procedure DoReloadClick(Sender: TObject);
    procedure DoSaveClick(Sender: TObject);
    procedure DoDiscardClick(Sender: TObject);
    procedure DoTabChange(Sender: TObject);
    procedure DoScopeChange(Sender: TObject);

    procedure ApplyScopeLockState;

    procedure RenderCurrent(const ARisk: TRiskConfig);
    procedure FillEditorsFromConfig(const ARisk: TRiskConfig);
    procedure ApplyTabVisibility;
    function  BuildPatchFromEdits: TRiskPatch;

    function  FieldValue(const AKey: RawUtf8): string;
    procedure SetFieldValue(const AKey: RawUtf8; const AText: string);
    procedure SetEditorOriginal(const AKey: RawUtf8; const AText: string);

    function  FormatRupee(AValue: Double): string;
    function  FormatPercent(AValue: Double): string;
    function  FormatRowCount(AValue: Integer): string;
  public
    constructor Create(AOwner: TComponent); override;

    // Replace the displayed snapshot. Caller fetches via
    // TThoriumClient.RiskGet and forwards here.
    procedure SetRisk(const ARisk: TRiskConfig);

    // Called when MainForm completes a successful save; resets the
    // "modified vs original" baseline so the operator's changes
    // become the new "no-op" state.
    procedure CommitSavedSnapshot(const ARisk: TRiskConfig);

    // Surface a transient status ("loading…", "saved 14:32 IST", or
    // an error). Cleared by the next Set/Render call.
    procedure SetStatusText(const AText: string; AKind: Integer);

    // SetInstanceOptions — populate the scope picker with attached
    // sessions. 'Global' is always first; selecting an instance is a
    // no-op against today's thoriumd but reserved for future per-
    // broker risk. Caller passes the same instance_id list it'd use
    // for any other instance-scoped panel.
    procedure SetInstanceOptions(const AInstanceIds: array of RawUtf8);

    // SelectedInstance — '' for Global, otherwise the instance_id.
    // Caller threads this into RiskGet / RiskSet calls so the wiring
    // is in place when the server-side per-broker support lands.
    function SelectedInstance: RawUtf8;

    property OnLoad: TRiskLoadEvent read FOnLoad write FOnLoad;
    property OnSave: TRiskSaveEvent read FOnSave write FOnSave;
  end;

implementation

uses
  Radium.Gui.Theme;

const
  TOPBAR_H        = 56;
  CARD_H          = 220;
  EDITTABS_H      = 36;

  // Tab indices kept here so AddField calls stay readable.
  TAB_DAILY    = 0;
  TAB_MARGIN   = 1;
  TAB_OPTIONS  = 2;
  TAB_CUTOFF   = 3;

// FormatNumber — locale-stable float formatting for both display
// (read-only card) and editor seeding. Trailing zeros trimmed so 0.0
// shows as "0", and 0.5 stays "0.5".
function FormatNum(AValue: Double): string;
begin
  result := FormatFloat('0.######', AValue);
end;

function FormatInt(AValue: Integer): string;
begin
  result := IntToStr(AValue);
end;

function NormaliseEditedNum(const AText: string): string;
begin
  // Trim, swap comma decimals, normalise '0.0' → '0'.
  result := Trim(AText);
  result := StringReplace(result, ',', '.', [rfReplaceAll]);
end;

function TryParseFloat(const AText: string; out AValue: Double): Boolean;
var n: string;
begin
  n := NormaliseEditedNum(AText);
  result := (n <> '') and TryStrToFloat(n, AValue, DefaultFormatSettings);
end;

function TryParseInt(const AText: string; out AValue: Integer): Boolean;
var n: string; v: Int64;
begin
  n := Trim(AText);
  result := (n <> '') and TryStrToInt64(n, v);
  if result then
    AValue := Integer(v);
end;

{ TRiskFrame ───────────────────────────────────────────────────────── }

constructor TRiskFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption    := '';

  BuildTopBar;
  BuildCurrentCard;
  BuildEditSection;

  ApplyTabVisibility;
  ApplyScopeLockState;
end;

procedure TRiskFrame.SetInstanceOptions(const AInstanceIds: array of RawUtf8);
var
  i: Integer;
begin
  FCmbScope.Items.BeginUpdate;
  try
    FCmbScope.Items.Clear;
    FCmbScope.Items.Add('Global  (all sessions)');
    for i := 0 to High(AInstanceIds) do
      FCmbScope.Items.Add(string(AInstanceIds[i]) + '  (per-broker, coming soon)');
  finally
    FCmbScope.Items.EndUpdate;
  end;
  if FCmbScope.ItemIndex < 0 then
    FCmbScope.ItemIndex := 0;
  ApplyScopeLockState;
end;

function TRiskFrame.SelectedInstance: RawUtf8;
begin
  if (FCmbScope = nil) or (FCmbScope.ItemIndex <= 0) then
    result := ''
  else
    result := FInstanceScope;
end;

procedure TRiskFrame.DoScopeChange(Sender: TObject);
begin
  if FCmbScope.ItemIndex <= 0 then
    FInstanceScope := ''
  else
    // Strip the suffix when storing the wire id.
    FInstanceScope := RawUtf8(
      Copy(FCmbScope.Items[FCmbScope.ItemIndex], 1,
           Pos('  (', FCmbScope.Items[FCmbScope.ItemIndex]) - 1));
  ApplyScopeLockState;
end;

procedure TRiskFrame.ApplyScopeLockState;
var
  isGlobal: Boolean;
  i: Integer;
begin
  isGlobal := (FCmbScope = nil) or (FCmbScope.ItemIndex <= 0);
  if isGlobal then
    FStatusLbl.Caption :=
      'Editing global risk caps. Changes apply to every broker session. ' +
      'Persists to thoriumd''s risk.json on save.'
  else
    FStatusLbl.Caption :=
      'Per-broker risk requires thoriumd to support /admin/risk?instance_id=X. ' +
      'The endpoint is not live yet — switch back to Global to edit.';

  // Lock the editors when scope is non-global so the operator can't
  // type into a no-op surface.
  if FBtnSave <> nil then FBtnSave.Enabled := isGlobal;
  if FBtnDiscard <> nil then FBtnDiscard.Enabled := isGlobal;
  for i := 0 to High(FFieldRows) do
    if FFieldRows[i].Edit <> nil then
      FFieldRows[i].Edit.Enabled := isGlobal;
end;

procedure TRiskFrame.BuildTopBar;
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
  FBtnReload.Width   := 160;
  FBtnReload.Height  := 30;
  FBtnReload.Caption := 'Reload from thoriumd';
  FBtnReload.OnClick := DoReloadClick;
  SetSemantic(FBtnReload, skPrimary);

  // Scope picker. Today only "Global" works on the wire (thoriumd's
  // /admin/risk has no instance_id param). The dropdown ships in the
  // shipped UI so the operator's mental model is "choose what scope
  // to govern" not "Risk = Global, period". When /admin/risk?instance_id=X
  // lands, the per-instance entries become live.
  FCmbScope := TComboBox.Create(FTopBar);
  FCmbScope.Parent := FTopBar;
  FCmbScope.Left   := 200;
  FCmbScope.Top    := 14;
  FCmbScope.Width  := 220;
  FCmbScope.Height := 30;
  FCmbScope.Style  := csDropDownList;
  FCmbScope.Items.Add('Global  (all sessions)');
  FCmbScope.ItemIndex := 0;
  FCmbScope.OnChange := DoScopeChange;

  // Banner — set by ApplyScopeLockState based on current selection
  // so it stays in sync when the operator switches scopes.
  FStatusLbl := TLabel.Create(FTopBar);
  FStatusLbl.Parent := FTopBar;
  FStatusLbl.Left   := 440;
  FStatusLbl.Top    := 18;
  FStatusLbl.AutoSize := False;
  FStatusLbl.Width  := 660;
  FStatusLbl.Height := 32;
  FStatusLbl.WordWrap := True;
  FStatusLbl.Font.Height := -12;
  FStatusLbl.ParentColor := True;
  FStatusLbl.ParentFont  := False;
  SetSemantic(FStatusLbl, skMuted);
end;

procedure TRiskFrame.BuildCurrentCard;
var
  hdr: TLabel;
begin
  FCurrentCard := TPanel.Create(Self);
  FCurrentCard.Parent     := Self;
  FCurrentCard.Align      := alTop;
  FCurrentCard.Height     := CARD_H;
  FCurrentCard.BevelOuter := bvNone;
  FCurrentCard.Caption    := '';

  hdr := TLabel.Create(FCurrentCard);
  hdr.Parent  := FCurrentCard;
  hdr.Caption := 'CURRENT RISK CAPS';
  hdr.Left    := 16;
  hdr.Top     := 8;
  hdr.AutoSize := True;
  hdr.Font.Height := -10;
  hdr.Font.Style  := [fsBold];
  hdr.ParentColor := True;
  hdr.ParentFont  := False;
  SetSemantic(hdr, skMuted);

  FCurrentGrid := TStringGrid.Create(FCurrentCard);
  FCurrentGrid.Parent       := FCurrentCard;
  FCurrentGrid.Left         := 16;
  FCurrentGrid.Top          := 32;
  FCurrentGrid.Width        := 1080;
  FCurrentGrid.Height       := CARD_H - 48;
  FCurrentGrid.Anchors      := [akLeft, akTop, akRight];
  FCurrentGrid.RowCount     := 14;       // 13 knobs + header
  FCurrentGrid.ColCount     := 2;
  FCurrentGrid.FixedRows    := 1;
  FCurrentGrid.FixedCols    := 0;
  FCurrentGrid.Cells[0, 0]  := 'Knob';
  FCurrentGrid.Cells[1, 0]  := 'Value';
  FCurrentGrid.ColWidths[0] := 280;
  FCurrentGrid.ColWidths[1] := 760;
  FCurrentGrid.DefaultRowHeight := 24;
  FCurrentGrid.Options := FCurrentGrid.Options - [goEditing] + [goVertLine, goHorzLine];
  FCurrentGrid.ScrollBars := ssNone;
end;

procedure TRiskFrame.BuildEditSection;
var
  bottom: TPanel;
begin
  FEditTabs := TTabControl.Create(Self);
  FEditTabs.Parent  := Self;
  FEditTabs.Align   := alTop;
  FEditTabs.Height  := EDITTABS_H;
  FEditTabs.Tabs.Add('Daily');
  FEditTabs.Tabs.Add('Margin');
  FEditTabs.Tabs.Add('Options');
  FEditTabs.Tabs.Add('Cutoff');
  FEditTabs.TabIndex := 0;
  FEditTabs.OnChange := DoTabChange;

  FEditPanel := TPanel.Create(Self);
  FEditPanel.Parent     := Self;
  FEditPanel.Align      := alClient;
  FEditPanel.BevelOuter := bvNone;
  FEditPanel.Caption    := '';

  // Bottom action bar — Discard (muted) + Save (primary). 56px tall;
  // alBottom on the frame (not on the edit panel) so the buttons
  // stay anchored as the panel grows.
  bottom := TPanel.Create(Self);
  bottom.Parent     := Self;
  bottom.Align      := alBottom;
  bottom.Height     := 56;
  bottom.BevelOuter := bvNone;
  bottom.Caption    := '';

  FBtnDiscard := TButton.Create(bottom);
  FBtnDiscard.Parent  := bottom;
  FBtnDiscard.Left    := 16;
  FBtnDiscard.Top     := 12;
  FBtnDiscard.Width   := 160;
  FBtnDiscard.Height  := 32;
  FBtnDiscard.Caption := 'Discard changes';
  FBtnDiscard.OnClick := DoDiscardClick;
  SetSemantic(FBtnDiscard, skMuted);

  FBtnSave := TButton.Create(bottom);
  FBtnSave.Parent  := bottom;
  FBtnSave.Left    := 196;
  FBtnSave.Top     := 12;
  FBtnSave.Width   := 160;
  FBtnSave.Height  := 32;
  FBtnSave.Caption := 'Save changes';
  FBtnSave.Default := True;
  FBtnSave.Font.Style := [fsBold];
  FBtnSave.ParentFont := False;
  FBtnSave.OnClick := DoSaveClick;
  SetSemantic(FBtnSave, skPrimary);

  // ── Daily tab ───────────────────────────────────────────────
  AddField(TAB_DAILY,  'cutoff_time',
    'Stop entries after (IST HH:MM)', False,
    'No new entries fire after this clock time. Engine default 14:45.');
  AddField(TAB_DAILY,  'max_daily_loss',
    'Max daily loss (₹)', False,
    'Aggregate session loss; flatten everything when breached.');
  AddField(TAB_DAILY,  'max_symbol_loss',
    'Max symbol loss (₹)', False,
    'Per-underlying realized-loss cap; further entries blocked after breach.');
  AddField(TAB_DAILY,  'max_open_orders',
    'Max open orders', True,
    'Concurrent open-order ceiling across all instruments.');

  // ── Margin tab ──────────────────────────────────────────────
  AddField(TAB_MARGIN, 'intraday_leverage',
    'Intraday leverage', False,
    'Multiplier on usable margin for MIS positions. 1.0 = no leverage.');
  AddField(TAB_MARGIN, 'exposure_utilization',
    'Exposure utilization (0-1)', False,
    'Fraction of available margin allowed at peak gross exposure.');
  AddField(TAB_MARGIN, 'max_margin_utilization',
    'Max margin utilization (0-1)', False,
    'Hard ceiling on used / available margin. New entries refused above.');
  AddField(TAB_MARGIN, 'min_available_margin',
    'Min available margin (₹)', False,
    'Floor on free margin; entries refused if breached.');

  // ── Options tab ─────────────────────────────────────────────
  AddField(TAB_OPTIONS, 'max_option_lots',
    'Max option lots', True,
    'Hard cap on total options lots open across the session.');
  AddField(TAB_OPTIONS, 'max_premium_per_lot',
    'Max premium per lot (₹)', False,
    'Refuse entries whose per-lot premium exceeds this.');
  AddField(TAB_OPTIONS, 'max_option_notional',
    'Max option notional (₹)', False,
    'Aggregate notional cap on options exposure.');

  // ── Cutoff tab ──────────────────────────────────────────────
  AddField(TAB_CUTOFF, 'hard_max_lots',
    'Hard max lots (any product)', True,
    'Absolute cap on lots — applies across all instrument types.');
  AddField(TAB_CUTOFF, 'hard_max_notional',
    'Hard max notional (₹)', False,
    'Absolute cap on session notional. Last-resort circuit breaker.');
end;

procedure TRiskFrame.AddField(ATab: Integer; const AKey: RawUtf8;
  const ALabel: string; AIsInt: Boolean; const AHint: string);
var
  n, x, y, i, prior: Integer;
begin
  n := Length(FFieldRows);
  SetLength(FFieldRows, n + 1);
  FFieldRows[n].Key   := AKey;
  FFieldRows[n].Tab   := ATab;
  FFieldRows[n].IsInt := AIsInt;
  FFieldRows[n].OrigStr := '';

  // Within each tab, fields stack vertically. Compute position from
  // the count of prior rows in the same tab (keeps call-order =
  // display-order without a separate per-tab counter).
  prior := 0;
  for i := 0 to n - 1 do
    if FFieldRows[i].Tab = ATab then
      Inc(prior);
  x := 16;
  y := 16 + prior * 76;

  FFieldRows[n].Lbl := TLabel.Create(FEditPanel);
  FFieldRows[n].Lbl.Parent  := FEditPanel;
  FFieldRows[n].Lbl.Caption := ALabel;
  FFieldRows[n].Lbl.Left    := x;
  FFieldRows[n].Lbl.Top     := y;
  FFieldRows[n].Lbl.AutoSize := True;
  FFieldRows[n].Lbl.Font.Height := -12;
  FFieldRows[n].Lbl.Font.Style  := [fsBold];
  FFieldRows[n].Lbl.ParentColor := True;
  FFieldRows[n].Lbl.ParentFont  := False;
  SetSemantic(FFieldRows[n].Lbl, skNeutral);

  FFieldRows[n].Edit := TEdit.Create(FEditPanel);
  FFieldRows[n].Edit.Parent := FEditPanel;
  FFieldRows[n].Edit.Left   := x;
  FFieldRows[n].Edit.Top    := y + 22;
  FFieldRows[n].Edit.Width  := 200;
  FFieldRows[n].Edit.Height := 28;

  FFieldRows[n].Hint := TLabel.Create(FEditPanel);
  FFieldRows[n].Hint.Parent  := FEditPanel;
  FFieldRows[n].Hint.Caption := AHint;
  FFieldRows[n].Hint.Left    := x + 220;
  FFieldRows[n].Hint.Top     := y + 26;
  FFieldRows[n].Hint.Width   := 700;
  FFieldRows[n].Hint.Height  := 30;
  FFieldRows[n].Hint.AutoSize := False;
  FFieldRows[n].Hint.WordWrap := True;
  FFieldRows[n].Hint.Font.Height := -11;
  FFieldRows[n].Hint.ParentColor := True;
  FFieldRows[n].Hint.ParentFont  := False;
  SetSemantic(FFieldRows[n].Hint, skMuted);
end;

procedure TRiskFrame.SetRisk(const ARisk: TRiskConfig);
begin
  FLoaded := ARisk;
  RenderCurrent(ARisk);
  FillEditorsFromConfig(ARisk);
end;

procedure TRiskFrame.CommitSavedSnapshot(const ARisk: TRiskConfig);
begin
  // Successful save → take the just-saved values as the new baseline
  // for "no-op" detection on the next BuildPatchFromEdits.
  SetRisk(ARisk);
end;

procedure TRiskFrame.SetStatusText(const AText: string; AKind: Integer);
var k: TSemanticKind;
begin
  // AKind: 0 muted/info, 1 success, -1 danger. Keeps the surface
  // narrow without exposing the full TSemanticKind enum.
  case AKind of
    1:  k := skBuy;
    -1: k := skDelete;
  else  k := skMuted;
  end;
  SetSemantic(FStatusLbl, k);
  FStatusLbl.Caption := AText;
end;

procedure TRiskFrame.RenderCurrent(const ARisk: TRiskConfig);
  procedure SetRow(R: Integer; const AKey, AVal: string);
  begin
    FCurrentGrid.Cells[0, R] := AKey;
    FCurrentGrid.Cells[1, R] := AVal;
  end;
begin
  // Display row order matches the form's tab order so the operator's
  // eyes train on the same vertical layout in both panes.
  SetRow(1,  'Stop entries after',
         IfThen(string(ARisk.CutoffTime) = '', '-', string(ARisk.CutoffTime) + ' IST'));
  SetRow(2,  'Max daily loss',           FormatRupee(ARisk.MaxDailyLoss));
  SetRow(3,  'Max symbol loss',          FormatRupee(ARisk.MaxSymbolLoss));
  SetRow(4,  'Max open orders',          FormatRowCount(ARisk.MaxOpenOrders));

  SetRow(5,  'Intraday leverage',        FormatNum(ARisk.IntradayLeverage));
  SetRow(6,  'Exposure utilization',     FormatPercent(ARisk.ExposureUtilization));
  SetRow(7,  'Max margin utilization',   FormatPercent(ARisk.MaxMarginUtilization));
  SetRow(8,  'Min available margin',     FormatRupee(ARisk.MinAvailableMargin));

  SetRow(9,  'Max option lots',          FormatRowCount(ARisk.MaxOptionLots));
  SetRow(10, 'Max premium per lot',      FormatRupee(ARisk.MaxPremiumPerLot));
  SetRow(11, 'Max option notional',      FormatRupee(ARisk.MaxOptionNotional));

  SetRow(12, 'Hard max lots',            FormatRowCount(ARisk.HardMaxLots));
  SetRow(13, 'Hard max notional',        FormatRupee(ARisk.HardMaxNotional));
end;

procedure TRiskFrame.FillEditorsFromConfig(const ARisk: TRiskConfig);
  procedure SetByKey(const AKey, AText: string);
  begin
    SetFieldValue(RawUtf8(AKey), AText);
    SetEditorOriginal(RawUtf8(AKey), AText);
  end;
begin
  // String fields use the wire shape verbatim; numeric fields use the
  // engine-side scalar with no unit decoration so what the operator
  // types matches what gets sent.
  SetByKey('cutoff_time',            string(ARisk.CutoffTime));
  SetByKey('max_daily_loss',         FormatNum(ARisk.MaxDailyLoss));
  SetByKey('max_symbol_loss',        FormatNum(ARisk.MaxSymbolLoss));
  SetByKey('max_open_orders',        FormatInt(ARisk.MaxOpenOrders));

  SetByKey('intraday_leverage',      FormatNum(ARisk.IntradayLeverage));
  SetByKey('exposure_utilization',   FormatNum(ARisk.ExposureUtilization));
  SetByKey('max_margin_utilization', FormatNum(ARisk.MaxMarginUtilization));
  SetByKey('min_available_margin',   FormatNum(ARisk.MinAvailableMargin));

  SetByKey('max_option_lots',        FormatInt(ARisk.MaxOptionLots));
  SetByKey('max_premium_per_lot',    FormatNum(ARisk.MaxPremiumPerLot));
  SetByKey('max_option_notional',    FormatNum(ARisk.MaxOptionNotional));

  SetByKey('hard_max_lots',          FormatInt(ARisk.HardMaxLots));
  SetByKey('hard_max_notional',      FormatNum(ARisk.HardMaxNotional));
end;

procedure TRiskFrame.ApplyTabVisibility;
var i: Integer;
begin
  for i := 0 to High(FFieldRows) do
  begin
    FFieldRows[i].Lbl.Visible  := FFieldRows[i].Tab = FEditTabs.TabIndex;
    FFieldRows[i].Edit.Visible := FFieldRows[i].Tab = FEditTabs.TabIndex;
    FFieldRows[i].Hint.Visible := FFieldRows[i].Tab = FEditTabs.TabIndex;
  end;
end;

procedure TRiskFrame.DoTabChange(Sender: TObject);
begin
  ApplyTabVisibility;
end;

procedure TRiskFrame.DoReloadClick(Sender: TObject);
begin
  if Assigned(FOnLoad) then
    FOnLoad(Self);
end;

procedure TRiskFrame.DoDiscardClick(Sender: TObject);
begin
  // Repopulate every editor with the originals captured from the
  // last load. Doesn't hit the network — purely a local rollback.
  FillEditorsFromConfig(FLoaded);
  SetStatusText('Discarded local edits.', 0);
end;

procedure TRiskFrame.DoSaveClick(Sender: TObject);
var patch: TRiskPatch;
begin
  patch := BuildPatchFromEdits;
  if not (patch.HasCutoffTime or patch.HasMaxOpenOrders or
          patch.HasMaxDailyLoss or patch.HasMaxSymbolLoss or
          patch.HasHardMaxLots or patch.HasHardMaxNotional or
          patch.HasMaxOptionLots or patch.HasMaxPremiumPerLot or
          patch.HasMaxOptionNotional or patch.HasIntradayLeverage or
          patch.HasExposureUtilization or patch.HasMaxMarginUtilization or
          patch.HasMinAvailableMargin) then
  begin
    SetStatusText('No changes to save.', 0);
    exit;
  end;
  if Assigned(FOnSave) then
    FOnSave(Self, patch);
end;

function TRiskFrame.BuildPatchFromEdits: TRiskPatch;
  function Changed(const AKey: RawUtf8): Boolean;
  var i: Integer;
  begin
    result := False;
    for i := 0 to High(FFieldRows) do
      if FFieldRows[i].Key = AKey then
      begin
        result := Trim(FFieldRows[i].Edit.Text) <>
                  Trim(string(FFieldRows[i].OrigStr));
        exit;
      end;
  end;
  function FltOf(const AKey: RawUtf8): Double;
  var v: Double; t: string;
  begin
    t := FieldValue(AKey);
    if TryParseFloat(t, v) then result := v else result := 0;
  end;
  function IntOf(const AKey: RawUtf8): Integer;
  var v: Integer; t: string;
  begin
    t := FieldValue(AKey);
    if TryParseInt(t, v) then result := v else result := 0;
  end;
begin
  FillChar(result, SizeOf(result), 0);

  if Changed('cutoff_time') then
  begin
    result.CutoffTime := RawUtf8(Trim(FieldValue('cutoff_time')));
    result.HasCutoffTime := True;
  end;
  if Changed('max_open_orders') then
  begin
    result.MaxOpenOrders := IntOf('max_open_orders');
    result.HasMaxOpenOrders := True;
  end;
  if Changed('max_daily_loss') then
  begin
    result.MaxDailyLoss := FltOf('max_daily_loss');
    result.HasMaxDailyLoss := True;
  end;
  if Changed('max_symbol_loss') then
  begin
    result.MaxSymbolLoss := FltOf('max_symbol_loss');
    result.HasMaxSymbolLoss := True;
  end;
  if Changed('hard_max_lots') then
  begin
    result.HardMaxLots := IntOf('hard_max_lots');
    result.HasHardMaxLots := True;
  end;
  if Changed('hard_max_notional') then
  begin
    result.HardMaxNotional := FltOf('hard_max_notional');
    result.HasHardMaxNotional := True;
  end;
  if Changed('max_option_lots') then
  begin
    result.MaxOptionLots := IntOf('max_option_lots');
    result.HasMaxOptionLots := True;
  end;
  if Changed('max_premium_per_lot') then
  begin
    result.MaxPremiumPerLot := FltOf('max_premium_per_lot');
    result.HasMaxPremiumPerLot := True;
  end;
  if Changed('max_option_notional') then
  begin
    result.MaxOptionNotional := FltOf('max_option_notional');
    result.HasMaxOptionNotional := True;
  end;
  if Changed('intraday_leverage') then
  begin
    result.IntradayLeverage := FltOf('intraday_leverage');
    result.HasIntradayLeverage := True;
  end;
  if Changed('exposure_utilization') then
  begin
    result.ExposureUtilization := FltOf('exposure_utilization');
    result.HasExposureUtilization := True;
  end;
  if Changed('max_margin_utilization') then
  begin
    result.MaxMarginUtilization := FltOf('max_margin_utilization');
    result.HasMaxMarginUtilization := True;
  end;
  if Changed('min_available_margin') then
  begin
    result.MinAvailableMargin := FltOf('min_available_margin');
    result.HasMinAvailableMargin := True;
  end;
end;

function TRiskFrame.FieldValue(const AKey: RawUtf8): string;
var i: Integer;
begin
  result := '';
  for i := 0 to High(FFieldRows) do
    if FFieldRows[i].Key = AKey then
    begin
      result := FFieldRows[i].Edit.Text;
      exit;
    end;
end;

procedure TRiskFrame.SetFieldValue(const AKey: RawUtf8; const AText: string);
var i: Integer;
begin
  for i := 0 to High(FFieldRows) do
    if FFieldRows[i].Key = AKey then
    begin
      FFieldRows[i].Edit.Text := AText;
      exit;
    end;
end;

procedure TRiskFrame.SetEditorOriginal(const AKey: RawUtf8; const AText: string);
var i: Integer;
begin
  for i := 0 to High(FFieldRows) do
    if FFieldRows[i].Key = AKey then
    begin
      FFieldRows[i].OrigStr := RawUtf8(AText);
      exit;
    end;
end;

function TRiskFrame.FormatRupee(AValue: Double): string;
begin
  if AValue = 0 then
    result := '-'
  else
    result := '₹' + FormatFloat('#,##0.##', AValue);
end;

function TRiskFrame.FormatPercent(AValue: Double): string;
begin
  if AValue = 0 then
    result := '-'
  else
    result := FormatFloat('0.##', AValue * 100) + '%';
end;

function TRiskFrame.FormatRowCount(AValue: Integer): string;
begin
  if AValue = 0 then
    result := '-'
  else
    result := IntToStr(AValue);
end;

end.
