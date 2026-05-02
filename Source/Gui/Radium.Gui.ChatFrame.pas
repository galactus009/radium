unit Radium.Gui.ChatFrame;

(* ----------------------------------------------------------------------------
  Chat frame — Pascal port of `cmd/chatbuddy` for the AI panel's "Chat"
  tab. Multi-turn conversation with thoriumd's `/ai/ask`. The Go binary
  is going away the same way the clerk binary is; this is the in-Radium
  replacement.

  v1 scope (this file):
    - Free-form natural-language input
    - Multi-turn history (last 20 exchanges by default)
    - Optional system prompt
    - Backend toggle: thoriumd (/ai/ask) OR direct local ollama
      (http://127.0.0.1:11434/api/chat). Direct ollama means chat
      works even when thoriumd is unreachable, and prompts never
      leave the operator's machine when they don't need to.
    - Send → backend → render reply
    - Clear conversation

  v2 (queued):
    - Slash commands (/pos, /orders, /strategy, …) routed through
      thoriumd's MCP — needs `TThoriumClient.McpCall` first.
    - Tool-call auto-dispatch: detect `TOOL_CALL: {tool, args}` in
      replies, run via /mcp, feed result back into the conversation.
    - Streaming via `/ai/stream` (SSE) when /ai/ask becomes the slow
      path on long replies.

  Wire mapping
  ────────────
    /ai/ask body fields the GUI uses today (see Radium.Api.Client):
        prompt   ← latest user message
        system   ← optional system instruction (top of frame)
        context  ← prior turns concatenated, "User: ...\nAssistant: ..."

    The thoriumd handler treats `context` as opaque text to splice
    into the LLM's message list. We keep the format simple-and-stable
    so a future change to how thoriumd builds messages doesn't break
    the GUI — the format only has to round-trip through the operator's
    eye, never through code.

  Coupling
  ────────
    Frame is HTTP-free. Send raises `OnAskRequested`; MainForm calls
    `TThoriumClient.AiAsk` and feeds the reply back via `AppendReply`.
    Same pattern as every other frame in this tree.
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
  mormot.core.base,
  Radium.Gui.Theme;

type
  // TChatBackend — where to send the prompt. The wire shape on the
  // other side is different per backend; MainForm dispatches.
  //   cbThoriumd → POST /ai/ask via TThoriumClient (multi-provider
  //                routing happens server-side; use whatever
  //                provider you set on the Configure tab).
  //   cbOllamaLocal → POST <url>/api/chat directly. Local-only, no
  //                   thoriumd dep, no provider key needed.
  TChatBackend = (cbThoriumd, cbOllamaLocal);

  // TChatAskRequest — what the frame asks MainForm to submit. Frame
  // doesn't know about TThoriumClient or any HTTP machinery.
  TChatAskRequest = record
    Backend:     TChatBackend;
    Prompt:      RawUtf8;     // latest user message
    System:      RawUtf8;     // optional system instruction; '' = none
    Context:     RawUtf8;     // serialised prior turns
    OllamaUrl:   RawUtf8;     // 'http://127.0.0.1:11434' (only for cbOllamaLocal)
    OllamaModel: RawUtf8;     // 'llama3.2' (only for cbOllamaLocal)
  end;

  TChatAskEvent = procedure(Sender: TObject;
    const ARequest: TChatAskRequest) of object;

  { TChatFrame }
  TChatFrame = class(TPanel)
  private
    FTopBar:        TPanel;
      FLblBackend:  TLabel;
      FCmbBackend:  TComboBox;
      FLblOllamaUrl:   TLabel;
      FEdtOllamaUrl:   TEdit;
      FLblOllamaModel: TLabel;
      FEdtOllamaModel: TEdit;
      FLblSystem:   TLabel;
      FEdtSystem:   TEdit;
      FBtnClear:    TButton;
      FStatusLbl:   TLabel;

    FLog:           TMemo;

    FBottomBar:     TPanel;
      FEdtPrompt:   TEdit;
      FBtnSend:     TButton;

    // Per-turn rolling history. Plain TStringList in pairs:
    //   index 0   : 'User: <msg>'
    //   index 1   : 'Assistant: <reply>'
    //   index 2   : 'User: ...'
    //   ...
    // Caps at MAX_HISTORY_TURNS * 2 lines. Older entries fall off.
    FHistory:       TStringList;

    FOnAskRequested: TChatAskEvent;
    FBusy:          Boolean;

    procedure BuildTopBar;
    procedure BuildLog;
    procedure BuildBottomBar;

    procedure DoSendClick(Sender: TObject);
    procedure DoClearClick(Sender: TObject);
    procedure DoPromptKeyPress(Sender: TObject; var Key: Char);
    procedure DoBackendChange(Sender: TObject);
    procedure ApplyBackendVisibility;
    function CurrentBackend: TChatBackend;

    function ContextFromHistory: RawUtf8;
    procedure AppendLogLine(const ARole, AText: string;
      AKind: TSemanticKind);
    procedure SetBusy(ABusy: Boolean);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    // Caller invokes after the AskRequested event finishes. AReply is
    // whatever /ai/ask returned (or an error message if it failed).
    procedure AppendReply(const AReply: RawUtf8; AOk: Boolean);

    procedure SetStatusText(const AText: string; AKind: Integer);

    property OnAskRequested: TChatAskEvent read FOnAskRequested write FOnAskRequested;
  end;

implementation

const
  // Turn = one user/assistant pair. Twenty exchanges is the same
  // window chatbuddy used; long enough to pick up context, short
  // enough to keep prompt size reasonable.
  MAX_HISTORY_TURNS = 20;

{ TChatFrame ──────────────────────────────────────────────────────── }

constructor TChatFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption    := '';

  FHistory := TStringList.Create;

  BuildTopBar;
  BuildBottomBar;
  BuildLog;        // built last so alClient stretches between alTop/alBottom
end;

destructor TChatFrame.Destroy;
begin
  FHistory.Free;
  inherited Destroy;
end;

procedure TChatFrame.BuildTopBar;
  function MakeCap(const ACaption: string; ALeft, ATop: Integer): TLabel;
  begin
    result := TLabel.Create(FTopBar);
    result.Parent := FTopBar;
    result.Caption := ACaption;
    result.Left := ALeft; result.Top := ATop;
    result.AutoSize := True;
    result.Font.Height := -10;
    result.Font.Style := [fsBold];
    result.ParentColor := True;
    result.ParentFont := False;
    SetSemantic(result, skMuted);
  end;
begin
  FTopBar := TPanel.Create(Self);
  FTopBar.Parent     := Self;
  FTopBar.Align      := alTop;
  FTopBar.Height     := 124;       // taller to fit backend + ollama strip
  FTopBar.BevelOuter := bvNone;
  FTopBar.Caption    := '';

  // Row 1 — backend selector + ollama URL/model (visible only when
  // backend = ollama).
  FLblBackend := MakeCap('Backend', 16, 8);
  FCmbBackend := TComboBox.Create(FTopBar);
  FCmbBackend.Parent := FTopBar;
  FCmbBackend.Left   := 16;
  FCmbBackend.Top    := 28;
  FCmbBackend.Width  := 200;
  FCmbBackend.Height := 28;
  FCmbBackend.Style  := csDropDownList;
  FCmbBackend.Items.Add('thoriumd  (server-side)');
  FCmbBackend.Items.Add('Local ollama');
  FCmbBackend.ItemIndex := 0;
  FCmbBackend.OnChange := DoBackendChange;

  FLblOllamaUrl := MakeCap('Ollama URL', 232, 8);
  FEdtOllamaUrl := TEdit.Create(FTopBar);
  FEdtOllamaUrl.Parent := FTopBar;
  FEdtOllamaUrl.Left   := 232;
  FEdtOllamaUrl.Top    := 28;
  FEdtOllamaUrl.Width  := 240;
  FEdtOllamaUrl.Height := 28;
  FEdtOllamaUrl.Text   := 'http://127.0.0.1:11434';
  FEdtOllamaUrl.TextHint := 'http://127.0.0.1:11434';

  FLblOllamaModel := MakeCap('Model', 488, 8);
  FEdtOllamaModel := TEdit.Create(FTopBar);
  FEdtOllamaModel.Parent := FTopBar;
  FEdtOllamaModel.Left   := 488;
  FEdtOllamaModel.Top    := 28;
  FEdtOllamaModel.Width  := 200;
  FEdtOllamaModel.Height := 28;
  FEdtOllamaModel.Text   := 'llama3.2';
  FEdtOllamaModel.TextHint := 'llama3.2';

  FBtnClear := TButton.Create(FTopBar);
  FBtnClear.Parent  := FTopBar;
  FBtnClear.Left    := 832;
  FBtnClear.Top     := 28;
  FBtnClear.Width   := 160;
  FBtnClear.Height  := 28;
  FBtnClear.Caption := 'Clear conversation';
  FBtnClear.Anchors := [akTop, akRight];
  FBtnClear.OnClick := DoClearClick;
  SetSemantic(FBtnClear, skMuted);

  // Row 2 — system prompt (always visible).
  FLblSystem := MakeCap('System prompt  (optional)', 16, 68);
  FEdtSystem := TEdit.Create(FTopBar);
  FEdtSystem.Parent := FTopBar;
  FEdtSystem.Left   := 16;
  FEdtSystem.Top    := 88;
  FEdtSystem.Width  := 800;
  FEdtSystem.Height := 28;
  FEdtSystem.Anchors  := [akLeft, akTop, akRight];
  FEdtSystem.TextHint :=
    'e.g. "You are an Indian-options trading assistant. Be concise."';

  FStatusLbl := TLabel.Create(FTopBar);
  FStatusLbl.Parent  := FTopBar;
  FStatusLbl.Left    := 832;
  FStatusLbl.Top     := 92;
  FStatusLbl.AutoSize := True;
  FStatusLbl.Anchors := [akTop, akRight];
  FStatusLbl.Caption := '';
  FStatusLbl.Font.Height := -11;
  FStatusLbl.ParentColor := True;
  FStatusLbl.ParentFont := False;
  SetSemantic(FStatusLbl, skMuted);

  ApplyBackendVisibility;
end;

procedure TChatFrame.BuildBottomBar;
begin
  FBottomBar := TPanel.Create(Self);
  FBottomBar.Parent     := Self;
  FBottomBar.Align      := alBottom;
  FBottomBar.Height     := 64;
  FBottomBar.BevelOuter := bvNone;
  FBottomBar.Caption    := '';

  FBtnSend := TButton.Create(FBottomBar);
  FBtnSend.Parent  := FBottomBar;
  FBtnSend.Left    := 0;       // aligned via anchors below
  FBtnSend.Top     := 16;
  FBtnSend.Width   := 110;
  FBtnSend.Height  := 32;
  FBtnSend.Caption := 'Send';
  FBtnSend.Default := True;
  FBtnSend.Anchors := [akTop, akRight];
  FBtnSend.Font.Style := [fsBold];
  FBtnSend.ParentFont := False;
  FBtnSend.OnClick := DoSendClick;
  SetSemantic(FBtnSend, skPrimary);
  // Anchor flush right with a 16px right margin via Align logic.
  FBtnSend.AnchorSideRight.Side := asrBottom;

  FEdtPrompt := TEdit.Create(FBottomBar);
  FEdtPrompt.Parent := FBottomBar;
  FEdtPrompt.Left   := 16;
  FEdtPrompt.Top    := 18;
  FEdtPrompt.Width  := 900;
  FEdtPrompt.Height := 28;
  FEdtPrompt.Anchors := [akLeft, akTop, akRight];
  FEdtPrompt.TextHint := 'Ask anything... press Enter to send';
  FEdtPrompt.OnKeyPress := DoPromptKeyPress;

  // Position Send manually so it sits at the right edge of FBottomBar.
  // Anchors take care of resize; initial coords assume the parent's
  // ClientWidth at first show.
  FBtnSend.Left := FBottomBar.ClientWidth - FBtnSend.Width - 16;
  FEdtPrompt.Width := FBtnSend.Left - FEdtPrompt.Left - 12;
end;

procedure TChatFrame.BuildLog;
begin
  FLog := TMemo.Create(Self);
  FLog.Parent      := Self;
  FLog.Align       := alClient;
  FLog.ReadOnly    := True;
  FLog.ScrollBars  := ssAutoVertical;
  FLog.WordWrap    := True;
  FLog.Font.Name   := 'Menlo';
  FLog.Font.Height := -12;
  FLog.ParentFont  := False;
  // Initial onboarding hint — disappears as soon as the first turn
  // appends. Cheap + friendly, no special "empty state" plumbing.
  FLog.Lines.Add('# AI Chat (chatbuddy)');
  FLog.Lines.Add('');
  FLog.Lines.Add('Multi-turn conversation routed to thoriumd''s /ai/ask.');
  FLog.Lines.Add('Type below; press Enter or click Send.');
  FLog.Lines.Add('');
  FLog.Lines.Add('Configure your AI provider on the Configure tab if you');
  FLog.Lines.Add('haven''t already.');
  FLog.Lines.Add('');
end;

{ ── send / clear flow ────────────────────────────────────────── }

procedure TChatFrame.DoSendClick(Sender: TObject);
var
  prompt: string;
  req: TChatAskRequest;
begin
  if FBusy then exit;
  prompt := Trim(FEdtPrompt.Text);
  if prompt = '' then exit;

  AppendLogLine('You', prompt, skNeutral);
  FEdtPrompt.Text := '';
  SetBusy(True);

  req.Backend     := CurrentBackend;
  req.Prompt      := RawUtf8(prompt);
  req.System      := RawUtf8(Trim(FEdtSystem.Text));
  req.Context     := ContextFromHistory;
  req.OllamaUrl   := RawUtf8(Trim(FEdtOllamaUrl.Text));
  req.OllamaModel := RawUtf8(Trim(FEdtOllamaModel.Text));
  if Assigned(FOnAskRequested) then
    FOnAskRequested(Self, req);
end;

procedure TChatFrame.DoBackendChange(Sender: TObject);
begin
  ApplyBackendVisibility;
end;

procedure TChatFrame.ApplyBackendVisibility;
var isOllama: Boolean;
begin
  isOllama := CurrentBackend = cbOllamaLocal;
  FLblOllamaUrl.Visible   := isOllama;
  FEdtOllamaUrl.Visible   := isOllama;
  FLblOllamaModel.Visible := isOllama;
  FEdtOllamaModel.Visible := isOllama;
end;

function TChatFrame.CurrentBackend: TChatBackend;
begin
  if FCmbBackend.ItemIndex = 1 then
    result := cbOllamaLocal
  else
    result := cbThoriumd;
end;

procedure TChatFrame.DoClearClick(Sender: TObject);
begin
  FHistory.Clear;
  FLog.Lines.Clear;
  FLog.Lines.Add('# Conversation cleared.');
  FLog.Lines.Add('');
  SetStatusText('', 0);
end;

procedure TChatFrame.DoPromptKeyPress(Sender: TObject; var Key: Char);
begin
  // Enter sends; the TButton.Default property on FBtnSend would
  // handle this if the form were modal, but inside a frame we wire
  // it explicitly. Shift+Enter for newline isn't supported here —
  // the prompt is single-line by design (it's a chat box, not an
  // editor). Long messages should be drafted elsewhere and pasted.
  if Key = #13 then
  begin
    Key := #0;
    DoSendClick(nil);
  end;
end;

procedure TChatFrame.AppendReply(const AReply: RawUtf8; AOk: Boolean);
var
  reply: string;
  i: Integer;
  found: string;
begin
  SetBusy(False);
  reply := Trim(string(AReply));
  if reply = '' then
    reply := '(empty reply)';
  if AOk then
  begin
    AppendLogLine('Assistant', reply, skInfo);
    if (FHistory.Count >= MAX_HISTORY_TURNS * 2) then
    begin
      FHistory.Delete(0);
      if FHistory.Count > 0 then FHistory.Delete(0);
    end;
    found := '';
    for i := FLog.Lines.Count - 1 downto 0 do
      if Pos('You: ', FLog.Lines[i]) = 1 then
      begin
        found := Copy(FLog.Lines[i], 6, MaxInt);
        break;
      end;
    if found <> '' then
      FHistory.Add('User: ' + found);
    FHistory.Add('Assistant: ' + reply);
  end
  else
    AppendLogLine('Error', reply, skDelete);
end;

procedure TChatFrame.SetStatusText(const AText: string; AKind: Integer);
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

{ ── helpers ──────────────────────────────────────────────────── }

procedure TChatFrame.SetBusy(ABusy: Boolean);
begin
  FBusy := ABusy;
  FBtnSend.Enabled  := not ABusy;
  FEdtPrompt.Enabled := not ABusy;
  if ABusy then
    SetStatusText('thinking...', 0)
  else
    SetStatusText('', 0);
end;

procedure TChatFrame.AppendLogLine(const ARole, AText: string;
  AKind: TSemanticKind);
var
  hdr, line: string;
  body: TStringList;
  i: Integer;
begin
  // Header line, then each newline-separated chunk indented under it.
  // Memo doesn't support per-line colour without RTF — colour cue is
  // the role label only ("You: ..."), but the row prefix makes the
  // role obvious at a glance.
  hdr := ARole + ': ';

  // Split AText on hard newlines so multi-paragraph replies render
  // with internal structure preserved, not run together as one line.
  body := TStringList.Create;
  try
    body.Text := AText;
    if body.Count = 0 then body.Add('');
    line := hdr + body[0];
    FLog.Lines.Add(line);
    for i := 1 to body.Count - 1 do
      FLog.Lines.Add('  ' + body[i]);
    FLog.Lines.Add('');
  finally
    body.Free;
  end;
  // Scroll to bottom — without this the operator has to drag the
  // scrollbar after every reply, which gets old fast.
  FLog.SelStart  := Length(FLog.Lines.Text);
  FLog.SelLength := 0;
end;

function TChatFrame.ContextFromHistory: RawUtf8;
var
  s: TStringBuilder;
  i: Integer;
begin
  if FHistory.Count = 0 then exit('');
  s := TStringBuilder.Create;
  try
    for i := 0 to FHistory.Count - 1 do
    begin
      s.Append(FHistory[i]);
      if i < FHistory.Count - 1 then
        s.AppendLine;
    end;
    result := RawUtf8(s.ToString);
  finally
    s.Free;
  end;
end;

end.
