unit Radium.Gui.AttachBrokerForm;

(* ----------------------------------------------------------------------------
  Attach Broker dialog — credential entry only. Owns no HTTP state.

  Maps onto the request body of POST /login (Docs/ThoriumdContract.md
  §2.1):

      apikey       ← from settings, not this dialog
      broker       ← FBroker
      token        ← FClientId + ':' + FAccessToken   (Fyers shape)
      instance_id  ← FInstanceId  (optional; "" → server picks broker name)
      feed         ← FFeedHint    (tri-state: auto / true / false)

  Two modes, same form:

    abFresh   — used by Sessions panel "+ Attach". All fields blank,
                broker dropdown defaults to "fyers", role defaults to
                Auto. Title: "Attach a broker".
    abModify  — used by Sessions row "Modify". Broker + instance are
                pre-filled and read-only; operator updates token /
                role only. Title: "Modify session". Submission triggers
                refresh (logout + login) under that instance.

  Token wire format is Fyers-specific (`client_id:access_token`).
  Other brokers join differently; broaden the helper at the top of
  the implementation when those land.
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
  Radium.Api.Types;

type
  TAttachKind = (abFresh, abModify);

  { TAttachBrokerForm }
  TAttachBrokerForm = class(TForm)
    Card:             TPanel;
      LblTitle:       TLabel;
      LblSubtitle:    TLabel;

      LblBroker:      TLabel;
      CmbBroker:      TComboBox;

      LblInstance:    TLabel;
      EdtInstance:    TEdit;
      LblInstanceHint:TLabel;

      LblClientId:    TLabel;
      EdtClientId:    TEdit;
      LblClientIdHint:TLabel;

      LblAccessToken: TLabel;
      EdtAccessToken: TEdit;
      LblTokenHint:   TLabel;

      LblRole:        TLabel;
      RbRoleAuto:     TRadioButton;
      RbRoleFeed:     TRadioButton;
      RbRoleRest:     TRadioButton;
      LblRoleHint:    TLabel;

      BtnAttach:      TButton;
      BtnCancel:      TButton;

    procedure FormCreate(Sender: TObject);
    procedure BtnAttachClick(Sender: TObject);
    procedure BtnCancelClick(Sender: TObject);

  private
    FKind: TAttachKind;
    function GetBroker:          RawUtf8;
    function GetInstanceId:      RawUtf8;
    function GetClientId:        RawUtf8;
    function GetAccessToken:     RawUtf8;
    function GetFeedHint:        TFeedHint;
    function GetWireToken:       RawUtf8;
    procedure ApplyKind;
  public
    // Constructor — caller decides mode + initial values for modify.
    constructor CreateForKind(AOwner: TComponent; AKind: TAttachKind;
      const ABroker, AInstanceId: RawUtf8);

    // Read after ShowModal = mrOk. WireToken is what /login wants; the
    // GUI never re-displays it.
    property Broker:      RawUtf8   read GetBroker;
    property InstanceId:  RawUtf8   read GetInstanceId;
    property ClientId:    RawUtf8   read GetClientId;
    property AccessToken: RawUtf8   read GetAccessToken;
    property WireToken:   RawUtf8   read GetWireToken;
    property FeedHint:    TFeedHint read GetFeedHint;
  end;

implementation

uses
  Radium.Gui.Theme;

{$R *.lfm}

{ TAttachBrokerForm ────────────────────────────────────────────────── }

constructor TAttachBrokerForm.CreateForKind(AOwner: TComponent;
  AKind: TAttachKind; const ABroker, AInstanceId: RawUtf8);
begin
  inherited Create(AOwner);
  FKind := AKind;
  if ABroker <> '' then
    CmbBroker.Text := string(ABroker);
  if AInstanceId <> '' then
    EdtInstance.Text := string(AInstanceId);
  ApplyKind;
end;

procedure TAttachBrokerForm.FormCreate(Sender: TObject);
begin
  // Default broker list — extend when adapters in thoriumd's
  // broker/ directory grow. Order matches the order the user is
  // most likely to attach in (Fyers first; it's the reference
  // adapter and the only one with mature catalogue support today).
  CmbBroker.Items.Clear;
  CmbBroker.Items.Add('fyers');
  CmbBroker.Items.Add('kite');
  CmbBroker.Items.Add('shoonya');
  CmbBroker.Items.Add('upstox');
  CmbBroker.Items.Add('indmoney');
  if CmbBroker.Text = '' then
    CmbBroker.Text := 'fyers';

  RbRoleAuto.Checked := True;

  // Semantic colour tagging — see Docs/LookAndFeel.md §1.5.
  SetSemantic(LblTitle,        skNeutral);
  SetSemantic(LblSubtitle,     skMuted);
  SetSemantic(LblInstanceHint, skMuted);
  SetSemantic(LblClientIdHint, skMuted);
  SetSemantic(LblTokenHint,    skMuted);
  SetSemantic(LblRoleHint,     skMuted);
  SetSemantic(BtnAttach,       skPrimary);
  SetSemantic(BtnCancel,       skMuted);

  Radium.Gui.Theme.Apply(Self);
end;

procedure TAttachBrokerForm.ApplyKind;
begin
  case FKind of
    abFresh:
      begin
        Caption          := 'Attach a broker';
        LblTitle.Caption := 'Attach a broker';
        LblSubtitle.Caption :=
          'thoriumd will hold the broker session and route market data + ' +
          'orders. You can attach more than one — each gets its own ' +
          'instance ID.';
        BtnAttach.Caption := 'Attach';
        CmbBroker.Enabled   := True;
        EdtInstance.Enabled := True;
      end;
    abModify:
      begin
        Caption          := 'Modify session';
        LblTitle.Caption := 'Modify session';
        LblSubtitle.Caption :=
          'Refresh credentials or change role for this session. ' +
          'Open positions on the broker side are unaffected; ' +
          'thoriumd reattaches with the new token.';
        BtnAttach.Caption := 'Apply';
        // Broker + instance lock so refresh hits the same slot.
        CmbBroker.Enabled   := False;
        EdtInstance.Enabled := False;
      end;
  end;
end;

procedure TAttachBrokerForm.BtnAttachClick(Sender: TObject);
begin
  // Validate locally so the modal closes only when MainForm has
  // everything /login needs. Server-side errors (bad token, broker
  // unreachable) still surface in MainForm's catch handler.
  if Trim(CmbBroker.Text) = '' then
  begin
    ShowMessage('Broker is required.');
    CmbBroker.SetFocus;
    exit;
  end;
  if Trim(EdtClientId.Text) = '' then
  begin
    ShowMessage(
      'Client ID is required.' + LineEnding + LineEnding +
      'For Fyers this is your APP_ID; for other brokers it''s the ' +
      'equivalent account identifier.');
    EdtClientId.SetFocus;
    exit;
  end;
  if Trim(EdtAccessToken.Text) = '' then
  begin
    ShowMessage(
      'Access token is required.' + LineEnding + LineEnding +
      'For Fyers this is the JWT from your login flow; other brokers ' +
      'use a long-lived access token from their auth endpoint.');
    EdtAccessToken.SetFocus;
    exit;
  end;
  ModalResult := mrOk;
end;

procedure TAttachBrokerForm.BtnCancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

{ ── property getters ─────────────────────────────────────────────── }

function TAttachBrokerForm.GetBroker: RawUtf8;
begin result := RawUtf8(LowerCase(Trim(CmbBroker.Text))); end;

function TAttachBrokerForm.GetInstanceId: RawUtf8;
begin result := RawUtf8(Trim(EdtInstance.Text)); end;

function TAttachBrokerForm.GetClientId: RawUtf8;
begin result := RawUtf8(Trim(EdtClientId.Text)); end;

function TAttachBrokerForm.GetAccessToken: RawUtf8;
begin result := RawUtf8(Trim(EdtAccessToken.Text)); end;

function TAttachBrokerForm.GetWireToken: RawUtf8;
begin
  // Fyers shape: `client_id:access_token`. Other brokers join
  // differently; centralising here means the call site stays
  // broker-agnostic.
  result := GetClientId + ':' + GetAccessToken;
end;

function TAttachBrokerForm.GetFeedHint: TFeedHint;
begin
  if RbRoleFeed.Checked then
    result := fhTrue
  else if RbRoleRest.Checked then
    result := fhFalse
  else
    result := fhAuto;
end;

end.
