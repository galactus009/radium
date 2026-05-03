unit Radium.Gui.AiFrame;

(* ----------------------------------------------------------------------------
  AI provider frame — centre-host content for the "AI" sidebar destination.
  Mirrors thoriumctl's `ai show` (GET /admin/ai/config) and `ai configure`
  (POST /admin/ai/configure). The third subcommand, `ai ask`, lives in a
  future chat surface (queued, not in this frame).

  Layout follows the Risk panel's "current + edit" pattern so operators
  carry one mental model across both admin pages:

    +- AI Provider ─────────────────────────────────────────────────+
    |   CURRENT                                                     |
    |     Provider   anthropic                                      |
    |     Model      claude-opus-4-7                                |
    |     Base URL   https://api.anthropic.com                      |
    |     API key    set  /  not set                                |
    |                                                               |
    |   CONFIGURE                                                   |
    |     Provider [▼ anthropic ]                                   |
    |     API key  [...............]   (write-only, never echoed)   |
    |     Model    [claude-opus-4-7]   (blank = provider default)   |
    |     Base URL [...............]   (blank = provider default)   |
    |                                                               |
    |   [Reload]                            [Discard]  [Save]       |
    +---------------------------------------------------------------+

  Wire semantics: `/admin/ai/config` (GET) returns provider, model,
  base_url, and has_key (bool — server NEVER returns the raw key).
  POST /admin/ai/configure persists. We keep the API key field
  password-masked at all times; loading a snapshot leaves it blank
  (we have no way to re-display it). To rotate, the operator types
  the new key and saves.

  Frame raises events; MainForm owns the client + I/O — same pattern
  as SessionsFrame / PlansFrame / RiskFrame.
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  Classes,
  SysUtils,
  Forms,
  Controls,
  Graphics,
  Grids,
  ComCtrls,
  ExtCtrls,
  StdCtrls,
  mormot.core.base,
  Radium.Api.Types,
  Radium.Gui.ChatFrame;

type
  TAiLoadEvent = procedure(Sender: TObject) of object;

  // TAiConfigurePayload — what the frame asks MainForm to submit. The
  // frame doesn't talk to the network; MainForm calls
  // TThoriumClient.AiConfigure with these fields.
  TAiConfigurePayload = record
    Provider: RawUtf8;
    ApiKey:   RawUtf8;     // empty = "leave server-side key as-is"
    Model:    RawUtf8;     // empty = "use provider default"
    BaseUrl:  RawUtf8;     // empty = "use provider default"
  end;

  TAiSaveEvent = procedure(Sender: TObject;
    const APayload: TAiConfigurePayload) of object;

  { TAiFrame }
  TAiFrame = class(TPanel)
  private
    FTopBar:        TPanel;
      FBtnReload:   TButton;
      FStatusLbl:   TLabel;

    FTabs:          TPageControl;
    FTabConfigure:  TTabSheet;
    FTabChat:       TTabSheet;

    // Configure-tab children — same controls as before, just reparented
    // to FTabConfigure instead of Self.
    FCurrentCard:   TPanel;
      FCurrentGrid: TStringGrid;

    FEditPanel:     TPanel;
      FLblProvider: TLabel;  FCmbProvider: TComboBox;
      FLblApiKey:   TLabel;  FEdtApiKey:   TEdit;   FLblApiKeyHint: TLabel;
      FLblModel:    TLabel;  FEdtModel:    TEdit;   FLblModelHint:  TLabel;
      FLblBaseUrl:  TLabel;  FEdtBaseUrl:  TEdit;   FLblBaseUrlHint:TLabel;

    FButtonsBar:    TPanel;
      FBtnSave:     TButton;
      FBtnDiscard:  TButton;

    // Chat-tab child — embedded ChatFrame, raises its own ask event.
    FChatFrame:     TChatFrame;

    FOnLoad:        TAiLoadEvent;
    FOnSave:        TAiSaveEvent;
    FOnChatAsk:     TChatAskEvent;

    FLoaded:        TAiConfigSnapshot;

    procedure BuildTopBar;
    procedure BuildCurrentCard;
    procedure BuildEditPanel;
    procedure BuildButtonsBar;

    procedure DoReloadClick(Sender: TObject);
    procedure DoSaveClick(Sender: TObject);
    procedure DoDiscardClick(Sender: TObject);
    procedure DoChatForward(Sender: TObject;
      const ARequest: TChatAskRequest);

    procedure RenderCurrent(const ASnap: TAiConfigSnapshot);
    procedure FillEditorsFromSnapshot(const ASnap: TAiConfigSnapshot);

    function ProviderWireFromCombo: RawUtf8;
    procedure SetProviderCombo(const AWireId: RawUtf8);
  public
    constructor Create(AOwner: TComponent); override;

    procedure SetSnapshot(const ASnap: TAiConfigSnapshot);
    procedure SetStatusText(const AText: string; AKind: Integer);

    // Caller relays a chat reply back into the chat tab. Used by
    // MainForm after the routed AskRequested event resolves.
    procedure AppendChatReply(const AReply: RawUtf8; AOk: Boolean);

    property OnLoad:    TAiLoadEvent  read FOnLoad    write FOnLoad;
    property OnSave:    TAiSaveEvent  read FOnSave    write FOnSave;
    // OnChatAskRequested is raised by the embedded ChatFrame; the
    // outer frame just forwards the event up so MainForm has one
    // handler set per panel destination.
    property OnChatAskRequested: TChatAskEvent
      read FOnChatAsk write FOnChatAsk;
  end;

implementation

uses
  Radium.Gui.Theme;

const
  TOPBAR_H        = 56;
  CARD_H          = 152;
  EDIT_H          = 280;

{ TAiFrame ─────────────────────────────────────────────────────────── }

constructor TAiFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption    := '';

  BuildTopBar;

  // Tabs occupy the rest of the frame: Configure (snapshot + form)
  // and Chat (chatbuddy port). Build BEFORE the configure-side
  // helpers because those reparent into FTabConfigure.
  FTabs := TPageControl.Create(Self);
  FTabs.Parent := Self;
  FTabs.Align  := alClient;

  FTabConfigure := TTabSheet.Create(FTabs);
  FTabConfigure.PageControl := FTabs;
  FTabConfigure.Caption := 'Configure';

  FTabChat := TTabSheet.Create(FTabs);
  FTabChat.PageControl := FTabs;
  FTabChat.Caption := 'Chat';

  BuildCurrentCard;     // parents to FTabConfigure
  BuildEditPanel;       // parents to FTabConfigure
  BuildButtonsBar;      // parents to FTabConfigure

  // Embed the ChatFrame on the Chat tab. It raises its own ask event;
  // DoChatForward republishes it through FOnChatAsk so MainForm only
  // hooks one set of frames.
  FChatFrame := TChatFrame.Create(FTabChat);
  FChatFrame.Parent := FTabChat;
  FChatFrame.Align  := alClient;
  FChatFrame.OnAskRequested := DoChatForward;
end;

procedure TAiFrame.DoChatForward(Sender: TObject;
  const ARequest: TChatAskRequest);
begin
  if Assigned(FOnChatAsk) then FOnChatAsk(Self, ARequest);
end;

procedure TAiFrame.AppendChatReply(const AReply: RawUtf8; AOk: Boolean);
begin
  if FChatFrame <> nil then
    FChatFrame.AppendReply(AReply, AOk);
end;

procedure TAiFrame.BuildTopBar;
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

  FStatusLbl := TLabel.Create(FTopBar);
  FStatusLbl.Parent := FTopBar;
  FStatusLbl.Left   := 200;
  FStatusLbl.Top    := 18;
  FStatusLbl.AutoSize := False;
  FStatusLbl.Width  := 1100;
  FStatusLbl.Height := 32;
  FStatusLbl.WordWrap := True;
  FStatusLbl.Caption := 'Click Reload to fetch the current AI provider config.';
  FStatusLbl.Font.Height := -12;
  FStatusLbl.ParentColor := True;
  FStatusLbl.ParentFont  := False;
  SetSemantic(FStatusLbl, skMuted);
end;

procedure TAiFrame.BuildCurrentCard;
var
  hdr: TLabel;
begin
  FCurrentCard := TPanel.Create(FTabConfigure);
  FCurrentCard.Parent     := FTabConfigure;
  FCurrentCard.Align      := alTop;
  FCurrentCard.Height     := CARD_H;
  FCurrentCard.BevelOuter := bvNone;
  FCurrentCard.Caption    := '';

  hdr := TLabel.Create(FCurrentCard);
  hdr.Parent  := FCurrentCard;
  hdr.Caption := 'CURRENT AI PROVIDER';
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
  FCurrentGrid.RowCount     := 5;     // 4 rows + header
  FCurrentGrid.ColCount     := 2;
  FCurrentGrid.FixedRows    := 1;
  FCurrentGrid.FixedCols    := 0;
  FCurrentGrid.Cells[0, 0]  := 'Field';
  FCurrentGrid.Cells[1, 0]  := 'Value';
  FCurrentGrid.ColWidths[0] := 200;
  FCurrentGrid.ColWidths[1] := 840;
  FCurrentGrid.DefaultRowHeight := 22;
  FCurrentGrid.Options := FCurrentGrid.Options - [goEditing] + [goVertLine, goHorzLine];
  FCurrentGrid.ScrollBars := ssNone;
  // Pre-populate row labels so the empty state still reads as a form
  // (operator sees "Provider: -" not a blank table) before Reload.
  FCurrentGrid.Cells[0, 1] := 'Provider';
  FCurrentGrid.Cells[0, 2] := 'Model';
  FCurrentGrid.Cells[0, 3] := 'Base URL';
  FCurrentGrid.Cells[0, 4] := 'API key';
  FCurrentGrid.Cells[1, 1] := '-';
  FCurrentGrid.Cells[1, 2] := '-';
  FCurrentGrid.Cells[1, 3] := '-';
  FCurrentGrid.Cells[1, 4] := '-';
end;

procedure TAiFrame.BuildEditPanel;
var
  hdr: TLabel;
  yRow, dy: Integer;
begin
  FEditPanel := TPanel.Create(FTabConfigure);
  FEditPanel.Parent     := FTabConfigure;
  FEditPanel.Align      := alClient;
  FEditPanel.BevelOuter := bvNone;
  FEditPanel.Caption    := '';

  hdr := TLabel.Create(FEditPanel);
  hdr.Parent  := FEditPanel;
  hdr.Caption := 'CONFIGURE';
  hdr.Left    := 16;
  hdr.Top     := 8;
  hdr.AutoSize := True;
  hdr.Font.Height := -10;
  hdr.Font.Style  := [fsBold];
  hdr.ParentColor := True;
  hdr.ParentFont  := False;
  SetSemantic(hdr, skMuted);

  // Each row: bold label, control, muted helper text. dy is the
  // vertical stride so adding another field is one constant tweak.
  dy := 64;
  yRow := 36;

  FLblProvider := TLabel.Create(FEditPanel);
  FLblProvider.Parent  := FEditPanel;
  FLblProvider.Caption := 'Provider';
  FLblProvider.Left    := 16;
  FLblProvider.Top     := yRow;
  FLblProvider.AutoSize := True;
  FLblProvider.Font.Height := -12;
  FLblProvider.Font.Style  := [fsBold];
  FLblProvider.ParentColor := True;
  FLblProvider.ParentFont  := False;
  SetSemantic(FLblProvider, skNeutral);

  FCmbProvider := TComboBox.Create(FEditPanel);
  FCmbProvider.Parent := FEditPanel;
  FCmbProvider.Left   := 200;
  FCmbProvider.Top    := yRow - 4;
  FCmbProvider.Width  := 220;
  FCmbProvider.Height := 28;
  FCmbProvider.Style  := csDropDownList;
  // Match thoriumctl's vocabulary: anthropic/openai/grok/ollama/gemini.
  // Display labels carry the canonical model so the operator doesn't
  // have to look it up; ProviderWireFromCombo strips back to the wire id.
  FCmbProvider.Items.Add('anthropic     (Claude)');
  FCmbProvider.Items.Add('openai        (GPT)');
  FCmbProvider.Items.Add('grok          (xAI)');
  FCmbProvider.Items.Add('gemini        (Google)');
  FCmbProvider.Items.Add('ollama        (local)');
  FCmbProvider.ItemIndex := 0;

  Inc(yRow, dy);
  FLblApiKey := TLabel.Create(FEditPanel);
  FLblApiKey.Parent  := FEditPanel;
  FLblApiKey.Caption := 'API key';
  FLblApiKey.Left    := 16;
  FLblApiKey.Top     := yRow;
  FLblApiKey.AutoSize := True;
  FLblApiKey.Font.Height := -12;
  FLblApiKey.Font.Style  := [fsBold];
  FLblApiKey.ParentColor := True;
  FLblApiKey.ParentFont  := False;
  SetSemantic(FLblApiKey, skNeutral);

  FEdtApiKey := TEdit.Create(FEditPanel);
  FEdtApiKey.Parent   := FEditPanel;
  FEdtApiKey.Left     := 200;
  FEdtApiKey.Top      := yRow - 4;
  FEdtApiKey.Width    := 460;
  FEdtApiKey.Height   := 28;
  FEdtApiKey.EchoMode := emPassword;
  FEdtApiKey.TextHint := 'leave blank to keep current key';

  FLblApiKeyHint := TLabel.Create(FEditPanel);
  FLblApiKeyHint.Parent  := FEditPanel;
  FLblApiKeyHint.Caption :=
    'Write-only on the wire. The server stores it; never sends it back. ' +
    'Blank here means "leave the existing key alone".';
  FLblApiKeyHint.Left    := 200;
  FLblApiKeyHint.Top     := yRow + 28;
  FLblApiKeyHint.Width   := 800;
  FLblApiKeyHint.AutoSize := False;
  FLblApiKeyHint.Height  := 16;
  FLblApiKeyHint.Font.Height := -11;
  FLblApiKeyHint.ParentColor := True;
  FLblApiKeyHint.ParentFont  := False;
  SetSemantic(FLblApiKeyHint, skMuted);

  Inc(yRow, dy);
  FLblModel := TLabel.Create(FEditPanel);
  FLblModel.Parent  := FEditPanel;
  FLblModel.Caption := 'Model';
  FLblModel.Left    := 16;
  FLblModel.Top     := yRow;
  FLblModel.AutoSize := True;
  FLblModel.Font.Height := -12;
  FLblModel.Font.Style  := [fsBold];
  FLblModel.ParentColor := True;
  FLblModel.ParentFont  := False;
  SetSemantic(FLblModel, skNeutral);

  FEdtModel := TEdit.Create(FEditPanel);
  FEdtModel.Parent   := FEditPanel;
  FEdtModel.Left     := 200;
  FEdtModel.Top      := yRow - 4;
  FEdtModel.Width    := 460;
  FEdtModel.Height   := 28;
  FEdtModel.TextHint := 'blank = provider default';

  FLblModelHint := TLabel.Create(FEditPanel);
  FLblModelHint.Parent  := FEditPanel;
  FLblModelHint.Caption :=
    'e.g. claude-opus-4-7  /  gpt-5  /  gemini-2-pro. ' +
    'Leave blank to take whatever default the daemon picks for the chosen provider.';
  FLblModelHint.Left    := 200;
  FLblModelHint.Top     := yRow + 28;
  FLblModelHint.Width   := 800;
  FLblModelHint.AutoSize := False;
  FLblModelHint.Height  := 16;
  FLblModelHint.Font.Height := -11;
  FLblModelHint.ParentColor := True;
  FLblModelHint.ParentFont  := False;
  SetSemantic(FLblModelHint, skMuted);

  Inc(yRow, dy);
  FLblBaseUrl := TLabel.Create(FEditPanel);
  FLblBaseUrl.Parent  := FEditPanel;
  FLblBaseUrl.Caption := 'Base URL';
  FLblBaseUrl.Left    := 16;
  FLblBaseUrl.Top     := yRow;
  FLblBaseUrl.AutoSize := True;
  FLblBaseUrl.Font.Height := -12;
  FLblBaseUrl.Font.Style  := [fsBold];
  FLblBaseUrl.ParentColor := True;
  FLblBaseUrl.ParentFont  := False;
  SetSemantic(FLblBaseUrl, skNeutral);

  FEdtBaseUrl := TEdit.Create(FEditPanel);
  FEdtBaseUrl.Parent   := FEditPanel;
  FEdtBaseUrl.Left     := 200;
  FEdtBaseUrl.Top      := yRow - 4;
  FEdtBaseUrl.Width    := 460;
  FEdtBaseUrl.Height   := 28;
  FEdtBaseUrl.TextHint := 'blank = provider default';

  FLblBaseUrlHint := TLabel.Create(FEditPanel);
  FLblBaseUrlHint.Parent  := FEditPanel;
  FLblBaseUrlHint.Caption :=
    'Override only when proxying through a gateway or running ollama locally ' +
    '(http://127.0.0.1:11434). Otherwise leave blank.';
  FLblBaseUrlHint.Left    := 200;
  FLblBaseUrlHint.Top     := yRow + 28;
  FLblBaseUrlHint.Width   := 800;
  FLblBaseUrlHint.AutoSize := False;
  FLblBaseUrlHint.Height  := 16;
  FLblBaseUrlHint.Font.Height := -11;
  FLblBaseUrlHint.ParentColor := True;
  FLblBaseUrlHint.ParentFont  := False;
  SetSemantic(FLblBaseUrlHint, skMuted);
end;

procedure TAiFrame.BuildButtonsBar;
begin
  FButtonsBar := TPanel.Create(FTabConfigure);
  FButtonsBar.Parent     := FTabConfigure;
  FButtonsBar.Align      := alBottom;
  FButtonsBar.Height     := 56;
  FButtonsBar.BevelOuter := bvNone;
  FButtonsBar.Caption    := '';

  FBtnDiscard := TButton.Create(FButtonsBar);
  FBtnDiscard.Parent  := FButtonsBar;
  FBtnDiscard.Left    := 16;
  FBtnDiscard.Top     := 12;
  FBtnDiscard.Width   := 160;
  FBtnDiscard.Height  := 32;
  FBtnDiscard.Caption := 'Discard changes';
  FBtnDiscard.OnClick := DoDiscardClick;
  SetSemantic(FBtnDiscard, skMuted);

  FBtnSave := TButton.Create(FButtonsBar);
  FBtnSave.Parent  := FButtonsBar;
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
end;

{ ── snapshot rendering ─────────────────────────────────────────── }

procedure TAiFrame.SetSnapshot(const ASnap: TAiConfigSnapshot);
begin
  FLoaded := ASnap;
  RenderCurrent(ASnap);
  FillEditorsFromSnapshot(ASnap);
end;

procedure TAiFrame.RenderCurrent(const ASnap: TAiConfigSnapshot);
  function Dash(const AVal: RawUtf8): string;
  begin
    if AVal = '' then result := '-' else result := string(AVal);
  end;

  // Compact "18234" → "18.2k", "1042" → "1.0k", "523" → "523". Keeps
  // the value column readable at a glance while the operator scans for
  // anomalies; the raw counts are still in the JSON if they need exact
  // numbers.
  function Compact(AN: Int64): string;
  begin
    if AN >= 1000000 then
      result := FormatFloat('0.0M', AN / 1000000)
    else if AN >= 1000 then
      result := FormatFloat('0.0k', AN / 1000)
    else
      result := IntToStr(AN);
  end;

const
  BASE_ROWS = 5; // header + Provider/Model/Base URL/API key
var
  i: Integer;
begin
  FCurrentGrid.Cells[1, 1] := Dash(ASnap.Provider);
  FCurrentGrid.Cells[1, 2] := Dash(ASnap.Model);
  FCurrentGrid.Cells[1, 3] := Dash(ASnap.BaseUrl);
  if ASnap.HasKey then
    FCurrentGrid.Cells[1, 4] := 'set'
  else
    FCurrentGrid.Cells[1, 4] := 'not set  -  configure below to set one';

  // Per-(provider,model) usage since thoriumd boot. One row per
  // bucket. Empty when the daemon hasn't seen any /ai/ask traffic
  // yet (or is too old to report `usage`).
  if Length(ASnap.Usage) = 0 then
  begin
    FCurrentGrid.RowCount := BASE_ROWS + 1;
    FCurrentGrid.Cells[0, BASE_ROWS] := 'Usage (since boot)';
    FCurrentGrid.Cells[1, BASE_ROWS] := '-';
  end
  else
  begin
    FCurrentGrid.RowCount := BASE_ROWS + Length(ASnap.Usage);
    for i := 0 to High(ASnap.Usage) do
    begin
      FCurrentGrid.Cells[0, BASE_ROWS + i] :=
        'Usage  ' + string(ASnap.Usage[i].Key);
      FCurrentGrid.Cells[1, BASE_ROWS + i] := Format(
        '%s calls  -  %s in / %s out tokens (since boot)',
        [Compact(ASnap.Usage[i].Calls),
         Compact(ASnap.Usage[i].InputTokens),
         Compact(ASnap.Usage[i].OutputTokens)]);
    end;
  end;
end;

procedure TAiFrame.FillEditorsFromSnapshot(const ASnap: TAiConfigSnapshot);
begin
  SetProviderCombo(ASnap.Provider);
  // API key field is always blank — server doesn't return the saved
  // key, and we never assume the operator wants to retype it. Saving
  // with this blank means "leave server-side key as-is".
  FEdtApiKey.Text := '';
  FEdtModel.Text   := string(ASnap.Model);
  FEdtBaseUrl.Text := string(ASnap.BaseUrl);
end;

procedure TAiFrame.SetProviderCombo(const AWireId: RawUtf8);
var s: string;
begin
  s := LowerCase(string(AWireId));
  if      (s = 'anthropic') or (s = 'claude') then FCmbProvider.ItemIndex := 0
  else if s = 'openai'                         then FCmbProvider.ItemIndex := 1
  else if (s = 'grok') or (s = 'xai')         then FCmbProvider.ItemIndex := 2
  else if s = 'gemini'                         then FCmbProvider.ItemIndex := 3
  else if s = 'ollama'                         then FCmbProvider.ItemIndex := 4
  else FCmbProvider.ItemIndex := 0;
end;

function TAiFrame.ProviderWireFromCombo: RawUtf8;
begin
  case FCmbProvider.ItemIndex of
    0: result := 'anthropic';
    1: result := 'openai';
    2: result := 'grok';
    3: result := 'gemini';
    4: result := 'ollama';
  else
    result := 'anthropic';
  end;
end;

{ ── status text + handlers ─────────────────────────────────────── }

procedure TAiFrame.SetStatusText(const AText: string; AKind: Integer);
var k: TSemanticKind;
begin
  case AKind of
    1:  k := skBuy;
    -1: k := skDelete;
  else  k := skMuted;
  end;
  SetSemantic(FStatusLbl, k);
  FStatusLbl.Caption := AText;
end;

procedure TAiFrame.DoReloadClick(Sender: TObject);
begin
  if Assigned(FOnLoad) then
    FOnLoad(Self);
end;

procedure TAiFrame.DoDiscardClick(Sender: TObject);
begin
  FillEditorsFromSnapshot(FLoaded);
  SetStatusText('Discarded local edits.', 0);
end;

procedure TAiFrame.DoSaveClick(Sender: TObject);
var
  payload: TAiConfigurePayload;
begin
  payload.Provider := ProviderWireFromCombo;
  payload.ApiKey   := RawUtf8(Trim(FEdtApiKey.Text));
  payload.Model    := RawUtf8(Trim(FEdtModel.Text));
  payload.BaseUrl  := RawUtf8(Trim(FEdtBaseUrl.Text));
  if Assigned(FOnSave) then
    FOnSave(Self, payload);
end;

end.
