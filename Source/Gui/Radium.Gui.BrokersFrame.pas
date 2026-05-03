unit Radium.Gui.BrokersFrame;

{$IFDEF FPC}{$mode Delphi}{$ENDIF}{$H+}

// TBrokersFrame — sidebar destination labelled "Thorium Server" in
// the nav. Bundles three thoriumd-facing surfaces under one panel:
//
//   Tab 0 — Status:   /status snapshot with auto-refresh. Default
//                     landing tab; the operator's first question is
//                     usually "is the daemon up + are my brokers
//                     healthy", and Status answers both.
//   Tab 1 — Sessions: attach/modify/detach/promote against thoriumd's
//                     /api/sessions surface.
//   Tab 2 — Risk:     /api/risk knobs (cutoff, max-loss, max-lots…).
//                     Lives here rather than as a separate sidebar
//                     entry so all daemon-side state sits under one
//                     destination — the operator clicks "Thorium
//                     Server" to inspect or change anything that
//                     affects the daemon.
//
// The tabs reuse the existing TStatusFrame / TSessionsFrame / TRiskFrame
// as-is; MainForm wires their events through the public accessors
// and treats this frame as a container. Class name kept as
// TBrokersFrame for diff economy — the user-visible label is the
// only naming change the rename brought.

interface

uses
  Classes,
  SysUtils,
  Controls,
  ExtCtrls,
  ComCtrls,
  Radium.Gui.SessionsFrame,
  Radium.Gui.StatusFrame,
  Radium.Gui.RiskFrame;

type

  { TBrokersFrame }
  TBrokersFrame = class(TPanel)
  private
    FTabs:     TPageControl;
    FTabStat:  TTabSheet;
    FTabSess:  TTabSheet;
    FTabRisk:  TTabSheet;
    FStatus:   TStatusFrame;
    FSessions: TSessionsFrame;
    FRisk:     TRiskFrame;
  public
    constructor Create(AOwner: TComponent); override;

    // Direct accessors so MainForm can hook events / push data without
    // a second event-forwarding layer. They are owned by the tab
    // sheets via the component tree, not by MainForm.
    property Status:   TStatusFrame   read FStatus;
    property Sessions: TSessionsFrame read FSessions;
    property Risk:     TRiskFrame     read FRisk;

    property Tabs: TPageControl read FTabs;
  end;

implementation

constructor TBrokersFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption    := '';

  FTabs := TPageControl.Create(Self);
  FTabs.Parent := Self;
  FTabs.Align  := alClient;

  // Tab order: Status first (default landing), then Sessions, then
  // Risk. Status answers "is the daemon healthy" — it's what the
  // operator wants on first glance after switching to this panel.
  FTabStat := TTabSheet.Create(FTabs);
  FTabStat.PageControl := FTabs;
  FTabStat.Caption := 'Status';

  FTabSess := TTabSheet.Create(FTabs);
  FTabSess.PageControl := FTabs;
  FTabSess.Caption := 'Sessions';

  FTabRisk := TTabSheet.Create(FTabs);
  FTabRisk.PageControl := FTabs;
  FTabRisk.Caption := 'Risk';

  FStatus := TStatusFrame.Create(FTabStat);
  FStatus.Parent := FTabStat;
  FStatus.Align  := alClient;

  FSessions := TSessionsFrame.Create(FTabSess);
  FSessions.Parent := FTabSess;
  FSessions.Align  := alClient;

  FRisk := TRiskFrame.Create(FTabRisk);
  FRisk.Parent := FTabRisk;
  FRisk.Align  := alClient;

  FTabs.ActivePageIndex := 0;
end;

end.
