unit Radium.Gui.MainForm;

(* ----------------------------------------------------------------------------
  Radium main window — sidebar-driven shell.

  Layout (per Docs/LookAndFeel.md §5):

    +----------------+----------------------------------+
    | RADIUM         |                                  |
    | thoriumd       |  Welcome card (default)          |
    | console        |   - or -                         |
    |                |  Thorium Server frame (when      |
    | ▣ ThoriumSrv   |   the nav button is clicked) —   |
    | ▣ Trade        |   Status / Sessions / Risk tabs. |
    | ▣ Plans        |                                  |
    | ▣ Clerk        |                                  |
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
  Radium.Gui.ChatFrame,
  Radium.Gui.Icons,
  Radium.Gui.NavButton,
  Radium.Trading.Types,
  Radium.Trading.Validator,
  Radium.Gui.SymbolSearch,
  Radium.Gui.TradeFrame;

type
  TStatusSlot = (ssConnection, ssFeed, ssInstance, ssClock);

  { TMainForm }
  TMainForm = class(TForm)
    SidebarHost:        TPanel;
      SidebarTopGroup:  TPanel;
        BrandLabel:     TLabel;
        BrandTagline:   TLabel;
      SidebarSpring:    TPanel;
      SidebarBotGroup:  TPanel;
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

  private
    FClient:         TThoriumClient;
    FPlanRunner:     TPlanRunner;
    FBrokersFrame:   TBrokersFrame;
    FPlansFrame:     TPlansFrame;
    FClerkFrame:     TClerkFrame;
    FAiFrame:        TAiFrame;
    FTradeFrame:     TTradeFrame;
    FHeartbeatTimer: TTimer;
    FStatusTimer:    TTimer;
    FCachedSessions: TStatusSessionArray;

    // Nav buttons — built programmatically in BuildSidebar so we can
    // host an icon font + caption in a compound widget. The toggle
    // collapses captions and shrinks the host width.
    FNavToggle:      TNavButton;
    FNavBrokers:     TNavButton;
    FNavTrade:       TNavButton;
    FNavPlans:       TNavButton;
    FNavClerk:       TNavButton;
    FNavAi:          TNavButton;
    FNavTheme:       TNavButton;
    FNavSettings:    TNavButton;
    FNavCollapsed:   Boolean;

    procedure SetStatus(ASlot: TStatusSlot; const AText: string);
    procedure ApplyActiveTheme;
    procedure NotImplemented(const AFeature: string);
    procedure EnsureSettings;
    procedure EnsureClient;
    function  HostForError: string;

    procedure BuildSidebar;
    procedure ApplyNavState;
    procedure SetActiveNav(AActive: TNavButton);
    procedure NavToggleClicked(Sender: TObject);
    procedure NavBrokersClicked(Sender: TObject);
    procedure NavTradeClicked(Sender: TObject);
    procedure NavPlansClicked(Sender: TObject);
    procedure NavClerkClicked(Sender: TObject);
    procedure NavAiClicked(Sender: TObject);
    procedure NavThemeClicked(Sender: TObject);
    procedure NavSettingsClicked(Sender: TObject);
    procedure RefreshThemeButton;

    procedure ShowBrokersFrame;
    procedure ShowTradeFrame;
    procedure ShowPlansFrame;
    procedure ShowClerkFrame;
    procedure ShowAiFrame;
    procedure HideAllFrames;
    procedure HeartbeatTick(Sender: TObject);
    procedure StatusTimerTick(Sender: TObject);
    procedure RefreshBrokers;
    procedure StatusReload(Sender: TObject);
    procedure StatusAutoToggle(Sender: TObject);
    procedure BrokersTabChanged(Sender: TObject);
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

    // Trade panel — host-side wiring for the order pad.
    procedure RefreshTrade;
    procedure TradeSymbolSearch(Sender: TObject; const AQuery: RawUtf8;
      out AResults: TInstrumentArray);
    procedure TradePlaceRequested(Sender: TObject;
      const APlanned: TPlannedOrder);
    procedure TradeAddRequested(Sender: TObject;
      const ARow: TPositionRow);
    procedure TradeExitRequested(Sender: TObject;
      const ARow: TPositionRow);
    procedure TradeRefreshClicked(Sender: TObject);
  public
  end;

var
  MainForm: TMainForm;

implementation

uses
  mormot.net.client,
  Radium.Gui.Theme,
  Radium.Gui.QtFusion,
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

  SetSemantic(BrandLabel,     skPrimary);
  SetSemantic(BrandTagline,   skMuted);
  SetSemantic(WelcomeTitle,   skPrimary);
  SetSemantic(WelcomeBody,    skNeutral);
  SetSemantic(DocsHint,       skMuted);
  SetSemantic(StatusDotLabel, skMuted);

  // Build nav AFTER semantic tagging on the LFM children but before
  // theme apply, so the nav-button sub-controls can pick up the
  // surface bg in the same Apply walk.
  BuildSidebar;
  ApplyActiveTheme;
  ApplyNavState;
  RefreshThemeButton;
  SetActiveNav(FNavBrokers);

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
  // Dark-only since the Fusion+QPalette switch (Radium.Gui.QtFusion).
  // Apply still runs because LCL TPanel + TForm read .Color directly,
  // and the sidebar gets a non-canonical surface bg via Theme.Apply's
  // by-name overrides.
  Radium.Gui.Theme.Apply(Self);
  StatusDot.Brush.Color := Token(tDanger);
  SidebarDivider.Color  := Token(tBorderSubtle);
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

{ ── sidebar build + handlers ───────────────────────────────────── }

const
  NAV_EXPANDED_WIDTH  = 220;
  NAV_COLLAPSED_WIDTH = 56;
  NAV_BTN_GAP         = 4;
  NAV_BTN_FIRST_TOP   = 8;

procedure TMainForm.BuildSidebar;

  // Helper: build one TNavButton, parent + position it inside the
  // SidebarSpring stack. Returns the new button. Top is taken by
  // reference so we can keep the stack flowing without manual offsets.
  function MakeNavBtn(const AIcon: TIconKind; const ACaption: string;
    const AClick: TNotifyEvent; var ATop: Integer): TNavButton;
  begin
    result := TNavButton.Create(Self);
    result.Parent := SidebarSpring;
    result.Left   := 0;
    result.Top    := ATop;
    result.Width  := NAV_EXPANDED_WIDTH;
    result.Configure(AIcon, ACaption);
    result.OnNavClick := AClick;
    Inc(ATop, NAV_ROW_HEIGHT + NAV_BTN_GAP);
  end;

var
  topY: Integer;
begin
  // Toggle lives in the top group's right slot. We size and position
  // it in ApplyNavState so collapsing recentres it.
  FNavToggle := TNavButton.Create(Self);
  FNavToggle.Parent := SidebarTopGroup;
  FNavToggle.Left   := 8;
  FNavToggle.Top    := 12;
  FNavToggle.Width  := NAV_ICON_BOX_WIDTH;
  FNavToggle.Configure(iconList, '');
  FNavToggle.OnNavClick := NavToggleClicked;

  // Main nav stack — Thorium Server / Trade / Plans / Clerk / AI.
  // "Thorium Server" hosts Status / Sessions / Risk as tabs because
  // all three are daemon-side state — operator goes there to inspect
  // or change anything thoriumd-facing. Trade sits next because it's
  // the second-most-used panel: broker state + order entry on the
  // same sidebar tap target.
  topY := NAV_BTN_FIRST_TOP;
  FNavBrokers := MakeNavBtn(iconBrokers, 'Thorium Server', NavBrokersClicked, topY);
  FNavTrade   := MakeNavBtn(iconNew,     'Trade',          NavTradeClicked,   topY);
  FNavPlans   := MakeNavBtn(iconPlans,   'Plans',          NavPlansClicked,   topY);
  FNavClerk   := MakeNavBtn(iconClerk,   'Clerk',          NavClerkClicked,   topY);
  FNavAi      := MakeNavBtn(iconAi,      'AI',             NavAiClicked,      topY);

  // Bottom group hosts the operator-utility buttons. Theme above
  // Settings — Theme is the more frequent click (lighting changes
  // through the day) so it gets the closer slot.
  FNavTheme := TNavButton.Create(Self);
  FNavTheme.Parent := SidebarBotGroup;
  FNavTheme.Left   := 0;
  FNavTheme.Top    := 8;
  FNavTheme.Width  := NAV_EXPANDED_WIDTH;
  // Configured in RefreshThemeButton — it picks sun/moon glyph +
  // caption based on the current ActiveTheme so the button reads
  // as "what clicking will switch you to".
  FNavTheme.OnNavClick := NavThemeClicked;

  FNavSettings := TNavButton.Create(Self);
  FNavSettings.Parent := SidebarBotGroup;
  FNavSettings.Left   := 0;
  FNavSettings.Top    := 8 + NAV_ROW_HEIGHT + NAV_BTN_GAP;
  FNavSettings.Width  := NAV_EXPANDED_WIDTH;
  FNavSettings.Configure(iconSettings, 'Settings');
  FNavSettings.OnNavClick := NavSettingsClicked;
end;

procedure TMainForm.ApplyNavState;
var
  surf, hover, fg, fgActive: TColor;
  w: Integer;

  procedure ApplyTo(B: TNavButton);
  begin
    if B = nil then exit;
    B.SetColors(surf, hover, hover, fg, fgActive);
    B.SetCollapsed(FNavCollapsed);
    if FNavCollapsed then
      B.Width := NAV_COLLAPSED_WIDTH
    else
      B.Width := NAV_EXPANDED_WIDTH;
  end;

begin
  // Sidebar surface bg + colour roles drawn from the Theme tokens so
  // any future palette tweak doesn't fork between this and Apply().
  surf     := Token(tBgSurface);
  hover    := Token(tBgElevated);
  fg       := Token(tFgSecondary);
  fgActive := Token(tFgPrimary);

  if FNavCollapsed then
    w := NAV_COLLAPSED_WIDTH
  else
    w := NAV_EXPANDED_WIDTH;
  SidebarHost.Width := w;

  // Brand region only renders in expanded mode — there's no room for
  // it at 56px wide, and the toggle alone reads as the "logo" tile.
  BrandLabel.Visible   := not FNavCollapsed;
  BrandTagline.Visible := not FNavCollapsed;

  ApplyTo(FNavToggle);
  ApplyTo(FNavBrokers);
  ApplyTo(FNavTrade);
  ApplyTo(FNavPlans);
  ApplyTo(FNavClerk);
  ApplyTo(FNavAi);
  ApplyTo(FNavTheme);
  ApplyTo(FNavSettings);
end;

procedure TMainForm.SetActiveNav(AActive: TNavButton);
  procedure Mark(B: TNavButton);
  begin
    if B <> nil then B.SetActive(B = AActive);
  end;
begin
  Mark(FNavBrokers);
  Mark(FNavTrade);
  Mark(FNavPlans);
  Mark(FNavClerk);
  Mark(FNavAi);
  Mark(FNavSettings);
end;

procedure TMainForm.NavToggleClicked(Sender: TObject);
begin
  FNavCollapsed := not FNavCollapsed;
  ApplyNavState;
end;

procedure TMainForm.NavBrokersClicked(Sender: TObject);
begin
  // Lands on the Status tab (index 0) and refreshes both Status +
  // Sessions from a single /status call. Risk is the third tab; the
  // operator switches into it explicitly when they want to change a
  // knob — we don't pre-fetch it here.
  SetActiveNav(FNavBrokers);
  ShowBrokersFrame;
  RefreshBrokers;
end;

procedure TMainForm.NavTradeClicked(Sender: TObject);
begin
  SetActiveNav(FNavTrade);
  ShowTradeFrame;
  RefreshTrade;
end;

procedure TMainForm.NavPlansClicked(Sender: TObject);
begin
  SetActiveNav(FNavPlans);
  ShowPlansFrame;
  RefreshPlans;
end;

procedure TMainForm.NavClerkClicked(Sender: TObject);
begin
  SetActiveNav(FNavClerk);
  ShowClerkFrame;
end;

procedure TMainForm.NavAiClicked(Sender: TObject);
begin
  SetActiveNav(FNavAi);
  ShowAiFrame;
  RefreshAi;
end;

procedure TMainForm.RefreshThemeButton;
begin
  if FNavTheme = nil then exit;
  // Show the icon for what clicking will switch you TO. So in light
  // mode → moon (= "switch to dark"), in dark mode → sun.
  case ActiveTheme of
    tkLight: FNavTheme.Configure(iconMoon, 'Dark mode');
    tkDark:  FNavTheme.Configure(iconSun,  'Light mode');
  end;
end;

procedure TMainForm.NavThemeClicked(Sender: TObject);
var
  next: TThemeKind;
  s:    TRadiumSettings;
begin
  // Toggle. ApplyFusionTheme repaints every Qt widget by reapplying
  // QApplication's palette + stylesheet. Theme.Apply(Self) follows
  // for the LCL-painted bits (sidebar surface bg, semantic font
  // colours, status dot). The pair keeps Qt and LCL in lockstep.
  if ActiveTheme = tkLight then next := tkDark else next := tkLight;
  ApplyFusionTheme(next);
  ApplyActiveTheme;
  ApplyNavState;
  RefreshThemeButton;
  // Persist so the operator's choice survives a restart. Only when
  // settings already exist on disk — otherwise the first-run wizard
  // owns the first save and we don't want to scribble a half-config.
  if LoadSettings(s) then
  begin
    case next of
      tkDark:  s.Theme := 'dark';
      tkLight: s.Theme := 'light';
    end;
    try
      SaveSettings(s);
    except
      // Disk write failed — toggle still applied in-memory; the
      // operator can retry on next toggle. Don't block the UI.
    end;
  end;
end;

procedure TMainForm.NavSettingsClicked(Sender: TObject);
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

{ ── frame plumbing ───────────────────────────────────────────────── }

procedure TMainForm.HideAllFrames;
begin
  // Sidebar destinations share CenterHost. Hiding everything before
  // showing the chosen frame keeps the destination switch a single
  // assignment, no z-order surprises.
  WelcomeCard.Visible := False;
  if FBrokersFrame <> nil then FBrokersFrame.Visible := False;
  if FTradeFrame <> nil then FTradeFrame.Visible := False;
  if FPlansFrame <> nil then FPlansFrame.Visible := False;
  if FClerkFrame <> nil then FClerkFrame.Visible := False;
  if FAiFrame <> nil then FAiFrame.Visible := False;
  // Pause the /status auto-refresh whenever Thorium Server isn't
  // visible — no point burning calls when the operator is on Plans
  // / Trade / etc. Resumed in ShowBrokersFrame.
  if FStatusTimer <> nil then FStatusTimer.Enabled := False;
end;

procedure TMainForm.BrokersTabChanged(Sender: TObject);
begin
  // Risk tab is lazy-loaded — its frame creates with empty fields
  // and only fetches /api/risk when the operator switches to it.
  // Sessions + Status share the existing /status snapshot fetched
  // by RefreshBrokers, so no extra work is needed there.
  if FBrokersFrame = nil then exit;
  if FBrokersFrame.Tabs.ActivePage = nil then exit;
  if SameText(FBrokersFrame.Tabs.ActivePage.Caption, 'Risk') then
    RefreshRisk;
end;

procedure TMainForm.ShowBrokersFrame;
begin
  HideAllFrames;
  if FBrokersFrame = nil then
  begin
    FBrokersFrame := TBrokersFrame.Create(Self);
    FBrokersFrame.Parent := CenterHost;
    FBrokersFrame.Align  := alClient;

    // Status-tab event wiring (default landing tab).
    FBrokersFrame.Status.OnReload     := StatusReload;
    FBrokersFrame.Status.OnAutoToggle := StatusAutoToggle;

    // Sessions-tab event wiring (same as the old standalone frame).
    FBrokersFrame.Sessions.OnAttachClicked  := SessionsAttach;
    FBrokersFrame.Sessions.OnModifyClicked  := SessionsModify;
    FBrokersFrame.Sessions.OnDetachClicked  := SessionsDetach;
    FBrokersFrame.Sessions.OnPromoteClicked := SessionsPromote;

    // Risk-tab event wiring — folded into Thorium Server panel
    // 2026-05-03; it used to be a top-level sidebar destination.
    FBrokersFrame.Risk.OnLoad := RiskLoad;
    FBrokersFrame.Risk.OnSave := RiskSave;

    // Tab-switch hook: fetches /api/risk lazily when the operator
    // moves to the Risk tab.
    FBrokersFrame.Tabs.OnChange := BrokersTabChanged;

    Radium.Gui.Theme.Apply(FBrokersFrame);
  end
  else
    FBrokersFrame.Visible := True;

  // Always land on Status — operator's first question is "is the
  // daemon healthy". Sessions + Risk are explicit clicks from there.
  FBrokersFrame.Tabs.ActivePageIndex := 0;

  // Spin up (or resume) the 5s status auto-refresh while Thorium
  // Server is visible. HideAllFrames pauses it.
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

procedure TMainForm.ShowTradeFrame;
begin
  HideAllFrames;
  if FTradeFrame = nil then
  begin
    FTradeFrame := TTradeFrame.Create(Self);
    FTradeFrame.Parent := CenterHost;
    FTradeFrame.Align  := alClient;
    FTradeFrame.OnSymbolSearch   := TradeSymbolSearch;
    FTradeFrame.OnPlaceRequested := TradePlaceRequested;
    FTradeFrame.OnAddRequested   := TradeAddRequested;
    FTradeFrame.OnExitRequested  := TradeExitRequested;
    FTradeFrame.OnRefreshClicked := TradeRefreshClicked;
    Radium.Gui.Theme.Apply(FTradeFrame);
  end
  else
    FTradeFrame.Visible := True;
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
  riskFrame: TRiskFrame;
begin
  if FBrokersFrame = nil then exit;
  riskFrame := FBrokersFrame.Risk;
  if riskFrame = nil then exit;
  // Populate the scope picker so the per-broker option is visible
  // (read-only today). Same instance list the Plans frame uses.
  if Length(FCachedSessions) > 0 then
  begin
    SetLength(instOpts, Length(FCachedSessions));
    for i := 0 to High(FCachedSessions) do
      instOpts[i] := FCachedSessions[i].InstanceId;
    riskFrame.SetInstanceOptions(instOpts);
  end;

  try
    EnsureClient;
    riskFrame.SetStatusText('Loading from thoriumd...', 0);
    Screen.Cursor := crHourGlass;
    try
      rk := FClient.RiskGet;
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      riskFrame.SetStatusText('Could not load risk: ' + E.Message, -1);
      ShowMessage(HumanError(E, 'Load risk', HostForError));
      exit;
    end;
  end;
  riskFrame.SetRisk(rk);
  riskFrame.SetStatusText('Loaded ' + FormatDateTime('hh:nn', Now) + ' IST.', 0);
end;

procedure TMainForm.RiskLoad(Sender: TObject);
begin
  RefreshRisk;
end;

procedure TMainForm.RiskSave(Sender: TObject; const APatch: TRiskPatch);
var
  rk: TRiskConfig;
  riskFrame: TRiskFrame;
begin
  if FBrokersFrame = nil then exit;
  riskFrame := FBrokersFrame.Risk;
  if riskFrame = nil then exit;
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
      riskFrame.SetStatusText('Save failed: ' + E.Message, -1);
      ShowMessage(HumanError(E, 'Save risk', HostForError));
      exit;
    end;
  end;
  // Successful save → take the just-saved values as the new baseline
  // for "modified vs original" detection on the next save.
  riskFrame.CommitSavedSnapshot(rk);
  riskFrame.SetStatusText('Saved ' + FormatDateTime('hh:nn', Now) + ' IST.', 1);
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

{ ── trade frame wiring ──────────────────────────────────────────── }

// FirstSessionInstance — the trade pad needs an instance_id to send
// to thoriumd. We default to whichever session is feed-broker (so
// quotes + tradebook line up); fallback to the first attached session.
function FirstFeedOrAnyInstance(const ASessions: TStatusSessionArray): RawUtf8;
var
  i: Integer;
begin
  result := '';
  for i := 0 to High(ASessions) do
    if ASessions[i].IsFeedBroker then
    begin
      result := ASessions[i].InstanceId;
      exit;
    end;
  if Length(ASessions) > 0 then
    result := ASessions[0].InstanceId;
end;

// ParsePositionsRaw — turn /api/v1/positionbook JSON into typed
// TPositionRow array. Mirrors the broker-agnostic shape thoriumd
// promises: { symbol, exchange, product, netqty, avgprice, ltp,
// pnl }. Defensive on field-name variants per broker.
function ParsePositionsRaw(const ARaw: RawUtf8): TPositionRowArray;
var
  parsed, rows, row: variant;
  i, n: Integer;
  d: PDocVariantData;
begin
  SetLength(result, 0);
  if ARaw = '' then exit;
  parsed := _Json(ARaw);
  if VarIsEmptyOrNull(parsed) then exit;
  d := _Safe(parsed);
  // Either a bare array or { positions: [...] } — accept both.
  if VarIsArray(parsed) then
    rows := parsed
  else if d^.Exists('positions') then
    rows := d^.Value['positions']
  else
    rows := parsed;
  if not VarIsArray(rows) then exit;
  n := _Safe(rows)^.Count;
  SetLength(result, n);
  for i := 0 to n - 1 do
  begin
    row := _Safe(rows)^.Values[i];
    // CID is the canonical identifier — prefer the 'cid' field
    // explicitly. Some adapters return only 'symbol' (broker key) on
    // positionbook; we tolerate that as a last-resort fallback but
    // place_order then has to round-trip a broker-key, which thoriumd
    // accepts. Search dropdown produces real CIDs; positions
    // returning broker keys is a per-adapter compliance gap, not a
    // Radium bug.
    result[i].Cid          := _Safe(row)^.U['cid'];
    if result[i].Cid = '' then
      result[i].Cid        := _Safe(row)^.U['symbol'];
    result[i].CidExchange  := _Safe(row)^.U['cid_exchange'];
    if result[i].CidExchange = '' then
      result[i].CidExchange := _Safe(row)^.U['exchange'];
    result[i].DisplayName  := string(result[i].Cid);
    result[i].Product      := ProductFromWire(_Safe(row)^.U['product']);
    result[i].NetQuantity  := _Safe(row)^.I['netqty'];
    if result[i].NetQuantity = 0 then
      result[i].NetQuantity := _Safe(row)^.I['net_quantity'];
    result[i].AvgPrice     := _Safe(row)^.D['avgprice'];
    if result[i].AvgPrice = 0 then
      result[i].AvgPrice   := _Safe(row)^.D['average_price'];
    result[i].Ltp          := _Safe(row)^.D['ltp'];
    result[i].Pnl          := _Safe(row)^.D['pnl'];
    result[i].LotSize      := _Safe(row)^.I['lot_size'];
    if result[i].LotSize = 0 then
      result[i].LotSize    := _Safe(row)^.I['lotsize'];
    result[i].Segment      := SegmentForExchange(result[i].CidExchange);
  end;
end;

procedure TMainForm.RefreshTrade;
var
  rk:           TRiskConfig;
  posRaw:       RawUtf8;
  trades, ords: RawUtf8;
  positions:    TPositionRowArray;
  ambient:      TAmbientTrading;
  inst:         RawUtf8;
  i:            Integer;
  tradeLines:   TStringList;
  ordersLines:  TStringList;
begin
  if FTradeFrame = nil then exit;
  inst := FirstFeedOrAnyInstance(FCachedSessions);
  FTradeFrame.SetInstance(inst);

  if inst = '' then
  begin
    FTradeFrame.SetUpdatedHint('No broker attached — attach one in Thorium Server › Sessions');
    exit;
  end;

  try
    EnsureClient;
    Screen.Cursor := crHourGlass;
    try
      rk := FClient.RiskGet;
      posRaw := FClient.PositionbookGet(inst);
      trades := FClient.TradebookGet(inst);
      ords   := FClient.OrderbookGetSafe(inst);
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      FTradeFrame.SetUpdatedHint('Refresh failed: ' + E.Message);
      exit;
    end;
  end;

  positions := ParsePositionsRaw(posRaw);
  FTradeFrame.SetRiskConfig(rk);
  FTradeFrame.SetPositions(positions);

  // Tradebook + orderbook get one row per JSON object for now —
  // pretty rendering is a future polish; the raw row keeps every
  // field accessible. ParseTradebookRaw could format a real grid
  // when we know the columns the operator wants.
  tradeLines := TStringList.Create;
  ordersLines := TStringList.Create;
  try
    if trades <> '' then tradeLines.Add(string(trades));
    if ords <> '' then ordersLines.Add(string(ords));
    FTradeFrame.SetTradebookText(tradeLines.ToStringArray);
    FTradeFrame.SetOrderbookText(ordersLines.ToStringArray);
  finally
    tradeLines.Free;
    ordersLines.Free;
  end;

  // Compose ambient state for the validator. Symbol-PnL stays 0
  // until we wire per-symbol breakdown — operator sees daily-loss
  // breaches via TodayPnl regardless.
  FillChar(ambient, SizeOf(ambient), 0);
  ambient.NowIst := Now;
  ambient.OpenOrderCount := 0; // refine when orderbook is parsed
  for i := 0 to High(positions) do
    ambient.TodayPnlInr := ambient.TodayPnlInr + positions[i].Pnl;
  // Margin/funds — leave zero for now so the margin checks short-
  // circuit cleanly. A future RefreshTrade slice calls FundsGet.
  FTradeFrame.SetAmbient(ambient);

  FTradeFrame.SetUpdatedHint(
    'Updated ' + FormatDateTime('hh:nn:ss', Now) + ' IST');
end;

procedure TMainForm.TradeSymbolSearch(Sender: TObject; const AQuery: RawUtf8;
  out AResults: TInstrumentArray);
var
  inst: RawUtf8;
begin
  SetLength(AResults, 0);
  inst := FirstFeedOrAnyInstance(FCachedSessions);
  if inst = '' then exit;
  try
    EnsureClient;
    AResults := FClient.SymbolSearch(AQuery, '', 25, inst);
  except
    on E: Exception do
      // Swallow — autocomplete shouldn't pop a dialog on every keystroke.
      SetLength(AResults, 0);
  end;
end;

procedure TMainForm.TradePlaceRequested(Sender: TObject;
  const APlanned: TPlannedOrder);
var
  msg, orderId: string;
  reply: Integer;
begin
  // Always confirm. Operator clicks Place → modal lays out exactly
  // what we're about to send. Any vsBlock finding has already
  // disabled the Place button so we know the validator agreed.
  msg :=
    Format('%s %d %s on %s @ %s', [
      string(ActionWire(APlanned.Action)),
      APlanned.Quantity,
      string(APlanned.InstrumentType),
      APlanned.DisplayName,
      string(PriceTypeWire(APlanned.PriceType))]) + LineEnding;
  if APlanned.Price > 0 then
    msg := msg + Format('Price: %.2f', [APlanned.Price]) + LineEnding;
  if APlanned.Trigger > 0 then
    msg := msg + Format('Trigger: %.2f', [APlanned.Trigger]) + LineEnding;
  msg := msg + 'Product: ' + string(ProductWire(APlanned.Product)) + LineEnding +
         LineEnding + 'Place this order?';

  reply := MessageDlg('Confirm order', msg, mtConfirmation,
                       [mbYes, mbNo], 0);
  if reply <> mrYes then exit;

  try
    EnsureClient;
    Screen.Cursor := crHourGlass;
    try
      orderId := string(FClient.PlaceOrder(
        APlanned.Cid, APlanned.CidExchange,
        ActionWire(APlanned.Action),
        PriceTypeWire(APlanned.PriceType),
        ProductWire(APlanned.Product),
        APlanned.Quantity, APlanned.Price, APlanned.Trigger,
        APlanned.InstanceId));
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      ShowMessage(HumanError(E, 'Place order', HostForError));
      exit;
    end;
  end;

  ShowMessage('Order placed.' + LineEnding +
              'Broker order id: ' + orderId);
  RefreshTrade;
end;

procedure TMainForm.TradeAddRequested(Sender: TObject;
  const ARow: TPositionRow);
begin
  if FTradeFrame = nil then exit;
  FTradeFrame.PrefillFromPosition(ARow);
end;

procedure TMainForm.TradeExitRequested(Sender: TObject;
  const ARow: TPositionRow);
var
  reply: Integer;
  orderId: string;
begin
  reply := MessageDlg('Exit position',
    Format('Close %s (qty %d, P&L %.2f)?',
      [ARow.DisplayName, ARow.NetQuantity, ARow.Pnl]),
    mtConfirmation, [mbYes, mbNo], 0);
  if reply <> mrYes then exit;

  try
    EnsureClient;
    Screen.Cursor := crHourGlass;
    try
      orderId := string(FClient.ClosePosition(
        ARow.Cid, ARow.CidExchange, ARow.InstanceId));
    finally
      Screen.Cursor := crDefault;
    end;
  except
    on E: Exception do
    begin
      ShowMessage(HumanError(E, 'Close position', HostForError));
      exit;
    end;
  end;
  ShowMessage('Exit submitted. Broker order id: ' + orderId);
  RefreshTrade;
end;

procedure TMainForm.TradeRefreshClicked(Sender: TObject);
begin
  RefreshTrade;
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
