unit Radium.Gui.SymbolSearch;

{$mode Delphi}{$H+}

// TSymbolSearchEdit — autocomplete search box for instrument CIDs.
//
// Compound widget = TEdit on top + TListBox dropdown below. Operator
// types; the host fires OnSearchRequested whenever the input has been
// idle for DEBOUNCE_MS, which the host fulfils by calling thoriumd's
// /api/v1/search and writing the results into the out-array. The
// widget then renders matches in the dropdown and waits for a click.
//
// Selecting a match (mouse click or Enter on the highlighted row)
// fires OnSelected with the chosen TInstrument and collapses the
// dropdown. Esc collapses without selecting.
//
// The widget owns no thoriumd / HTTP knowledge — the OnSearchRequested
// indirection lets the order pad inject behaviour while keeping the
// widget reusable (e.g. the Plan wizard could reuse this verbatim).

interface

uses
  Classes, SysUtils,
  Controls, ExtCtrls, StdCtrls,
  Graphics, LCLType, LCLProc,
  mormot.core.base,
  Radium.Api.Types;

type
  // OnSearchRequested handler shape. Caller fills AResults and the
  // widget renders them. Sync — simpler to reason about, and the
  // search is small enough (~25 rows) that a 100-200ms blocking
  // call is acceptable on this UI thread.
  TSymbolSearchRequestEvent = procedure(Sender: TObject;
    const AQuery: RawUtf8;
    out AResults: TInstrumentArray) of object;

  TSymbolSelectedEvent = procedure(Sender: TObject;
    const AInst: TInstrument) of object;

  { TSymbolSearchEdit }
  TSymbolSearchEdit = class(TPanel)
  private
    FEdit:        TEdit;
    FList:        TListBox;
    FDebounce:    TTimer;
    FResults:     TInstrumentArray;
    FOnSearch:    TSymbolSearchRequestEvent;
    FOnSelected:  TSymbolSelectedEvent;
    FSelected:    TInstrument;
    FHasSelected: Boolean;

    procedure DoEditChange(Sender: TObject);
    procedure DoEditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure DoListClick(Sender: TObject);
    procedure DoDebounceTick(Sender: TObject);
    procedure RunSearch;
    procedure RenderResults;
    procedure HideList;
    procedure ShowList;
    procedure CommitSelection(AIndex: Integer);
  public
    constructor Create(AOwner: TComponent); override;

    procedure SetText(const AText: string);
    function  Selected: TInstrument;
    function  HasSelection: Boolean;
    procedure ClearSelection;

    property OnSearchRequested: TSymbolSearchRequestEvent
      read FOnSearch  write FOnSearch;
    property OnSelected:        TSymbolSelectedEvent
      read FOnSelected write FOnSelected;
  end;

const
  DEBOUNCE_MS  = 220;
  EDIT_HEIGHT  = 32;
  LIST_HEIGHT  = 200;

implementation

{ TSymbolSearchEdit ───────────────────────────────────────────────── }

constructor TSymbolSearchEdit.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  BevelOuter := bvNone;
  Caption := '';
  // Total height = edit + dropdown stacked. We re-anchor the list
  // visibility based on whether the operator's query has matches.
  Height := EDIT_HEIGHT;

  FEdit := TEdit.Create(Self);
  FEdit.Parent := Self;
  FEdit.Align  := alTop;
  FEdit.Height := EDIT_HEIGHT;
  FEdit.TextHint := 'symbol — start typing (e.g. NIFTY, RELIANCE, NIFTY 24500 CE)';
  FEdit.OnChange  := DoEditChange;
  FEdit.OnKeyDown := DoEditKeyDown;

  FList := TListBox.Create(Self);
  FList.Parent  := Self;
  FList.Align   := alClient;
  FList.Visible := False;
  FList.OnClick := DoListClick;

  FDebounce := TTimer.Create(Self);
  FDebounce.Enabled  := False;
  FDebounce.Interval := DEBOUNCE_MS;
  FDebounce.OnTimer  := DoDebounceTick;
end;

