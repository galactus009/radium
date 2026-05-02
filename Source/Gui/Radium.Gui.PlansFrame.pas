unit Radium.Gui.PlansFrame;

(* ----------------------------------------------------------------------------
  Plans frame — centre-host content for the "Plans" sidebar destination.

  thoriumd's TradePlan API is the only way the GUI launches a bot:
  POST /api/v1/plans/create with capability='options.scalper' (OptionsBuddy)
  or 'gamma.scalper' (GammaBuddy) routes to the matching in-process bot.
  This frame is the operator's ground-truth view of every plan thoriumd
  knows about for the current session set.

  Layout matches Sessions for muscle memory:

    +- Plans ─────────────────────────────────────────────────────────+
    |  [+ New plan ▾]   instance: [▼ all ]   status: [▼ active ]      |
    |                                                            [↻]  |
    |  ┌─────┬──────────┬─────────┬─────────────────┬───────┬──────┐  |
    |  │ id  │ Bot      │ Status  │ Instruments     │ Updt. │ Acts │  |
    |  └─────┴──────────┴─────────┴─────────────────┴───────┴──────┘  |
    |  ┌─────┬──────────┬─────────┬─────────────────┬───────┬──────┐  |
    |  │ pln1│ Options  │ ● run   │ NIFTY · BANK    │ 09:14 │ ▤▣▥  │  |
    |  └─────┴──────────┴─────────┴─────────────────┴───────┴──────┘  |
    |  …                                                              |
    +─────────────────────────────────────────────────────────────────+

  Empty state is the same modern empty card SessionsFrame uses — one
  big primary action ("+ New plan"), clear copy. Lower cognitive load
  than a blank table.

  Action wiring follows SessionsFrame: this frame doesn't talk to the
  API. It raises events (OnNewPlanClicked / OnViewPlanClicked /
  OnHaltClicked / OnResumeClicked / OnCancelClicked / OnRefreshClicked)
  that MainForm hooks; MainForm owns the TThoriumClient.

  The "+ New plan" button is a dropdown so the operator picks their
  capability up front (Options vs Gamma) — wizard then takes over.
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  Classes,
  SysUtils,
  Forms,
  Controls,
  Graphics,
  Menus,
  ComCtrls,
  ExtCtrls,
  StdCtrls,
  mormot.core.base,
  Radium.Api.Types;

type
  // Plan-row action signature. The full TPlanRef is forwarded so
  // MainForm can pull plan_id + instance_id without a separate lookup.
  TPlanActionEvent = procedure(Sender: TObject;
    const APlan: TPlanRef) of object;

  // New-plan request: capability picked in the dropdown menu, wizard
  // then drives shared chrome + capability-specific knobs.
  TNewPlanEvent = procedure(Sender: TObject;
    ACapability: TPlanCapability) of object;

  TPlanRefreshEvent = procedure(Sender: TObject) of object;

  { TPlansFrame }
  TPlansFrame = class(TPanel)
  private
    FTopBar:        TPanel;
    FBtnNewPlan:    TButton;
    FNewPlanMenu:   TPopupMenu;
    FLblInstance:   TLabel;
    FCmbInstance:   TComboBox;
    FStatusTabs:    TTabControl;
    FBtnRefresh:    TButton;

    FHeader:        TPanel;
    FRowsHost:      TScrollBox;
    FEmptyCard:     TPanel;
    FRowPanels:     array of TPanel;
    FPlans:         TPlanRefArray;       // parallel to FRowPanels

    FOnNewPlan:     TNewPlanEvent;
    FOnView:        TPlanActionEvent;
    FOnHalt:        TPlanActionEvent;
    FOnResume:      TPlanActionEvent;
    FOnCancel:      TPlanActionEvent;
    FOnRefresh:     TPlanRefreshEvent;
    FOnFilterChanged: TPlanRefreshEvent;

    procedure DoNewPlanClick(Sender: TObject);
    procedure DoNewOptionsScalper(Sender: TObject);
    procedure DoNewGammaScalper(Sender: TObject);
    procedure DoRefreshClick(Sender: TObject);
    procedure DoFilterChange(Sender: TObject);
    procedure DoViewRow(Sender: TObject);
    procedure DoHaltOrResumeRow(Sender: TObject);
    procedure DoCancelRow(Sender: TObject);

    procedure BuildTopBar;
    procedure BuildHeaderRow;
    procedure BuildEmptyCard;
    function  BuildPlanRow(const APlan: TPlanRef): TPanel;
    procedure ClearRows;
    procedure ShowEmpty;
    procedure ShowList;
    procedure StyleColumnLabel(ALabel: TLabel; ALeft, AWidth: Integer;
      ABold: Boolean);
  public
    constructor Create(AOwner: TComponent); override;

    // Replace the rendered list with this snapshot. Empty array →
    // empty state. Idempotent.
    procedure SetPlans(const APlans: TPlanRefArray);

    // Populate the instance-id filter dropdown. 'all' is always first;
    // each subsequent entry is one attached session's instance_id.
    // MainForm refreshes this whenever Sessions change.
    procedure SetInstanceOptions(const AInstanceIds: array of RawUtf8);

    // Read by MainForm before issuing PlanList — empty string for
    // "all instances", otherwise the picked instance_id.
    function SelectedInstance: RawUtf8;

    // Status filter readout. Empty = 'all'; else one of pending /
    // running / halted / completed / cancelled / expired / error.
    function SelectedStatus: RawUtf8;

    property OnNewPlanClicked:    TNewPlanEvent     read FOnNewPlan  write FOnNewPlan;
    property OnViewPlanClicked:   TPlanActionEvent  read FOnView     write FOnView;
    property OnHaltClicked:       TPlanActionEvent  read FOnHalt     write FOnHalt;
    property OnResumeClicked:     TPlanActionEvent  read FOnResume   write FOnResume;
    property OnCancelClicked:     TPlanActionEvent  read FOnCancel   write FOnCancel;
    property OnRefreshClicked:    TPlanRefreshEvent read FOnRefresh  write FOnRefresh;
    property OnFilterChanged:     TPlanRefreshEvent read FOnFilterChanged write FOnFilterChanged;
  end;

implementation

uses
  Radium.Gui.Theme;

const
  COL_ID_X        =  16;  COL_ID_W        = 110;
  COL_BOT_X       = 134;  COL_BOT_W       = 130;
  COL_STATUS_X    = 272;  COL_STATUS_W    = 110;
  COL_INSTRS_X    = 390;  COL_INSTRS_W    = 240;
  COL_UPDATED_X   = 638;  COL_UPDATED_W   =  80;
  COL_ACTIONS_X   = 726;
  ROW_HEIGHT      = 56;
  HEADER_HEIGHT   = 32;
  TOPBAR_HEIGHT   = 72;

// ShortPlanId — plan IDs are UUIDs. The grid cell is narrow; show
// the first 8 chars (enough to disambiguate at human eyeball-time).
// Hover / detail view shows the full ID.
function ShortPlanId(const AId: RawUtf8): string;
begin
  if Length(AId) > 8 then
    result := string(Copy(AId, 1, 8))
  else
    result := string(AId);
end;

// ShortTime — same helper as SessionsFrame: '2026-05-02T09:14:23Z'
// → '09:14'. Detail view shows the full timestamp.
function ShortTime(const ARfc3339: RawUtf8): string;
var
  s: string;
  i: Integer;
begin
  s := string(ARfc3339);
  i := Pos('T', s);
  if (i > 0) and (Length(s) >= i + 5) then
    result := Copy(s, i + 1, 5)
  else
    result := s;
end;

// CapabilityLabel — wire id → friendly bot name. Unknown
// capabilities surface verbatim so a future bot doesn't disappear
// silently.
function CapabilityLabel(const AWireId: RawUtf8): string;
begin
  if AWireId = 'options.scalper' then
    result := 'Options Scalper'
  else if AWireId = 'gamma.scalper' then
    result := 'Gamma Scalper'
  else
    result := string(AWireId);
end;

// StatusKind — colour mapping for status chips. Active states get
// success/warn; terminal states get muted; error stays loud red so
// the operator sees it at a glance.
function StatusKind(const AStatus: RawUtf8): TSemanticKind;
var s: string;
begin
  s := LowerCase(string(AStatus));
  if s = 'running' then       result := skBuy        // green = live
  else if s = 'pending' then  result := skInfo
  else if s = 'halted' then   result := skModify     // amber
  else if s = 'completed' then result := skMuted
  else if s = 'cancelled' then result := skMuted
  else if s = 'expired' then  result := skMuted
  else if s = 'error' then    result := skDelete     // red
  else                        result := skNeutral;
end;

// StatusLabel — what we show in the chip. Capitalises the wire form
// without changing it. 'running' → 'Running'.
function StatusLabel(const AStatus: RawUtf8): string;
var s: string;
begin
  s := string(AStatus);
  if s = '' then
    result := '—'
  else
    result := UpperCase(Copy(s, 1, 1)) + Copy(s, 2, MaxInt);
end;

// IsTerminalStatus — terminal statuses can't be halted/resumed/cancelled.
// Hide the action buttons so the operator doesn't try to PATCH a closed
// plan and get a daemon-side rejection back.
function IsTerminalStatus(const AStatus: RawUtf8): Boolean;
var s: string;
begin
  s := LowerCase(string(AStatus));
  result := (s = 'completed') or (s = 'cancelled') or (s = 'expired');
end;

// PosFrom — find ANeedle in AHaystack at or after AStart. FPC's stock
// Pos doesn't take an offset; named separately to keep the lookup
// helpers below readable.
function PosFrom(const ANeedle, AHaystack: string; AStart: Integer): Integer;
var
  cut: string;
  hit: Integer;
begin
  if AStart > Length(AHaystack) then
  begin
    result := 0;
    exit;
  end;
  cut := Copy(AHaystack, AStart, MaxInt);
  hit := Pos(ANeedle, cut);
  if hit = 0 then
    result := 0
  else
    result := hit + AStart - 1;
end;

// ExtractFirstString — first match of `"<AKey>":"<value>"` returned
// verbatim. Used for cheap top-level field lookups (capability,
// status) without spinning up a full _Json walk for every row render.
// Returns '' when not found.
function ExtractFirstString(const AKey: string; const ARaw: RawUtf8): string;
var
  s, marker: string;
  p, e: Integer;
begin
  result := '';
  s := string(ARaw);
  marker := '"' + AKey + '":"';
  p := Pos(marker, s);
  if p = 0 then exit;
  p := p + Length(marker);
  e := PosFrom('"', s, p);
  if e = 0 then exit;
  result := Copy(s, p, e - p);
end;

// InstrumentsSummary — pulls a short symbol list out of the plan's
// raw JSON for the grid cell. Plans usually carry 1-3 underlyings;
// we show all when small, "NIFTY · BANK · 2 more" when the basket
// gets busy.
function InstrumentsSummary(const ARawJson: RawUtf8): string;
var
  p, e: Integer;
  s, sym, inner: string;
  symbols: array of string;
  i, count, segStart: Integer;
begin
  // Cheap-but-honest scan of "symbol":"X" pairs scoped to the
  // instruments array. A full _Json+_Safe walk is overkill for a grid
  // cell that needs at most 3 strings.
  s := string(ARawJson);
  p := Pos('"instruments"', s);
  if p = 0 then
  begin
    result := '-';
    exit;
  end;
  e := PosFrom(']', s, p);
  if e = 0 then e := Length(s);
  inner := Copy(s, p, e - p + 1);

  symbols := nil;
  segStart := 1;
  while True do
  begin
    p := PosFrom('"symbol":"', inner, segStart);
    if p = 0 then break;
    p := p + Length('"symbol":"');
    e := PosFrom('"', inner, p);
    if e = 0 then break;
    sym := Copy(inner, p, e - p);
    if sym <> '' then
    begin
      SetLength(symbols, Length(symbols) + 1);
      symbols[High(symbols)] := sym;
    end;
    segStart := e + 1;
  end;

  count := Length(symbols);
  if count = 0 then
  begin
    result := '-';
    exit;
  end;
  if count = 1 then
    result := symbols[0]
  else if count <= 3 then
  begin
    result := symbols[0];
    for i := 1 to count - 1 do
      result := result + ' / ' + symbols[i];
  end
  else
  begin
    result := symbols[0] + ' / ' + symbols[1] + ' / ' +
              IntToStr(count - 2) + ' more';
  end;
end;

{ TPlansFrame ──────────────────────────────────────────────────────── }

constructor TPlansFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption    := '';

  BuildTopBar;

  FHeader := TPanel.Create(Self);
  FHeader.Parent     := Self;
  FHeader.Align      := alTop;
  FHeader.Height     := HEADER_HEIGHT;
  FHeader.BevelOuter := bvNone;
  FHeader.Caption    := '';
  BuildHeaderRow;

  FRowsHost := TScrollBox.Create(Self);
  FRowsHost.Parent      := Self;
  FRowsHost.Align       := alClient;
  FRowsHost.BorderStyle := bsNone;
  FRowsHost.HorzScrollBar.Visible := False;

  FEmptyCard := TPanel.Create(Self);
  FEmptyCard.Parent     := Self;
  FEmptyCard.Align      := alClient;
  FEmptyCard.BevelOuter := bvNone;
  FEmptyCard.Caption    := '';
  FEmptyCard.Visible    := False;
  BuildEmptyCard;

  ShowEmpty;
end;

procedure TPlansFrame.BuildTopBar;
var
  miOpt, miGamma: TMenuItem;
begin
  FTopBar := TPanel.Create(Self);
  FTopBar.Parent     := Self;
  FTopBar.Align      := alTop;
  FTopBar.Height     := TOPBAR_HEIGHT;
  FTopBar.BevelOuter := bvNone;
  FTopBar.Caption    := '';

  // Popup menu attached to "+ New plan" — capability picker. Wizard
  // takes over on selection.
  FNewPlanMenu := TPopupMenu.Create(Self);

  miOpt := TMenuItem.Create(FNewPlanMenu);
  miOpt.Caption := 'Options Scalper  —  multi-underlying intraday';
  miOpt.OnClick := DoNewOptionsScalper;
  FNewPlanMenu.Items.Add(miOpt);

  miGamma := TMenuItem.Create(FNewPlanMenu);
  miGamma.Caption := 'Gamma Scalper  —  expiry-day VIX-gated';
  miGamma.OnClick := DoNewGammaScalper;
  FNewPlanMenu.Items.Add(miGamma);

  FBtnNewPlan := TButton.Create(FTopBar);
  FBtnNewPlan.Parent     := FTopBar;
  FBtnNewPlan.Left       := 16;
  FBtnNewPlan.Top        := 14;
  FBtnNewPlan.Width      := 200;
  FBtnNewPlan.Height     := 36;
  FBtnNewPlan.Caption    := '+  New plan';
  FBtnNewPlan.Font.Style := [fsBold];
  FBtnNewPlan.OnClick    := DoNewPlanClick;
  SetSemantic(FBtnNewPlan, skPrimary);

  FLblInstance := TLabel.Create(FTopBar);
  FLblInstance.Parent  := FTopBar;
  FLblInstance.Caption := 'Session';
  FLblInstance.Left    := 240;
  FLblInstance.Top     := 24;
  FLblInstance.AutoSize := True;
  FLblInstance.Font.Height := -12;
  FLblInstance.ParentColor := True;
  FLblInstance.ParentFont  := False;
  SetSemantic(FLblInstance, skMuted);

  FCmbInstance := TComboBox.Create(FTopBar);
  FCmbInstance.Parent := FTopBar;
  FCmbInstance.Left   := 300;
  FCmbInstance.Top    := 20;
  FCmbInstance.Width  := 150;
  FCmbInstance.Style  := csDropDownList;
  FCmbInstance.OnChange := DoFilterChange;
  // Default: 'all'; SetInstanceOptions overwrites when MainForm loads
  // attached sessions.
  FCmbInstance.Items.Add('All sessions');
  FCmbInstance.ItemIndex := 0;

  // Status filter as tabs (per LookAndFeel.md design language —
  // tabs preferred for filter strips). 'Active' lumps pending+running+
  // halted: the default the operator usually wants.
  FStatusTabs := TTabControl.Create(FTopBar);
  FStatusTabs.Parent := FTopBar;
  FStatusTabs.Left   := 460;
  FStatusTabs.Top    := 8;
  FStatusTabs.Width  := 540;
  FStatusTabs.Height := 48;
  FStatusTabs.Tabs.Add('Active');
  FStatusTabs.Tabs.Add('All');
  FStatusTabs.Tabs.Add('Running');
  FStatusTabs.Tabs.Add('Halted');
  FStatusTabs.Tabs.Add('Completed');
  FStatusTabs.Tabs.Add('Cancelled');
  FStatusTabs.Tabs.Add('Error');
  FStatusTabs.TabIndex := 0;
  FStatusTabs.OnChange := DoFilterChange;
  FStatusTabs.Anchors := [akLeft, akTop, akRight];

  FBtnRefresh := TButton.Create(FTopBar);
  FBtnRefresh.Parent  := FTopBar;
  FBtnRefresh.Left    := 1010;
  FBtnRefresh.Top     := 18;
  FBtnRefresh.Width   := 80;
  FBtnRefresh.Height  := 30;
  FBtnRefresh.Caption := 'Refresh';
  FBtnRefresh.Anchors := [akTop, akRight];
  FBtnRefresh.OnClick := DoRefreshClick;
  SetSemantic(FBtnRefresh, skNeutral);
end;

procedure TPlansFrame.StyleColumnLabel(ALabel: TLabel;
  ALeft, AWidth: Integer; ABold: Boolean);
begin
  ALabel.Left   := ALeft;
  ALabel.Width  := AWidth;
  ALabel.Top    := 8;
  ALabel.Height := 16;
  ALabel.AutoSize := False;
  ALabel.ParentColor := True;
  ALabel.ParentFont  := False;
  ALabel.Font.Height := -12;
  if ABold then
  begin
    ALabel.Font.Style := [fsBold];
    SetSemantic(ALabel, skNeutral);
  end
  else
    SetSemantic(ALabel, skMuted);
end;

procedure TPlansFrame.BuildHeaderRow;
  function MakeHeader(const ACaption: string; ALeft, AWidth: Integer): TLabel;
  begin
    result := TLabel.Create(FHeader);
    result.Parent := FHeader;
    result.Caption := ACaption;
    StyleColumnLabel(result, ALeft, AWidth, False);
  end;
var
  lbl: TLabel;
begin
  lbl := MakeHeader('Plan',         COL_ID_X,      COL_ID_W);      lbl.Tag := 0;
  lbl := MakeHeader('Bot',          COL_BOT_X,     COL_BOT_W);     lbl.Tag := 0;
  lbl := MakeHeader('Status',       COL_STATUS_X,  COL_STATUS_W);  lbl.Tag := 0;
  lbl := MakeHeader('Instruments',  COL_INSTRS_X,  COL_INSTRS_W);  lbl.Tag := 0;
  lbl := MakeHeader('Updated',      COL_UPDATED_X, COL_UPDATED_W); lbl.Tag := 0;
  lbl := MakeHeader('Actions',      COL_ACTIONS_X, 240);           lbl.Tag := 0;
end;

procedure TPlansFrame.BuildEmptyCard;
var
  ttl, sub: TLabel;
  cta: TButton;
begin
  ttl := TLabel.Create(FEmptyCard);
  ttl.Parent := FEmptyCard;
  ttl.Caption := 'No plans yet';
  ttl.Left := 0; ttl.Top := 200; ttl.Width := 800; ttl.Height := 28;
  ttl.Alignment := taCenter;
  ttl.AutoSize := False;
  ttl.Font.Height := -22;
  ttl.Font.Style  := [fsBold];
  ttl.ParentColor := True;
  ttl.ParentFont  := False;
  SetSemantic(ttl, skNeutral);

  sub := TLabel.Create(FEmptyCard);
  sub.Parent := FEmptyCard;
  sub.Caption :=
    'A plan tells thoriumd which bot to run and how. ' +
    'Pick a bot to get started — the wizard will walk you through it.';
  sub.Left := 80; sub.Top := 240; sub.Width := 640; sub.Height := 36;
  sub.Alignment := taCenter;
  sub.WordWrap := True;
  sub.AutoSize := False;
  sub.Font.Height := -13;
  sub.ParentColor := True;
  sub.ParentFont  := False;
  SetSemantic(sub, skMuted);

  cta := TButton.Create(FEmptyCard);
  cta.Parent     := FEmptyCard;
  cta.Caption    := '+  Start a new plan';
  cta.Left       := 280; cta.Top := 296;
  cta.Width      := 240; cta.Height := 44;
  cta.Font.Height := -14;
  cta.Font.Style  := [fsBold];
  cta.ParentFont  := False;
  cta.OnClick     := DoNewPlanClick;
  SetSemantic(cta, skPrimary);
end;

function TPlansFrame.BuildPlanRow(const APlan: TPlanRef): TPanel;
  function MakeCell(AParent: TWinControl; const AText: string;
    ALeft, AWidth: Integer; ABold: Boolean): TLabel;
  begin
    result := TLabel.Create(AParent);
    result.Parent := AParent;
    result.Caption := AText;
    StyleColumnLabel(result, ALeft, AWidth, ABold);
    result.Top := (ROW_HEIGHT - 16) div 2;
  end;
  function MakeButton(AParent: TWinControl; const ACaption: string;
    ALeft: Integer; AKind: TSemanticKind;
    AOnClick: TNotifyEvent; ATag: PtrInt): TButton;
  begin
    result := TButton.Create(AParent);
    result.Parent  := AParent;
    result.Caption := ACaption;
    result.Left    := ALeft;
    result.Top     := (ROW_HEIGHT - 28) div 2;
    result.Width   := 76;
    result.Height  := 28;
    result.OnClick := AOnClick;
    result.Tag     := ATag;
    SetSemantic(result, AKind);
  end;
var
  row:        TPanel;
  rowIdx:     PtrInt;
  statusLbl:  TLabel;
  capLbl:     TLabel;
  haltCaption: string;
  haltKind:    TSemanticKind;
  isHalted:    Boolean;
  isTerminal:  Boolean;
begin
  rowIdx := Length(FRowPanels);
  row := TPanel.Create(FRowsHost);
  row.Parent     := FRowsHost;
  row.Left       := 0;
  row.Top        := rowIdx * (ROW_HEIGHT + 1);
  row.Width      := FRowsHost.ClientWidth;
  row.Height     := ROW_HEIGHT;
  row.Anchors    := [akLeft, akTop, akRight];
  row.BevelOuter := bvNone;
  row.Caption    := '';
  row.Tag        := rowIdx;

  MakeCell(row, ShortPlanId(APlan.PlanId),       COL_ID_X,      COL_ID_W,      True);

  // Capability isn't a TPlanRef field today (PlanList's serializer
  // copies only id/instance/status/note/updated_at) — pull it out of
  // the raw plan body. ExtractFirstString is cheap; one cell render
  // cost is negligible against the network round-trip we just paid.
  capLbl := MakeCell(row,
    CapabilityLabel(RawUtf8(ExtractFirstString('capability', APlan.Raw))),
    COL_BOT_X, COL_BOT_W, False);
  if capLbl.Caption = '' then capLbl.Caption := '-';

  statusLbl := MakeCell(row, StatusLabel(APlan.Status),
                        COL_STATUS_X, COL_STATUS_W, True);
  SetSemantic(statusLbl, StatusKind(APlan.Status));

  MakeCell(row, InstrumentsSummary(APlan.Raw),  COL_INSTRS_X, COL_INSTRS_W, False);
  MakeCell(row, ShortTime(APlan.UpdatedAt),     COL_UPDATED_X, COL_UPDATED_W, False);

  isTerminal := IsTerminalStatus(APlan.Status);
  isHalted   := LowerCase(string(APlan.Status)) = 'halted';

  // View is always available — even for cancelled plans the operator
  // may want to read the original body or the patch history.
  MakeButton(row, 'View',   COL_ACTIONS_X +   0, skInfo,    DoViewRow,         rowIdx);

  if not isTerminal then
  begin
    if isHalted then
    begin
      haltCaption := 'Resume';
      haltKind    := skBuy;     // green = re-arming
    end
    else
    begin
      haltCaption := 'Halt';
      haltKind    := skModify;  // amber = pause-with-positions-open
    end;
    MakeButton(row, haltCaption, COL_ACTIONS_X +  82, haltKind, DoHaltOrResumeRow, rowIdx);
    MakeButton(row, 'Cancel',    COL_ACTIONS_X + 164, skCancel, DoCancelRow,       rowIdx);
  end;

  result := row;
end;

procedure TPlansFrame.ClearRows;
var
  i: Integer;
begin
  for i := 0 to High(FRowPanels) do
    FRowPanels[i].Free;
  FRowPanels := nil;
end;

procedure TPlansFrame.SetPlans(const APlans: TPlanRefArray);
var
  i: Integer;
begin
  ClearRows;
  SetLength(FPlans, Length(APlans));
  for i := 0 to High(APlans) do
    FPlans[i] := APlans[i];

  if Length(APlans) = 0 then
  begin
    ShowEmpty;
    exit;
  end;
  ShowList;
  SetLength(FRowPanels, Length(APlans));
  for i := 0 to High(APlans) do
    FRowPanels[i] := BuildPlanRow(APlans[i]);
  Radium.Gui.Theme.Apply(Self);
end;

procedure TPlansFrame.SetInstanceOptions(const AInstanceIds: array of RawUtf8);
var
  i: Integer;
begin
  FCmbInstance.Items.BeginUpdate;
  try
    FCmbInstance.Items.Clear;
    FCmbInstance.Items.Add('All sessions');
    for i := 0 to High(AInstanceIds) do
      FCmbInstance.Items.Add(string(AInstanceIds[i]));
  finally
    FCmbInstance.Items.EndUpdate;
  end;
  FCmbInstance.ItemIndex := 0;
end;

function TPlansFrame.SelectedInstance: RawUtf8;
begin
  if (FCmbInstance.ItemIndex <= 0) then
    result := ''
  else
    result := RawUtf8(FCmbInstance.Items[FCmbInstance.ItemIndex]);
end;

function TPlansFrame.SelectedStatus: RawUtf8;
begin
  // 'All' returns ''; 'Active' is a synthetic filter the caller
  // expands to (pending|running|halted) before issuing PlanList.
  case FStatusTabs.TabIndex of
    0: result := 'active';
    1: result := '';
    2: result := 'running';
    3: result := 'halted';
    4: result := 'completed';
    5: result := 'cancelled';
    6: result := 'error';
  else
    result := '';
  end;
end;

procedure TPlansFrame.ShowEmpty;
begin
  FRowsHost.Visible := False;
  FHeader.Visible   := False;
  FEmptyCard.Visible := True;
end;

procedure TPlansFrame.ShowList;
begin
  FEmptyCard.Visible := False;
  FRowsHost.Visible := True;
  FHeader.Visible   := True;
end;

{ ── handlers ─────────────────────────────────────────────────────── }

procedure TPlansFrame.DoNewPlanClick(Sender: TObject);
var
  pt: TPoint;
begin
  // Pop the capability menu just below the button so the operator's
  // eye stays in the same vertical rail.
  pt.X := 0;
  pt.Y := FBtnNewPlan.Height + 2;
  pt := FBtnNewPlan.ClientToScreen(pt);
  FNewPlanMenu.PopUp(pt.X, pt.Y);
end;

procedure TPlansFrame.DoNewOptionsScalper(Sender: TObject);
begin
  if Assigned(FOnNewPlan) then
    FOnNewPlan(Self, pcOptionsScalper);
end;

procedure TPlansFrame.DoNewGammaScalper(Sender: TObject);
begin
  if Assigned(FOnNewPlan) then
    FOnNewPlan(Self, pcGammaScalper);
end;

procedure TPlansFrame.DoRefreshClick(Sender: TObject);
begin
  if Assigned(FOnRefresh) then
    FOnRefresh(Self);
end;

procedure TPlansFrame.DoFilterChange(Sender: TObject);
begin
  if Assigned(FOnFilterChanged) then
    FOnFilterChanged(Self);
end;

procedure TPlansFrame.DoViewRow(Sender: TObject);
var idx: PtrInt;
begin
  if not (Sender is TButton) then exit;
  idx := TButton(Sender).Tag;
  if (idx < 0) or (idx > High(FPlans)) then exit;
  if Assigned(FOnView) then
    FOnView(Self, FPlans[idx]);
end;

procedure TPlansFrame.DoHaltOrResumeRow(Sender: TObject);
var
  idx: PtrInt;
  isHalted: Boolean;
begin
  if not (Sender is TButton) then exit;
  idx := TButton(Sender).Tag;
  if (idx < 0) or (idx > High(FPlans)) then exit;
  isHalted := LowerCase(string(FPlans[idx].Status)) = 'halted';
  if isHalted then
  begin
    if Assigned(FOnResume) then FOnResume(Self, FPlans[idx]);
  end
  else
  begin
    if Assigned(FOnHalt) then FOnHalt(Self, FPlans[idx]);
  end;
end;

procedure TPlansFrame.DoCancelRow(Sender: TObject);
var idx: PtrInt;
begin
  if not (Sender is TButton) then exit;
  idx := TButton(Sender).Tag;
  if (idx < 0) or (idx > High(FPlans)) then exit;
  if Assigned(FOnCancel) then
    FOnCancel(Self, FPlans[idx]);
end;

end.
