unit Radium.Gui.SessionsFrame;

(* ----------------------------------------------------------------------------
  Sessions frame — the centre-host content for the "Broker Sessions"
  sidebar destination.

  Multi-broker first. thoriumd's session model is multi-tenant
  (instance_id keyed); Radium's view of it is a list, never a "current
  session" singleton. Empty state, single-session, three-way attach
  all use the same row-panel layout — no special-casing.

  Visual layout:

    +- Broker Sessions ─────────────────────────────────────────────+
    |  [+ Attach a Broker]                                          |  ← skPrimary
    |                                                               |
    |  ┌───────┬────────┬───────────┬─────────┬───────┬───────────┐ |
    |  │ Inst  │ Broker │ Role      │Cat. Rows│Attach │ Actions   │ |  ← header
    |  └───────┴────────┴───────────┴─────────┴───────┴───────────┘ |
    |  ┌───────┬────────┬───────────┬─────────┬───────┬───────────┐ |
    |  │ alpha │ fyers  │ Data+REST │ 148,231 │ 09:14 │ [M][D][P] │ |  ← row
    |  └───────┴────────┴───────────┴─────────┴───────┴───────────┘ |
    |  …                                                            |
    +───────────────────────────────────────────────────────────────+

  Empty state replaces the whole content area with a centred
  "no sessions attached" card and a single big CTA — modern empty
  states reduce cognitive load (Docs/LookAndFeel.md design language).

  Built programmatically (no .lfm) so each row's controls — labels +
  semantic-tagged buttons — can be created from a session record in
  one place. A .lfm + LFM streaming would force a fixed cap on row
  count or duplicate template declarations.

  Action wiring: the frame doesn't call the API itself. It raises
  events (OnAttachClicked / OnModifyClicked / OnDetachClicked /
  OnPromoteClicked) that MainForm hooks; MainForm owns the
  TThoriumClient and the GUI<->API choreography.
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  Classes,
  SysUtils,
  Forms,
  Controls,
  Graphics,
  ExtCtrls,
  StdCtrls,
  Buttons,
  mormot.core.base,
  Radium.Api.Types;

type
  // One handler signature for every row action — the InstanceID
  // identifies the session uniquely. The frame owner switches on
  // intent, not on which button raised it.
  TSessionActionEvent = procedure(Sender: TObject;
    const ASession: TStatusSession) of object;

  TAttachClickEvent = procedure(Sender: TObject) of object;

  { TSessionsFrame — slot under CenterHost. Built lazily by MainForm. }
  TSessionsFrame = class(TPanel)
  private
    FAttachBar:    TPanel;
    FBtnAttach:    TButton;
    FRowsHost:     TScrollBox;
    FHeader:       TPanel;
    FEmptyCard:    TPanel;
    FRowPanels:    array of TPanel;
    FSessions:     TStatusSessionArray;   // parallel to FRowPanels

    FOnAttach:     TAttachClickEvent;
    FOnModify:     TSessionActionEvent;
    FOnDetach:     TSessionActionEvent;
    FOnPromote:    TSessionActionEvent;

    procedure DoAttach(Sender: TObject);
    procedure DoModifyRow(Sender: TObject);
    procedure DoDetachRow(Sender: TObject);
    procedure DoPromoteRow(Sender: TObject);
    procedure ClearRows;
    procedure BuildEmptyCard;
    procedure BuildHeaderRow;
    function  BuildSessionRow(const ASession: TStatusSession): TPanel;
    procedure ShowEmpty;
    procedure ShowList;
    procedure StyleColumnLabel(ALabel: TLabel; ALeft, AWidth: Integer;
      ABold: Boolean);
  public
    constructor Create(AOwner: TComponent); override;

    // Replace the rendered list with this snapshot. Pass an empty
    // array to render the empty state. Idempotent — call after every
    // /status round-trip.
    procedure SetSessions(const ASessions: TStatusSessionArray);

    property OnAttachClicked:  TAttachClickEvent     read FOnAttach  write FOnAttach;
    property OnModifyClicked:  TSessionActionEvent   read FOnModify  write FOnModify;
    property OnDetachClicked:  TSessionActionEvent   read FOnDetach  write FOnDetach;
    property OnPromoteClicked: TSessionActionEvent   read FOnPromote write FOnPromote;
  end;

implementation

uses
  Radium.Gui.Theme;

const
  COL_INSTANCE_X = 16;   COL_INSTANCE_W = 120;
  COL_BROKER_X   = 144;  COL_BROKER_W   = 100;
  COL_ROLE_X     = 252;  COL_ROLE_W     = 120;
  COL_ROWS_X     = 380;  COL_ROWS_W     = 110;
  COL_TIME_X     = 498;  COL_TIME_W     = 130;
  COL_ACTIONS_X  = 636;
  ROW_HEIGHT     = 56;
  HEADER_HEIGHT  = 32;

// FormatRowCount — 148231 → "148,231". Tiny readability win that
// matters on the panel where the operator scans counts at a glance.
function FormatRowCount(AValue: Integer): string;
var
  s: string;
  i, gap: Integer;
begin
  s := IntToStr(AValue);
  result := '';
  gap := 0;
  for i := Length(s) downto 1 do
  begin
    if (gap = 3) then
    begin
      result := ',' + result;
      gap := 0;
    end;
    result := s[i] + result;
    Inc(gap);
  end;
end;

// Catalog timestamps arrive as RFC3339 (e.g. "2026-05-02T09:14:23Z").
// The grid only needs the local HH:MM tail; full timestamp is in the
// Status panel's metrics grid for power users.
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

function RoleLabel(const ASession: TStatusSession): string;
begin
  if ASession.IsFeedBroker then
    result := 'Data + REST'
  else
    result := 'REST only';
end;

{ TSessionsFrame ───────────────────────────────────────────────────── }

constructor TSessionsFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption    := '';

  // [+ Attach a Broker] bar at the top — alTop, fixed height.
  FAttachBar := TPanel.Create(Self);
  FAttachBar.Parent     := Self;
  FAttachBar.Align      := alTop;
  FAttachBar.Height     := 64;
  FAttachBar.BevelOuter := bvNone;
  FAttachBar.Caption    := '';

  FBtnAttach := TButton.Create(FAttachBar);
  FBtnAttach.Parent     := FAttachBar;
  FBtnAttach.Left       := 16;
  FBtnAttach.Top        := 14;
  FBtnAttach.Width      := 200;
  FBtnAttach.Height     := 36;
  FBtnAttach.Caption    := '+  Attach a broker';
  FBtnAttach.Font.Style := [fsBold];
  FBtnAttach.OnClick    := DoAttach;
  SetSemantic(FBtnAttach, skPrimary);

  // Header row — never moves with scroll.
  FHeader := TPanel.Create(Self);
  FHeader.Parent     := Self;
  FHeader.Align      := alTop;
  FHeader.Height     := HEADER_HEIGHT;
  FHeader.BevelOuter := bvNone;
  FHeader.Caption    := '';
  BuildHeaderRow;

  // Scroll host. Each session row is a child of FRowsHost; SetSessions
  // recreates them on every refresh.
  FRowsHost := TScrollBox.Create(Self);
  FRowsHost.Parent      := Self;
  FRowsHost.Align       := alClient;
  FRowsHost.BorderStyle := bsNone;
  FRowsHost.HorzScrollBar.Visible := False;

  // Empty-state card lives over the scroll host; toggled visible by
  // ShowEmpty / ShowList. It sits above by virtue of being created
  // last and parented to the frame, not the scrollbox.
  FEmptyCard := TPanel.Create(Self);
  FEmptyCard.Parent     := Self;
  FEmptyCard.Align      := alClient;
  FEmptyCard.BevelOuter := bvNone;
  FEmptyCard.Caption    := '';
  FEmptyCard.Visible    := False;
  BuildEmptyCard;

  ShowEmpty;
end;

procedure TSessionsFrame.StyleColumnLabel(ALabel: TLabel;
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

procedure TSessionsFrame.BuildHeaderRow;
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
  lbl := MakeHeader('Instance',     COL_INSTANCE_X, COL_INSTANCE_W); lbl.Tag := 0;
  lbl := MakeHeader('Broker',       COL_BROKER_X,   COL_BROKER_W);   lbl.Tag := 0;
  lbl := MakeHeader('Role',         COL_ROLE_X,     COL_ROLE_W);     lbl.Tag := 0;
  lbl := MakeHeader('Catalogue',    COL_ROWS_X,     COL_ROWS_W);     lbl.Tag := 0;
  lbl := MakeHeader('Attached',     COL_TIME_X,     COL_TIME_W);     lbl.Tag := 0;
  lbl := MakeHeader('Actions',      COL_ACTIONS_X,  240);            lbl.Tag := 0;
end;

procedure TSessionsFrame.BuildEmptyCard;
var
  ttl, sub: TLabel;
  cta:      TButton;
begin
  ttl := TLabel.Create(FEmptyCard);
  ttl.Parent := FEmptyCard;
  ttl.Caption := 'No brokers attached yet';
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
    'Attach your first broker to read market data and place orders ' +
    'through thoriumd. You can attach more than one at a time.';
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
  cta.Caption    := '+  Attach Your First Broker';
  cta.Left       := 280; cta.Top := 296;
  cta.Width      := 240; cta.Height := 44;
  cta.Font.Height := -14;
  cta.Font.Style  := [fsBold];
  cta.ParentFont  := False;
  cta.OnClick     := DoAttach;
  SetSemantic(cta, skPrimary);
end;

function TSessionsFrame.BuildSessionRow(const ASession: TStatusSession): TPanel;
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
    result.Width   := 78;
    result.Height  := 28;
    result.OnClick := AOnClick;
    result.Tag     := ATag;
    SetSemantic(result, AKind);
  end;
var
  row:        TPanel;
  promoteKind: TSemanticKind;
  rowIdx:     PtrInt;
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
  // Tag carries the row index so action handlers can find the right
  // session in MainForm without keeping a separate registry.
  row.Tag        := rowIdx;

  MakeCell(row, string(ASession.InstanceId), COL_INSTANCE_X, COL_INSTANCE_W, True);
  MakeCell(row, string(ASession.Broker),     COL_BROKER_X,   COL_BROKER_W,   False);
  MakeCell(row, RoleLabel(ASession),         COL_ROLE_X,     COL_ROLE_W,     False);
  MakeCell(row, FormatRowCount(ASession.CatalogRows), COL_ROWS_X, COL_ROWS_W, False);
  MakeCell(row, ShortTime(ASession.CatalogLoadedAt),  COL_TIME_X, COL_TIME_W, False);

  // Promote button is greyed out (skMuted) when this session is
  // already the feed — no-op semantics, no need for a red accent.
  if ASession.IsFeedBroker then
    promoteKind := skMuted
  else
    promoteKind := skInfo;

  MakeButton(row, 'Modify',  COL_ACTIONS_X +   0, skModify, DoModifyRow,  rowIdx);
  MakeButton(row, 'Detach',  COL_ACTIONS_X +  84, skDelete, DoDetachRow,  rowIdx);
  MakeButton(row, 'Promote', COL_ACTIONS_X + 168, promoteKind, DoPromoteRow, rowIdx);

  result := row;
end;

procedure TSessionsFrame.ClearRows;
var
  i: Integer;
begin
  for i := 0 to High(FRowPanels) do
    FRowPanels[i].Free;
  FRowPanels := nil;
end;

procedure TSessionsFrame.SetSessions(const ASessions: TStatusSessionArray);
var
  i: Integer;
begin
  ClearRows;
  // Store a private copy aligned with FRowPanels so action handlers
  // can resolve a button's row in O(1) via Tag — no cell-content
  // archaeology that breaks the moment columns rearrange.
  SetLength(FSessions, Length(ASessions));
  for i := 0 to High(ASessions) do
    FSessions[i] := ASessions[i];

  if Length(ASessions) = 0 then
  begin
    ShowEmpty;
    exit;
  end;
  ShowList;
  SetLength(FRowPanels, Length(ASessions));
  for i := 0 to High(ASessions) do
    FRowPanels[i] := BuildSessionRow(ASessions[i]);
  // Force a theme re-apply on the new tree so semantic tags painted
  // during construction also pick up the right TColor for the active
  // theme.
  Radium.Gui.Theme.Apply(Self);
end;

procedure TSessionsFrame.ShowEmpty;
begin
  FRowsHost.Visible := False;
  FHeader.Visible   := False;
  FEmptyCard.Visible := True;
end;

procedure TSessionsFrame.ShowList;
begin
  FEmptyCard.Visible := False;
  FRowsHost.Visible := True;
  FHeader.Visible   := True;
end;

{ ── action plumbing ───────────────────────────────────────────────── }

procedure TSessionsFrame.DoAttach(Sender: TObject);
begin
  if Assigned(FOnAttach) then
    FOnAttach(Self);
end;

// The three row-action dispatchers share one shape: pull the row
// index from the sender's Tag (set in BuildSessionRow as `rowIdx`),
// look up the matching session in FSessions, and forward to the
// owner's handler. Tag → index → record stays correct under any
// column reorder; the previous Caption-of-first-cell trick did not.
procedure TSessionsFrame.DoModifyRow(Sender: TObject);
var
  idx: PtrInt;
begin
  if not (Sender is TButton) then exit;
  idx := TButton(Sender).Tag;
  if (idx < 0) or (idx > High(FSessions)) then exit;
  if Assigned(FOnModify) then
    FOnModify(Self, FSessions[idx]);
end;

procedure TSessionsFrame.DoDetachRow(Sender: TObject);
var
  idx: PtrInt;
begin
  if not (Sender is TButton) then exit;
  idx := TButton(Sender).Tag;
  if (idx < 0) or (idx > High(FSessions)) then exit;
  if Assigned(FOnDetach) then
    FOnDetach(Self, FSessions[idx]);
end;

procedure TSessionsFrame.DoPromoteRow(Sender: TObject);
var
  idx: PtrInt;
begin
  if not (Sender is TButton) then exit;
  idx := TButton(Sender).Tag;
  if (idx < 0) or (idx > High(FSessions)) then exit;
  if Assigned(FOnPromote) then
    FOnPromote(Self, FSessions[idx]);
end;

end.
