unit Radium.Gui.MainForm;

(* ----------------------------------------------------------------------------
  Radium main window — sidebar-driven shell.

  Layout (per Docs/LookAndFeel.md §5):

    +----------------+----------------------------------+
    | RADIUM         |                                  |
    | thoriumd       |  Welcome card (default)          |
    | console        |   - or -                         |
    |                |  Sessions frame (when            |
    | ▣ Broker Sess. |   "Broker Sessions" clicked)     |
    | ▣ Status       |                                  |
    | ▣ Plans        |                                  |
    | ▣ Risk         |                                  |
    | ▣ AI           |                                  |
    | (spring)       |                                  |
    | ▣ Settings     |                                  |
    | ◐ Light/Dark   |                                  |
    +----------------+----------------------------------+
    | conn ▶  feed: live  •  inst: alpha  •  09:14 IST  |
    +---------------------------------------------------+

  TThoriumClient ownership: this form owns one client built from the
  persisted Settings after EnsureSettings completes. Worker threads
  in slice 3.x will share that single instance — until then every
  call is on the GUI thread (and the longest one, /login, blocks for
  the catalogue load).

  Multi-broker assumption: every call site that touches a session
  takes an instance_id explicitly. There is no "current session"
  singleton; the Sessions frame is a list that drives the UX.
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  Classes,
  SysUtils,
  Forms,
  Controls,
  Graphics,
  Dialogs,
  ExtCtrls,
  ComCtrls,
  StdCtrls,
  Buttons,
  Variants,
  mormot.core.base,
  mormot.core.json,
  mormot.core.text,
  mormot.core.variants,
  Radium.Api.Types,
  Radium.Api.Client,
  Radium.Plans.Runner,
  Radium.Clerk.Types,
  Radium.Clerk.Analyzer,
  Radium.Gui.SessionsFrame,
  Radium.Gui.StatusFrame,
  Radium.Gui.BrokersFrame,
  Radium.Gui.PlansFrame,
  Radium.Gui.RiskFrame,
  Radium.Gui.ClerkFrame,
  Radium.Gui.AiFrame,
  Radium.Gui.ChatFrame;

type
  TStatusSlot = (ssConnection, ssFeed, ssInstance, ssClock);

  { TMainForm }
  TMainForm = class(TForm)
    SidebarHost:        TPanel;
      SidebarTopGroup:  TPanel;
        BrandLabel:     TLabel;
        BrandTagline:   TLabel;
        BtnBrokers:     TSpeedButton;
        BtnPlans:       TSpeedButton;
        BtnRisk:        TSpeedButton;
        BtnClerk:       TSpeedButton;
        BtnAi:          TSpeedButton;
      SidebarSpring:    TPanel;
      SidebarBotGroup:  TPanel;
        BtnSettings:    TSpeedButton;
        BtnTheme:       TSpeedButton;
    SidebarDivider:     TBevel;
    CenterHost:         TPanel;
      WelcomeCard:      TPanel;
        WelcomeTitle:   TLabel;
        WelcomeBody:    TLabel;
        DocsHint:       TLabel;
        StatusDot:      TShape;
        StatusDotLabel: TLabel;
    StatusBar:          TStatusBar;
    ClockTimer:         TTimer;

    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure ClockTimerTimer(Sender: TObject);

    procedure BtnBrokersClick(Sender: TObject);
    procedure BtnPlansClick(Sender: TObject);
    procedure BtnRiskClick(Sender: TObject);
    procedure BtnClerkClick(Sender: TObject);
    procedure BtnAiClick(Sender: TObject);
    procedure BtnSettingsClick(Sender: TObject);
    procedure BtnThemeClick(Sender: TObject);

  private
    FClient:         TThoriumClient;
    FPlanRunner:     TPlanRunner;
    FBrokersFrame:   TBrokersFrame;
    FPlansFrame:     TPlansFrame;
    FRiskFrame:      TRiskFrame;
    FClerkFrame:     TClerkFrame;
    FAiFrame:        TAiFrame;
    FHeartbeatTimer: TTimer;
    FStatusTimer:    TTimer;
    FCachedSessions: TStatusSessionArray;

    procedure SetStatus(ASlot: TStatusSlot; const AText: string);
    procedure ApplyActiveTheme;
    procedure NotImplemented(const AFeature: string);
    procedure EnsureSettings;
    procedure EnsureClient;
    function  HostForError: string;

    procedure ShowBrokersFrame(AStatusTab: Boolean);
    procedure ShowPlansFrame;
    procedure ShowRiskFrame;
    procedure ShowClerkFrame;
    procedure ShowAiFrame;
    procedure HideAllFrames;
    procedure HeartbeatTick(Sender: TObject);
    procedure StatusTimerTick(Sender: TObject);
    procedure RefreshBrokers;
    procedure StatusReload(Sender: TObject);
    procedure StatusAutoToggle(Sender: TObject);
    procedure RefreshPlans;
    procedure RefreshRisk;
    procedure UpdateConnectionStatusBar;

    procedure SessionsAttach(Sender: TObject);
    procedure SessionsModify(Sender: TObject;
      const ASession: TStatusSession);
    procedure SessionsDetach(Sender: TObject;
      const ASession: TStatusSession);
    procedure SessionsPromote(Sender: TObject;
      const ASession: TStatusSession);

    procedure PlansNew(Sender: TObject; ACapability: TPlanCapability);
    procedure PlansView(Sender: TObject; const APlan: TPlanRef);
    procedure PlansHalt(Sender: TObject; const APlan: TPlanRef);
    procedure PlansResume(Sender: TObject; const APlan: TPlanRef);
    procedure PlansCancel(Sender: TObject; const APlan: TPlanRef);
    procedure PlansRefresh(Sender: TObject);
    procedure PlansFilterChanged(Sender: TObject);

    procedure RiskLoad(Sender: TObject);
    procedure RiskSave(Sender: TObject; const APatch: TRiskPatch);

    procedure ClerkRunRequested(Sender: TObject;
      const ARequest: TClerkRunRequest);
    function ClerkSymbolLookup(const ASymbol, AExchange: RawUtf8): TInstrumentClassification;

    procedure AiLoad(Sender: TObject);
    procedure AiSave(Sender: TObject; const APayload: TAiConfigurePayload);
    procedure ChatAsk(Sender: TObject; const ARequest: TChatAskRequest);

    procedure RefreshAi;
  public
  end;

var
  MainForm: TMainForm;

implementation

uses
  mormot.net.client,
  Radium.Gui.Theme,
  Radium.Settings,
  Radium.Gui.SetupForm,
  Radium.Gui.AttachBrokerForm,
  Radium.Gui.NewPlanWizard,
  Radium.Gui.Errors;

{$R *.lfm}

{ TMainForm ─────────────────────────────────────────────────────────── }

procedure TMainForm.FormCreate(Sender: TObject);
begin
  EnsureSettings;

  SetStatus(ssConnection, 'disconnected');
  SetStatus(ssFeed,       'feed: -');
  SetStatus(ssInstance,   'instance: -');
  SetStatus(ssClock,      FormatDateTime('hh:nn', Now) + ' IST');

  SetSemantic(BrandLabel,    skPrimary);
  SetSemantic(BrandTagline,  skMuted);
  SetSemantic(BtnBrokers,    skPrimary);
  SetSemantic(BtnPlans,      skNeutral);
  SetSemantic(BtnRisk,       skNeutral);
  SetSemantic(BtnAi,         skNeutral);
  SetSemantic(BtnSettings,   skNeutral);
  SetSemantic(BtnTheme,      skMuted);
  SetSemantic(WelcomeTitle,  skPrimary);
  SetSemantic(WelcomeBody,   skNeutral);
  SetSemantic(DocsHint,      skMuted);
  SetSemantic(StatusDotLabel, skMuted);

  ApplyActiveTheme;

  // Heartbeat — pings thoriumd every 15s and paints the status dot
  // green / red accordingly. Built programmatically (not in the LFM)
  // because the timer plumbs into FClient which doesn't exist at LFM
  // load time. Interval is generous: ping is cheap, but tighter
  // beats add no signal — a real outage gets caught within 15s.
  FHeartbeatTimer := TTimer.Create(Self);
  FHeartbeatTimer.Interval := 15000;
  FHeartbeatTimer.OnTimer := HeartbeatTick;
  FHeartbeatTimer.Enabled := True;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  // Frames are parented to CenterHost which the form owns — the LCL
  // Component tree frees them. FClient + FPlanRunner are plain
  // objects we own directly. Free runner first since it borrows the
  // client pointer (no ownership) — order doesn't strictly matter
  // (no destructor work touches the borrowed pointer) but keep it
  // intuitive.
  FreeAndNil(FPlanRunner);
  FreeAndNil(FClient);
end;

procedure TMainForm.ClockTimerTimer(Sender: TObject);
begin
  SetStatus(ssClock, FormatDateTime('hh:nn', Now) + ' IST');
end;

procedure TMainForm.SetStatus(ASlot: TStatusSlot; const AText: string);
begin
  StatusBar.Panels[Ord(ASlot)].Text := AText;
end;

procedure TMainForm.ApplyActiveTheme;
begin
  Radium.Gui.Theme.Apply(Self);
  StatusDot.Brush.Color := Token(tDanger);
  SidebarDivider.Color := Token(tBorderSubtle);
  case ActiveTheme of
    tkLight: BtnTheme.Caption := 'Theme: Light';
    tkDark:  BtnTheme.Caption := 'Theme: Dark';
  end;
end;

procedure TMainForm.NotImplemented(const AFeature: string);
begin
  ShowMessage(AFeature + ' — not yet wired (coming in a later slice).');
end;

procedure TMainForm.EnsureSettings;
var
  s:   TRadiumSettings;
  dlg: TSetupForm;
begin
  if LoadSettings(s) and IsValid(s) then
    exit;
  dlg := TSetupForm.CreateForKind(Self, skFirstRun, s);
  try
    dlg.ShowModal;
  finally
    dlg.Free;
  end;
end;

procedure TMainForm.EnsureClient;
var
  s: TRadiumSettings;
begin
  if FClient <> nil then
    exit;
  if not (LoadSettings(s) and IsValid(s)) then
    raise Exception.Create(
      'Settings missing - open Settings to enter host and API key.');
  FClient := TThoriumClient.Create(s.Host, s.Apikey);
  // PlanRunner borrows the client; lifetimes line up because both
  // are reset together in BtnSettingsClick when the operator updates
  // host or apikey.
  FPlanRunner := TServerPlanRunner.Create(FClient);
end;

function TMainForm.HostForError: string;
var
  s: TRadiumSettings;
begin
  // Fallback chain so error dialogs can name the host even before
  // FClient exists (e.g. settings just got cleared).
  if FClient <> nil then
    result := string(FClient.BaseUrl)
  else if LoadSettings(s) then
    result := string(s.Host)
  else
    result := '(host not configured)';
end;

{ ── sidebar handlers ─────────────────────────────────────────────── }

procedure TMainForm.BtnBrokersClick(Sender: TObject);
begin
  // Single sidebar destination → both tabs of TBrokersFrame. One
  // /status call updates both tabs in lockstep.
  ShowBrokersFrame(False);
  RefreshBrokers;
end;

procedure TMainForm.BtnPlansClick(Sender: TObject);
begin
  ShowPlansFrame;
  RefreshPlans;
end;

procedure TMainForm.BtnRiskClick(Sender: TObject);
begin
  ShowRiskFrame;
  RefreshRisk;
end;

procedure TMainForm.BtnClerkClick(Sender: TObject);
begin
  ShowClerkFrame;
end;

procedure TMainForm.BtnAiClick(Sender: TObject);
begin
  ShowAiFrame;
  RefreshAi;
end;

procedure TMainForm.BtnSettingsClick(Sender: TObject);
var
  loaded: TRadiumSettings;
  dlg:    TSetupForm;
begin
  LoadSettings(loaded);
  dlg := TSetupForm.CreateForKind(Self, skEdit, loaded);
  try
    if dlg.ShowModal = mrOk then
    begin
      // Settings changed → drop the old client; next call rebuilds
      // it against the new host / apikey. Existing thoriumd-side
      // sessions stay attached; we just stop talking to them with
      // stale credentials. Runner holds a borrowed pointer to the
      // old client, so it goes too.
      FreeAndNil(FPlanRunner);
      FreeAndNil(FClient);
    end;
  finally
    dlg.Free;
  end;
end;

procedure TMainForm.BtnThemeClick(Sender: TObject);
begin
  case ActiveTheme of
    tkLight: SetActiveTheme(tkDark);
    tkDark:  SetActiveTheme(tkLight);
  end;
  ApplyActiveTheme;
end;

{ ── frame plumbing ───────────────────────────────────────────────── }

procedure TMainForm.HideAllFrames;
begin
  // Sidebar destinations share CenterHost. Hiding everything before
  // showing the chosen frame keeps the destination switch a single
  // assignment, no z-order surprises.
  WelcomeCard.Visible := False;
  if FBrokersFrame <> nil then FBrokersFrame.Visible := False;
  if FPlansFrame <> nil then FPlansFrame.Visible := False;
  if FRiskFrame <> nil then FRiskFrame.Visible := False;
  if FClerkFrame <> nil then FClerkFrame.Visible := False;
  if FAiFrame <> nil then FAiFrame.Visible := False;
  // Pause the status auto-refresh whenever Brokers isn't visible —
  // no point burning /status calls when the operator is on Plans /
  // Risk / etc. Resumed in ShowBrokersFrame.
  if FStatusTimer <> nil then FStatusTimer.Enabled := False;
end;

procedure TMainForm.ShowBrokersFrame(AStatusTab: Boolean);
begin
  HideAllFrames;
  if FBrokersFrame = nil then
  begin
    FBrokersFrame := TBrokersFrame.Create(Self);
    FBrokersFrame.Parent := CenterHost;
    FBrokersFrame.Align  := alClient;

    // Sessions-tab event wiring (same as the old standalone frame).
    FBrokersFrame.Sessions.OnAttachClicked  := SessionsAttach;
    FBrokersFrame.Sessions.OnModifyClicked  := SessionsModify;
    FBrokersFrame.Sessions.OnDetachClicked  := SessionsDetach;
    FBrokersFrame.Sessions.OnPromoteClicked := SessionsPromote;

    // Status-tab event wiring.
    FBrokersFrame.Status.OnReload     := StatusReload;
    FBrokersFrame.Status.OnAutoToggle := StatusAutoToggle;

    Radium.Gui.Theme.Apply(FBrokersFrame);
  end
  else
    FBrokersFrame.Visible := True;

  if AStatusTab then
    FBrokersFrame.Tabs.ActivePageIndex := 1
  else
    FBrokersFrame.Tabs.ActivePageIndex := 0;

  // Spin up (or resume) the 5s status auto-refresh while Brokers is
  // visible. HideAllFrames pauses it.
  if FStatusTimer = nil then
  begin
    FStatusTimer := TTimer.Create(Self);
    FStatusTimer.Interval := 5000;
    FStatusTimer.OnTimer := StatusTimerTick;
  end;
  FStatusTimer.Enabled := FBrokersFrame.Status.AutoRefreshEnabled;
end;

procedure TMainForm.ShowPlansFrame;
begin
  HideAllFrames;
  if FPlansFrame = nil then
  begin
    FPlansFrame := TPlansFrame.Create(Self);
    FPlansFrame.Parent := CenterHost;
    FPlansFrame.Align  := alClient;
    FPlansFrame.OnNewPlanClicked  := PlansNew;
    FPlansFrame.OnViewPlanClicked := PlansView;
    FPlansFrame.OnHaltClicked     := PlansHalt;
    FPlansFrame.OnResumeClicked   := PlansResume;
    FPlansFrame.OnCancelClicked   := PlansCancel;
    FPlansFrame.OnRefreshClicked  := PlansRefresh;
    FPlansFrame.OnFilterChanged   := PlansFilterChanged;
    Radium.Gui.Theme.Apply(FPlansFrame);
  end
  else
    FPlansFrame.Visible := True;
end;

procedure TMainForm.ShowRiskFrame;
begin
  HideAllFrames;
  if FRiskFrame = nil then
  begin
    FRiskFrame := TRiskFrame.Create(Self);
    FRiskFrame.Parent := CenterHost;
    FRiskFrame.Align  := alClient;
    FRiskFrame.OnLoad := RiskLoad;
    FRiskFrame.OnSave := RiskSave;
    Radium.Gui.Theme.Apply(FRiskFrame);
  end
  else
    FRiskFrame.Visible := True;
end;

procedure TMainForm.ShowClerkFrame;
var
  i: Integer;
  instOpts: array of RawUtf8;
begin
  HideAllFrames;
  if FClerkFrame = nil then
  begin
    FClerkFrame := TClerkFrame.Create(Self);
    FClerkFrame.Parent := CenterHost;
    FClerkFrame.Align  := alClient;
    FClerkFrame.OnRunRequested := ClerkRunRequested;
    Radium.Gui.Theme.Apply(FClerkFrame);
  end
  else
    FClerkFrame.Visible := True;

  if Length(FCachedSessions) > 0 then
  begin
    SetLength(instOpts, Length(FCachedSessions));
    for i := 0 to High(FCachedSessions) do
      instOpts[i] := FCachedSessions[i].InstanceId;
    FClerkFrame.SetInstanceOptions(instOpts);
  end;
end;

procedure TMainForm.ShowAiFrame;
begin
  HideAllFrames;
  if FAiFrame = nil then
  begin
    FAiFrame := TAiFrame.Create(Self);
    FAiFrame.Parent := CenterHost;
    FAiFrame.Align  := alClient;
    FAiFrame.OnLoad := AiLoad;
    FAiFrame.OnSave := AiSave;
    FAiFrame.OnChatAskRequested := ChatAsk;
    Radium.Gui.Theme.Apply(FAiFrame);
  end
  else
    FAiFrame.Visible := True;
end;

procedure TMainForm.RefreshBrokers;
var
  status: TStatusResult;
begin
  if FBrokersFrame = nil then
    exit;
  // Single /status call, fed into both tabs of the Brokers panel —
  // Sessions (interactive list) and Status (read-only summary +
  // metrics). Earlier the two tabs ran independent /status fetches
  // and drifted: an attach handled by the Sessions tab refreshed
  // only itself, while the 5s Status timer would later see the new
  // session and disagree with what Sessions still showed (or vice
  // versa). One fetch → one rendering → tabs are always in sync.
  try
    EnsureClient;
    Screen.Cursor := crHourGlass;
    try
      status := FClient.Status;
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      ShowMessage(HumanError(E, 'Refresh brokers', HostForError));
      SetLength(FCachedSessions, 0);
      FBrokersFrame.Sessions.SetSessions(FCachedSessions);
      FBrokersFrame.Status.SetStatusText(
        'Refresh failed: ' + E.Message, -1);
      UpdateConnectionStatusBar;
      exit;
    end;
  end;

  FCachedSessions := status.Sessions;
  FBrokersFrame.Sessions.SetSessions(FCachedSessions);
  FBrokersFrame.Status.SetStatus(status);
  FBrokersFrame.Status.SetStatusText(
    'Updated ' + FormatDateTime('hh:nn:ss', Now) + ' IST.', 0);
  UpdateConnectionStatusBar;
end;

procedure TMainForm.UpdateConnectionStatusBar;
var
  feedIdx: Integer;
  i:       Integer;
begin
  if Length(FCachedSessions) = 0 then
  begin
    SetStatus(ssConnection, 'disconnected');
    SetStatus(ssFeed,       'feed: -');
    SetStatus(ssInstance,   'instance: -');
    StatusDot.Brush.Color := Token(tDanger);
    StatusDotLabel.Caption := 'no broker attached';
    exit;
  end;

  feedIdx := -1;
  for i := 0 to High(FCachedSessions) do
    if FCachedSessions[i].IsFeedBroker then
    begin
      feedIdx := i;
      break;
    end;

  if Length(FCachedSessions) = 1 then
    SetStatus(ssConnection, 'connected (1 session)')
  else
    SetStatus(ssConnection,
      Format('connected (%d sessions)', [Length(FCachedSessions)]));
  if feedIdx >= 0 then
  begin
    SetStatus(ssFeed,
      'feed: ' + string(FCachedSessions[feedIdx].Broker));
    SetStatus(ssInstance,
      'instance: ' + string(FCachedSessions[feedIdx].InstanceId));
    StatusDot.Brush.Color := Token(tSuccess);
    StatusDotLabel.Caption := 'connected to thoriumd';
  end
  else
  begin
    SetStatus(ssFeed, 'feed: none');
    SetStatus(ssInstance,
      'instance: ' + string(FCachedSessions[0].InstanceId));
    StatusDot.Brush.Color := Token(tWarning);
    StatusDotLabel.Caption := 'attached, no feed broker';
  end;
end;

{ ── sessions actions: attach / modify / detach / promote ─────────── }

procedure TMainForm.SessionsAttach(Sender: TObject);
var
  dlg: TAttachBrokerForm;
begin
  dlg := TAttachBrokerForm.CreateForKind(Self, abFresh, '', '');
  try
    if dlg.ShowModal <> mrOk then
      exit;
    try
      EnsureClient;
      Screen.Cursor := crHourGlass;
      try
        FClient.Login(
          dlg.Broker, dlg.WireToken, dlg.InstanceId, dlg.FeedHint);
      finally
        Screen.Cursor := crDefault;
      end;
    except
      on E: Exception do
      begin
        ShowMessage(HumanError(E, 'Attach broker', HostForError));
        exit;
      end;
    end;
    RefreshBrokers;
  finally
    dlg.Free;
  end;
end;

procedure TMainForm.SessionsModify(Sender: TObject;
  const ASession: TStatusSession);
var
  dlg: TAttachBrokerForm;
begin
  dlg := TAttachBrokerForm.CreateForKind(Self, abModify,
    ASession.Broker, ASession.InstanceId);
  try
    if dlg.ShowModal <> mrOk then
      exit;
    try
      EnsureClient;
      Screen.Cursor := crHourGlass;
      try
        FClient.Refresh(
          dlg.Broker, dlg.WireToken, dlg.InstanceId, dlg.FeedHint);
      finally
        Screen.Cursor := crDefault;
      end;
    except
      on E: Exception do
      begin
        ShowMessage(HumanError(E, 'Modify session', HostForError));
        exit;
      end;
    end;
    RefreshBrokers;
  finally
    dlg.Free;
  end;
end;

procedure TMainForm.SessionsDetach(Sender: TObject;
  const ASession: TStatusSession);
begin
  if MessageDlg('Detach broker session',
       Format(
         'Detach session "%s"?' + LineEnding + LineEnding +
         'Open positions stay open at the broker. Pending orders ' +
         'submitted by bots stop being managed until you re-attach.',
         [string(ASession.InstanceId)]),
       mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    exit;

  try
    EnsureClient;
    Screen.Cursor := crHourGlass;
    try
      FClient.Logout(ASession.InstanceId);
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      ShowMessage(HumanError(E, 'Detach session', HostForError));
      exit;
    end;
  end;
  RefreshBrokers;
end;

procedure TMainForm.SessionsPromote(Sender: TObject;
  const ASession: TStatusSession);
begin
  // Maps to thoriumd's POST /admin/promote_feed endpoint; not yet a
  // typed method on TThoriumClient. Slice 3.x folds it in alongside
  // /search (Catalogue panel) and Status auto-refresh.
  NotImplemented('Promote feed (instance ' + string(ASession.InstanceId) + ')');
end;

{ ── plans frame wiring ─────────────────────────────────────────────── }

procedure TMainForm.RefreshPlans;
var
  filter: RawUtf8;
  instId: RawUtf8;
  statuses: array of RawUtf8;
  plans: TPlanRefArray;
  i: Integer;
  instOpts: array of RawUtf8;
begin
  if FPlansFrame = nil then exit;

  // Update the instance dropdown so the picker reflects current
  // attached sessions. RefreshBrokers populates FCachedSessions; we
  // borrow that.
  if Length(FCachedSessions) > 0 then
  begin
    SetLength(instOpts, Length(FCachedSessions));
    for i := 0 to High(FCachedSessions) do
      instOpts[i] := FCachedSessions[i].InstanceId;
    FPlansFrame.SetInstanceOptions(instOpts);
  end;

  filter := FPlansFrame.SelectedStatus;
  instId := FPlansFrame.SelectedInstance;

  statuses := nil;
  if filter = 'active' then
  begin
    SetLength(statuses, 3);
    statuses[0] := 'pending';
    statuses[1] := 'running';
    statuses[2] := 'halted';
  end
  else if filter <> '' then
  begin
    SetLength(statuses, 1);
    statuses[0] := filter;
  end;

  try
    EnsureClient;
    Screen.Cursor := crHourGlass;
    try
      plans := FPlanRunner.List(instId, statuses);
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      ShowMessage(HumanError(E, 'Refresh plans', HostForError));
      FPlansFrame.SetPlans(nil);
      exit;
    end;
  end;
  FPlansFrame.SetPlans(plans);
end;

procedure TMainForm.PlansNew(Sender: TObject; ACapability: TPlanCapability);
var
  wiz: TNewPlanWizard;
  statusSnap: TStatusResult;
  rawBody: RawUtf8;
begin
  // Wizard needs the live session list so its session-picker is
  // accurate. We refresh /status here on demand rather than trusting
  // FCachedSessions — operators sometimes leave the Plans tab open
  // for a while.
  try
    EnsureClient;
    Screen.Cursor := crHourGlass;
    try
      statusSnap := FClient.Status;
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      ShowMessage(HumanError(E, 'Open New Plan wizard', HostForError));
      exit;
    end;
  end;

  if Length(statusSnap.Sessions) = 0 then
  begin
    ShowMessage(
      'No broker sessions are attached.' + LineEnding + LineEnding +
      'A plan needs a broker to trade through. Attach a broker from ' +
      'the Broker Sessions panel, then come back to Plans.');
    exit;
  end;

  wiz := TNewPlanWizard.CreateWizard(Self, ACapability, statusSnap.Sessions);
  try
    if wiz.ShowModal <> mrOk then exit;
    try
      Screen.Cursor := crHourGlass;
      try
        rawBody := FPlanRunner.Submit(wiz.Result);
      finally
        Screen.Cursor := crDefault;
      end;
    except
      on E: Exception do
      begin
        ShowMessage(HumanError(E, 'Create plan', HostForError));
        exit;
      end;
    end;
    // rawBody contains the full success body including the new
    // plan_id. The Plans frame refresh fetches the updated list, so
    // we don't bother decoding here — operator sees the new row.
    if rawBody = '' then ; // touch to suppress unused-result warning
    ShowMessage('Plan created. The bot will start as soon as the ' +
                'dispatcher picks it up.');
    RefreshPlans;
  finally
    wiz.Free;
  end;
end;

procedure TMainForm.PlansView(Sender: TObject; const APlan: TPlanRef);
var
  fullBody: RawUtf8;
  dlg: TForm;
  memo: TMemo;
begin
  try
    EnsureClient;
    Screen.Cursor := crHourGlass;
    try
      fullBody := FPlanRunner.GetPlan(APlan.PlanId, APlan.InstanceId);
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      ShowMessage(HumanError(E, 'View plan', HostForError));
      exit;
    end;
  end;

  // Inline read-only viewer — minimum viable; v2 swaps this for an
  // edit-mode wizard that pre-fills from this body.
  dlg := TForm.CreateNew(Self);
  try
    dlg.Caption := 'Plan ' + string(APlan.PlanId);
    dlg.Width := 720;
    dlg.Height := 560;
    dlg.Position := poScreenCenter;
    dlg.BorderStyle := bsSizeable;
    memo := TMemo.Create(dlg);
    memo.Parent := dlg;
    memo.Align := alClient;
    memo.ScrollBars := ssAutoBoth;
    memo.ReadOnly := True;
    memo.Font.Name := 'Menlo';
    memo.Font.Height := -12;
    memo.ParentFont := False;
    memo.Text := string(fullBody);
    Radium.Gui.Theme.Apply(dlg);
    dlg.ShowModal;
  finally
    dlg.Free;
  end;
end;

procedure TMainForm.PlansHalt(Sender: TObject; const APlan: TPlanRef);
begin
  if MessageDlg('Halt plan',
       Format('Halt plan %s?' + LineEnding + LineEnding +
              'The bot will stop opening new positions. Existing ' +
              'positions stay live and continue to be managed by ' +
              'their stop-loss / take-profit / trail rules. ' +
              'You can resume the plan at any time.',
              [string(APlan.PlanId)]),
       mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    exit;
  try
    EnsureClient;
    Screen.Cursor := crHourGlass;
    try
      FPlanRunner.HaltPlan(APlan.PlanId, APlan.InstanceId);
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      ShowMessage(HumanError(E, 'Halt plan', HostForError));
      exit;
    end;
  end;
  RefreshPlans;
end;

procedure TMainForm.PlansResume(Sender: TObject; const APlan: TPlanRef);
begin
  if MessageDlg('Resume plan',
       Format('Resume plan %s?' + LineEnding + LineEnding +
              'The bot will start opening new positions again, ' +
              'subject to its entry window and risk caps.',
              [string(APlan.PlanId)]),
       mtConfirmation, [mbYes, mbNo], 0) <> mrYes then
    exit;
  try
    EnsureClient;
    Screen.Cursor := crHourGlass;
    try
      FPlanRunner.ResumePlan(APlan.PlanId, APlan.InstanceId);
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      ShowMessage(HumanError(E, 'Resume plan', HostForError));
      exit;
    end;
  end;
  RefreshPlans;
end;

procedure TMainForm.PlansCancel(Sender: TObject; const APlan: TPlanRef);
begin
  if MessageDlg('Cancel plan',
       Format('Cancel plan %s?' + LineEnding + LineEnding +
              'The bot stops managing positions. Open positions stay ' +
              'open at the broker — you become responsible for them. ' +
              'This is irreversible.',
              [string(APlan.PlanId)]),
       mtWarning, [mbYes, mbNo], 0) <> mrYes then
    exit;
  try
    EnsureClient;
    Screen.Cursor := crHourGlass;
    try
      FPlanRunner.Cancel(APlan.PlanId, APlan.InstanceId);
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      ShowMessage(HumanError(E, 'Cancel plan', HostForError));
      exit;
    end;
  end;
  RefreshPlans;
end;

procedure TMainForm.PlansRefresh(Sender: TObject);
begin
  RefreshPlans;
end;

procedure TMainForm.PlansFilterChanged(Sender: TObject);
begin
  RefreshPlans;
end;

{ ── risk frame wiring ──────────────────────────────────────────────── }

procedure TMainForm.RefreshRisk;
var
  rk: TRiskConfig;
  i: Integer;
  instOpts: array of RawUtf8;
begin
  if FRiskFrame = nil then exit;
  // Populate the scope picker so the per-broker option is visible
  // (read-only today). Same instance list the Plans frame uses.
  if Length(FCachedSessions) > 0 then
  begin
    SetLength(instOpts, Length(FCachedSessions));
    for i := 0 to High(FCachedSessions) do
      instOpts[i] := FCachedSessions[i].InstanceId;
    FRiskFrame.SetInstanceOptions(instOpts);
  end;

  try
    EnsureClient;
    FRiskFrame.SetStatusText('Loading from thoriumd...', 0);
    Screen.Cursor := crHourGlass;
    try
      rk := FClient.RiskGet;
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      FRiskFrame.SetStatusText('Could not load risk: ' + E.Message, -1);
      ShowMessage(HumanError(E, 'Load risk', HostForError));
      exit;
    end;
  end;
  FRiskFrame.SetRisk(rk);
  FRiskFrame.SetStatusText('Loaded ' + FormatDateTime('hh:nn', Now) + ' IST.', 0);
end;

procedure TMainForm.RiskLoad(Sender: TObject);
begin
  RefreshRisk;
end;

procedure TMainForm.RiskSave(Sender: TObject; const APatch: TRiskPatch);
var
  rk: TRiskConfig;
begin
  try
    EnsureClient;
    Screen.Cursor := crHourGlass;
    try
      rk := FClient.RiskSet(APatch);
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      FRiskFrame.SetStatusText('Save failed: ' + E.Message, -1);
      ShowMessage(HumanError(E, 'Save risk', HostForError));
      exit;
    end;
  end;
  // Successful save → take the just-saved values as the new baseline
  // for "modified vs original" detection on the next save.
  FRiskFrame.CommitSavedSnapshot(rk);
  FRiskFrame.SetStatusText('Saved ' + FormatDateTime('hh:nn', Now) + ' IST.', 1);
end;

{ ── clerk frame wiring ─────────────────────────────────────────────── }

function TMainForm.ClerkSymbolLookup(const ASymbol, AExchange: RawUtf8): TInstrumentClassification;
var
  raw: RawUtf8;
  data: variant;
  d: PDocVariantData;
  itype: RawUtf8;
  lot:   Integer;
begin
  // Method-of-object the analyzer calls for each unique
  // (symbol, exchange). Hits /api/v1/symbol; cheap on the analyzer
  // side because that unit caches per-key. Returns Found=False on
  // miss so the analyzer falls back to suffix heuristics.
  result.Found    := False;
  result.InstType := '';
  result.LotSize  := 0;

  if FClient = nil then exit;
  raw := FClient.SymbolLookup(ASymbol, AExchange);
  if raw = '' then exit;
  data := _Json(raw);
  if VarIsEmptyOrNull(data) then exit;
  d := _Safe(data);
  itype := RawUtf8(d^.U['instrument_type']);
  lot   := d^.I['lot_size'];

  // Map the daemon's verbose codes ('OPT_CE'/'FUT_IDX') to clerk's
  // short form. The analyzer does the same mapping in
  // ClassifyByPattern; we keep this mapping here so the lookup result
  // is "ready to use" downstream.
  if Pos('OPT', string(itype)) = 1 then result.InstType := 'OPT'
  else if Pos('FUT', string(itype)) = 1 then result.InstType := 'FUT'
  else if (itype = 'EQ') or (itype = 'EQUITY') then result.InstType := 'EQ'
  else if itype = 'ETF' then result.InstType := 'ETF'
  else exit; // genuinely unknown → caller falls back to pattern.

  if lot < 1 then lot := 1;
  result.LotSize := lot;
  result.Found   := True;
end;

procedure TMainForm.ClerkRunRequested(Sender: TObject;
  const ARequest: TClerkRunRequest);
var
  tradebookJson, positionbookJson, orderbookJson: RawUtf8;
  report: TClerkReport;
begin
  if not ARequest.IsToday then
  begin
    // Past dates need the SQLite store. The store layer ships next
    // iteration (see memory: clerk_in_radium.md). Today we tell the
    // operator clearly rather than fake history.
    FClerkFrame.SetStatusText(
      'Stored reports require the Radium SQLite store ' +
      '(coming in the next iteration). Pick today to run live.', -1);
    exit;
  end;

  try
    EnsureClient;
    FClerkFrame.SetStatusText('Fetching tradebook + positions from thoriumd...', 0);
    Screen.Cursor := crHourGlass;
    try
      tradebookJson    := FClient.TradebookGet(ARequest.InstanceId);
      positionbookJson := FClient.PositionbookGet(ARequest.InstanceId);
      orderbookJson    := FClient.OrderbookGetSafe(ARequest.InstanceId);
      report := AnalyzeRaw(tradebookJson, positionbookJson, orderbookJson,
                           ClerkSymbolLookup);
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      FClerkFrame.SetStatusText('Run failed: ' + E.Message, -1);
      ShowMessage(HumanError(E, 'Run clerk', HostForError));
      exit;
    end;
  end;

  FClerkFrame.SetReport(report);
  FClerkFrame.SetStatusText(string(report.SourceLabel), 1);
end;

{ ── ai frame wiring ────────────────────────────────────────────────── }

procedure TMainForm.RefreshAi;
var snap: TAiConfigSnapshot;
begin
  if FAiFrame = nil then exit;
  try
    EnsureClient;
    FAiFrame.SetStatusText('Loading AI config...', 0);
    Screen.Cursor := crHourGlass;
    try
      snap := FClient.AiShow;
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      FAiFrame.SetStatusText('Could not load: ' + E.Message, -1);
      ShowMessage(HumanError(E, 'Load AI config', HostForError));
      exit;
    end;
  end;
  FAiFrame.SetSnapshot(snap);
  FAiFrame.SetStatusText(
    'Loaded ' + FormatDateTime('hh:nn', Now) + ' IST.', 0);
end;

procedure TMainForm.AiLoad(Sender: TObject);
begin
  RefreshAi;
end;

procedure TMainForm.AiSave(Sender: TObject; const APayload: TAiConfigurePayload);
var
  freshSnap: TAiConfigSnapshot;
begin
  if APayload.Provider = '' then
  begin
    FAiFrame.SetStatusText('Pick a provider before saving.', -1);
    exit;
  end;
  try
    EnsureClient;
    Screen.Cursor := crHourGlass;
    try
      // Server takes "" for model/base_url to mean "use provider default".
      // Our payload preserves the operator's blank → empty wire.
      FClient.AiConfigure(APayload.Provider, APayload.ApiKey,
                          APayload.Model, APayload.BaseUrl);
      // /admin/ai/configure replies with just {message}; re-fetch the
      // snapshot so the "current" card reflects what actually persisted.
      freshSnap := FClient.AiShow;
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      FAiFrame.SetStatusText('Save failed: ' + E.Message, -1);
      ShowMessage(HumanError(E, 'Save AI config', HostForError));
      exit;
    end;
  end;
  FAiFrame.SetSnapshot(freshSnap);
  FAiFrame.SetStatusText(
    'Saved ' + FormatDateTime('hh:nn', Now) + ' IST.', 1);
end;

procedure TMainForm.ChatAsk(Sender: TObject;
  const ARequest: TChatAskRequest);
var
  reply: RawUtf8;
  body, parsed: variant;
  bodyJson, askUrl, response: RawUtf8;
  c: TSimpleHttpClient;
  http: Integer;
  msgs: TDocVariantData;
  url: RawUtf8;
begin
  if FAiFrame = nil then exit;

  reply := '';
  case ARequest.Backend of
    cbThoriumd:
    begin
      try
        EnsureClient;
        Screen.Cursor := crHourGlass;
        try
          // Server-side AI route. ARequest.Context already encodes prior
          // turns as a flat string; no model override here — server uses
          // whatever was set via /admin/ai/configure.
          reply := FClient.AiAsk(ARequest.Prompt, ARequest.System,
                                 ARequest.Context, '');
        finally
          Screen.Cursor := crDefault;
        end;
      except
        on E: Exception do
        begin
          FAiFrame.AppendChatReply(
            RawUtf8('thoriumd: ' + E.Message), False);
          exit;
        end;
      end;
      FAiFrame.AppendChatReply(reply, True);
    end;

    cbOllamaLocal:
    begin
      // Ollama's /api/chat takes a messages array. We compose:
      //   [system?, context (as one user-turn synthetic), prompt]
      // Keeping this dumb-and-direct so chat still works when thoriumd
      // is offline. Stream:false so we get a single response object.
      msgs.InitArray([], JSON_FAST_FLOAT);
      if ARequest.System <> '' then
        msgs.AddItem(_ObjFast([
          'role',    'system',
          'content', ARequest.System
        ]));
      if ARequest.Context <> '' then
        msgs.AddItem(_ObjFast([
          'role',    'user',
          'content', ARequest.Context
        ]));
      msgs.AddItem(_ObjFast([
        'role',    'user',
        'content', ARequest.Prompt
      ]));

      body := _ObjFast([
        'model',    ARequest.OllamaModel,
        'stream',   False,
        'messages', Variant(msgs)
      ]);
      bodyJson := VariantSaveJson(body);

      url := ARequest.OllamaUrl;
      if url = '' then url := 'http://127.0.0.1:11434';
      // Strip trailing slash so concatenation stays clean.
      while (url <> '') and (url[Length(url)] = '/') do
        SetLength(url, Length(url) - 1);
      askUrl := url + '/api/chat';

      c := TSimpleHttpClient.Create;
      try
        c.Options^.CreateTimeoutMS := 60000;
        Screen.Cursor := crHourGlass;
        try
          try
            http := c.Request(askUrl, 'POST', '', bodyJson,
                              'application/json');
          except
            on E: Exception do
            begin
              FAiFrame.AppendChatReply(
                RawUtf8('ollama: ' + E.Message), False);
              exit;
            end;
          end;
          response := c.Body;
        finally
          Screen.Cursor := crDefault;
        end;
      finally
        c.Free;
      end;

      if (http < 200) or (http >= 300) then
      begin
        FAiFrame.AppendChatReply(
          RawUtf8('ollama HTTP ' + IntToStr(http) + ': ' + string(response)),
          False);
        exit;
      end;

      parsed := _Json(response);
      if VarIsEmptyOrNull(parsed) then
      begin
        FAiFrame.AppendChatReply(
          RawUtf8('ollama: non-JSON response'), False);
        exit;
      end;
      // /api/chat shape: { message: { role, content }, done: true, ... }
      reply := _Safe(_Safe(parsed)^.GetValueOrRaiseException('message'))^.U['content'];
      if reply = '' then
        reply := RawUtf8('(empty reply)');
      FAiFrame.AppendChatReply(reply, True);
    end;
  end;
end;

{ ── status frame wiring ────────────────────────────────────────────── }

procedure TMainForm.StatusReload(Sender: TObject);
begin
  RefreshBrokers;
end;

procedure TMainForm.StatusAutoToggle(Sender: TObject);
begin
  if (FStatusTimer <> nil) and (FBrokersFrame <> nil) then
    FStatusTimer.Enabled := FBrokersFrame.Status.AutoRefreshEnabled;
end;

procedure TMainForm.StatusTimerTick(Sender: TObject);
begin
  // Bail if the panel isn't visible — covers the brief window between
  // HideAllFrames and the next ShowBrokersFrame click. Cheap insurance.
  if (FBrokersFrame = nil) or (not FBrokersFrame.Visible) then
  begin
    if FStatusTimer <> nil then FStatusTimer.Enabled := False;
    exit;
  end;
  RefreshBrokers;
end;

{ ── connection-status heartbeat ────────────────────────────────────── }

// Periodic /ping to thoriumd. The status dot in the welcome card and
// the connection slot of the StatusBar reflect this — independent of
// whichever frame the operator is currently looking at. Without it
// the operator only learns about a network drop the next time they
// click a sidebar button, which is too late.
//
// We use /ping (not /status) because the ping handler's payload is
// trivial — under a kilobyte — and the round-trip is what we care
// about, not the contents. /status is heavier and costs more per beat.
procedure TMainForm.HeartbeatTick(Sender: TObject);
var
  pong: TPingResult;
begin
  // Skip the beat if FClient isn't built yet (settings dialog still
  // open on first run, etc). The next click that calls EnsureClient
  // will rehydrate it; we just stay quiet until then.
  if FClient = nil then exit;
  try
    pong := FClient.Ping;
    SetStatus(ssConnection,
      Format('connected (%dms)', [Round(pong.RoundTripMs)]));
    StatusDot.Brush.Color := Token(tSuccess);
    StatusDotLabel.Caption := 'connected to thoriumd';
  except
    on E: Exception do
    begin
      // Don't spam ShowMessage from a timer — too disruptive for a
      // transient network blip. Surface in the status bar; if the
      // operator clicks an action it will surface there with full
      // HumanError formatting.
      SetStatus(ssConnection, 'no connection');
      StatusDot.Brush.Color := Token(tDanger);
      StatusDotLabel.Caption :=
        'thoriumd unreachable - check ' + HostForError;
    end;
  end;
end;

end.