procedure TSymbolSearchEdit.DoEditChange(Sender: TObject);
begin
  // Any keystroke voids the prior selection. Operator must pick
  // again from the dropdown so we never carry forward a stale CID
  // that doesn't match the visible text.
  FHasSelected := False;
  // Restart the debounce — if they keep typing, the search waits.
  FDebounce.Enabled := False;
  FDebounce.Enabled := True;
end;

procedure TSymbolSearchEdit.DoEditKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  case Key of
    VK_DOWN:
      if FList.Visible and (FList.Count > 0) then
      begin
        if FList.ItemIndex < FList.Count - 1 then
          FList.ItemIndex := FList.ItemIndex + 1
        else
          FList.ItemIndex := 0;
        Key := 0;
      end;
    VK_UP:
      if FList.Visible and (FList.Count > 0) then
      begin
        if FList.ItemIndex > 0 then
          FList.ItemIndex := FList.ItemIndex - 1
        else
          FList.ItemIndex := FList.Count - 1;
        Key := 0;
      end;
    VK_RETURN:
      if FList.Visible and (FList.ItemIndex >= 0) then
      begin
        CommitSelection(FList.ItemIndex);
        Key := 0;
      end;
    VK_ESCAPE:
      if FList.Visible then
      begin
        HideList;
        Key := 0;
      end;
  end;
end;

procedure TSymbolSearchEdit.DoListClick(Sender: TObject);
begin
  if FList.ItemIndex >= 0 then
    CommitSelection(FList.ItemIndex);
end;

procedure TSymbolSearchEdit.DoDebounceTick(Sender: TObject);
begin
  FDebounce.Enabled := False;
  RunSearch;
end;

procedure TSymbolSearchEdit.RunSearch;
var
  q: RawUtf8;
begin
  q := RawUtf8(Trim(FEdit.Text));
  if Length(q) < 2 then
  begin
    HideList;
    SetLength(FResults, 0);
    exit;
  end;
  if not Assigned(FOnSearch) then exit;
  SetLength(FResults, 0);
  FOnSearch(Self, q, FResults);
  RenderResults;
end;

procedure TSymbolSearchEdit.RenderResults;
var
  i: Integer;
  inst: TInstrument;
  line: string;
begin
  FList.Items.BeginUpdate;
  try
    FList.Items.Clear;
    for i := 0 to High(FResults) do
    begin
      inst := FResults[i];
      // One row per result: "<symbol>  <CID-exchange>  <type>  lot=<n>".
      // Using two-space gaps so monospace alignment isn't required.
      line := Format('%-22s  %-10s  %-8s  lot=%d',
        [string(inst.TradingSymbol), string(inst.CidExchange),
         string(inst.InstrumentType), inst.LotSize]);
      FList.Items.Add(line);
    end;
  finally
    FList.Items.EndUpdate;
  end;

  if FList.Items.Count = 0 then
    HideList
  else
  begin
    FList.ItemIndex := 0;
    ShowList;
  end;
end;

procedure TSymbolSearchEdit.HideList;
begin
  FList.Visible := False;
  Height := EDIT_HEIGHT;
end;

procedure TSymbolSearchEdit.ShowList;
begin
  FList.Visible := True;
  Height := EDIT_HEIGHT + LIST_HEIGHT;
end;

procedure TSymbolSearchEdit.CommitSelection(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex > High(FResults)) then exit;
  FSelected := FResults[AIndex];
  FHasSelected := True;
  FEdit.OnChange := nil;
  try
    FEdit.Text := string(FSelected.TradingSymbol);
  finally
    FEdit.OnChange := DoEditChange;
  end;
  HideList;
  if Assigned(FOnSelected) then
    FOnSelected(Self, FSelected);
end;

procedure TSymbolSearchEdit.SetText(const AText: string);
begin
  FEdit.OnChange := nil;
  try
    FEdit.Text := AText;
  finally
    FEdit.OnChange := DoEditChange;
  end;
end;

function TSymbolSearchEdit.Selected: TInstrument;
begin
  result := FSelected;
end;

function TSymbolSearchEdit.HasSelection: Boolean;
begin
  result := FHasSelected;
end;

procedure TSymbolSearchEdit.ClearSelection;
begin
  FHasSelected := False;
  Finalize(FSelected);
  FillChar(FSelected, SizeOf(FSelected), 0);
end;

end.
