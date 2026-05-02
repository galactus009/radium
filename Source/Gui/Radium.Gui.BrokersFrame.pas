unit Radium.Gui.BrokersFrame;

{$IFDEF FPC}{$mode Delphi}{$ENDIF}{$H+}

// TBrokersFrame — sidebar destination that bundles broker sessions and
// thoriumd status into a single panel with two tabs. It owns nothing
// new on the wire; the tabs reuse the existing TSessionsFrame and
// TStatusFrame as-is, so MainForm wires their events through the
// public Sessions/Status accessors and treats this frame as a
// container.
//
// Tab 1 — Sessions: attach/modify/detach/promote against thoriumd's
//   /api/sessions surface (same as the old "Broker Sessions" panel).
// Tab 2 — Status:   /status snapshot with auto-refresh (same as the
//   old "Status" panel).
//
// The merge is purely UI: combining "who's attached" and "what's the
// daemon doing right now" under one Brokers entry. Nothing in the
// child frames changed.

interface

uses
  Classes,
  SysUtils,
  Controls,
  ExtCtrls,
  ComCtrls,
  Radium.Gui.SessionsFrame,
  Radium.Gui.StatusFrame;

type

  { TBrokersFrame }
  TBrokersFrame = class(TPanel)
  private
    FTabs:     TPageControl;
    FTabSess:  TTabSheet;
    FTabStat:  TTabSheet;
    FSessions: TSessionsFrame;
    FStatus:   TStatusFrame;
  public
    constructor Create(AOwner: TComponent); override;

    // Direct accessors so MainForm can hook events / push data without
    // a second event-forwarding layer. They are owned by the tab
    // sheets via the component tree, not by MainForm.
    property Sessions: TSessionsFrame read FSessions;
    property Status:   TStatusFrame   read FStatus;

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

  FTabSess := TTabSheet.Create(FTabs);
  FTabSess.PageControl := FTabs;
  FTabSess.Caption := 'Sessions';

  FTabStat := TTabSheet.Create(FTabs);
  FTabStat.PageControl := FTabs;
  FTabStat.Caption := 'Status';

  FSessions := TSessionsFrame.Create(FTabSess);
  FSessions.Parent := FTabSess;
  FSessions.Align  := alClient;

  FStatus := TStatusFrame.Create(FTabStat);
  FStatus.Parent := FTabStat;
  FStatus.Align  := alClient;
end;

end.
