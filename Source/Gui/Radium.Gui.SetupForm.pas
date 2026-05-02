unit Radium.Gui.SetupForm;

(* ----------------------------------------------------------------------------
  Setup dialog. Two modes, same form:

    skFirstRun — shown automatically when no settings.json exists. The
                 only way out is to fill the fields and continue, or
                 quit the app. There is no Cancel; closing the window
                 (Esc / X) terminates Radium.
    skEdit     — opened from the sidebar Settings button. Pre-filled
                 with the current settings; Cancel + Save both visible.

  Two fields only — Host URL + API Key. Inline help under each so the
  operator never has to swivel-chair to thoriumd's docs. Per
  Docs/LookAndFeel.md design language: one obvious primary action,
  generous whitespace, plain-language labels.
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
  StdCtrls,
  ExtCtrls,
  mormot.core.base,
  Radium.Settings,
  Radium.Api.Types,
  Radium.Api.Client,
  Radium.Gui.Errors;

type
  TSetupKind = (skFirstRun, skEdit);

  { TSetupForm }
  TSetupForm = class(TForm)
    Card:           TPanel;
      LblBrand:     TLabel;
      LblTitle:     TLabel;
      LblSubtitle:  TLabel;
      LblHost:      TLabel;
      EdtHost:      TEdit;
      LblHostHint:  TLabel;
      LblApiKey:    TLabel;
      EdtApiKey:    TEdit;
      LblApiKeyHint:TLabel;
      LblSpacer:    TLabel;
      BtnSave:      TButton;
      BtnCancel:    TButton;

    procedure FormCreate(Sender: TObject);
    procedure BtnSaveClick(Sender: TObject);
    procedure BtnCancelClick(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);

  private
    FKind:     TSetupKind;
    FSettings: TRadiumSettings;
    procedure ApplyKind;
  public
    // Constructor — caller decides mode + initial values. Passing
    // skFirstRun ignores AInitial and starts blank with defaults;
    // skEdit pre-fills from AInitial.
    constructor CreateForKind(AOwner: TComponent; AKind: TSetupKind;
      const AInitial: TRadiumSettings);

    // Read after ShowModal = mrOk. The form has already validated +
    // persisted, so MainForm just consumes these values directly.
    property Settings: TRadiumSettings read FSettings;
  end;

implementation

uses
  Radium.Gui.Theme;

{$R *.lfm}

{ TSetupForm ─────────────────────────────────────────────────────────── }

constructor TSetupForm.CreateForKind(AOwner: TComponent; AKind: TSetupKind;
  const AInitial: TRadiumSettings);
begin
  inherited Create(AOwner);
  FKind := AKind;
  FSettings := AInitial;
  ApplyKind;
end;

procedure TSetupForm.FormCreate(Sender: TObject);
begin
  // Sane defaults pre-fill so the operator only fills what's missing.
  // THORIUM_HOST default matches thoriumctl exactly.
  if EdtHost.Text = '' then
    EdtHost.Text := 'http://localhost:8080';

  // Semantic colour tagging — see Docs/LookAndFeel.md §1.5.
  SetSemantic(LblBrand,    skPrimary);
  SetSemantic(LblTitle,    skNeutral);
  SetSemantic(LblSubtitle, skMuted);
  SetSemantic(LblHostHint, skMuted);
  SetSemantic(LblApiKeyHint, skMuted);
  SetSemantic(BtnSave,     skPrimary);
  SetSemantic(BtnCancel,   skMuted);

  Radium.Gui.Theme.Apply(Self);
end;

procedure TSetupForm.ApplyKind;
begin
  case FKind of
    skFirstRun:
      begin
        Caption          := 'Welcome to Radium';
        LblTitle.Caption := 'Connect to thoriumd';
        LblSubtitle.Caption :=
          'Radium is a desktop console for thoriumd, the trading daemon. ' +
          'Tell it where thoriumd lives and which API key to use.';
        BtnSave.Caption  := 'Save and continue';
        BtnCancel.Visible := False;
      end;
    skEdit:
      begin
        Caption          := 'Settings';
        LblTitle.Caption := 'Connection settings';
        LblSubtitle.Caption :=
          'Update where Radium connects. Changes take effect on the next ' +
          'attach — existing sessions stay attached until detached.';
        BtnSave.Caption  := 'Save';
        BtnCancel.Visible := True;
      end;
  end;
  // Pre-fill from initial values so edit mode shows the operator's
  // current config. First-run leaves them blank (with default host).
  if FSettings.Host <> '' then
    EdtHost.Text := string(FSettings.Host);
  EdtApiKey.Text := string(FSettings.Apikey);
end;

procedure TSetupForm.BtnSaveClick(Sender: TObject);
var
  s:      TRadiumSettings;
  client: TThoriumClient;
  status: TStatusResult;
begin
  s.Host   := RawUtf8(Trim(EdtHost.Text));
  s.Apikey := RawUtf8(Trim(EdtApiKey.Text));

  if not IsValid(s) then
  begin
    ShowMessage(
      'Both fields are required.' + LineEnding + LineEnding +
      'Host is the URL where thoriumd listens (e.g. http://localhost:8080). ' +
      'API key is whatever you set THORIUM_APIKEY to when starting thoriumd.');
    if Trim(EdtHost.Text) = '' then EdtHost.SetFocus
    else EdtApiKey.SetFocus;
    exit;
  end;

  // Probe thoriumd before accepting Save. /status exercises both
  // the host (transport reachability) and the apikey (authentication)
  // in one round-trip. Cheaper to fail here, where the operator is
  // looking at the fields, than to fail later when they click a
  // sidebar button. Short timeout so an unreachable host doesn't
  // freeze the dialog for two minutes — config-time, not run-time.
  client := TThoriumClient.Create(s.Host, s.Apikey);
  try
    client.TimeoutMs := 5000;
    Screen.Cursor := crHourGlass;
    try
      try
        status := client.Status;
      except
        on E: Exception do
        begin
          ShowMessage(HumanError(E,
            'Connection check', string(s.Host)));
          exit;
        end;
      end;
    finally
      Screen.Cursor := crDefault;
    end;
    // Status accessed but unused — the call itself is the validation.
    if status.Uptime = '' then
      ; // touch the field so the compiler doesn't elide the call
  finally
    client.Free;
  end;

  try
    SaveSettings(s);
  except
    on E: Exception do
    begin
      ShowMessage(HumanError(E, 'Save settings', ''));
      exit;
    end;
  end;

  FSettings := s;
  ModalResult := mrOk;
end;

procedure TSetupForm.BtnCancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

procedure TSetupForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  // First-run dismissal terminates the app — without settings, Radium
  // has nothing to talk to. Edit mode lets the operator cancel out
  // without effect.
  if (FKind = skFirstRun) and (ModalResult <> mrOk) then
  begin
    if MessageDlg('Quit Radium?',
         'Radium needs a host and API key to run. Quit without saving?',
         mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    begin
      Application.Terminate;
      CanClose := True;
    end
    else
      CanClose := False;
  end;
end;

end.
