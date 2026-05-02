unit Radium.Gui.MainForm;

{ ----------------------------------------------------------------------------
  Radium main window. Slice 0 ships an empty form; subsequent slices
  add the menu, status bar, and the tabbed panels for plans / risk /
  status / report / events.

  IDE-editable: open Source/Gui/Radium.Gui.MainForm.lfm in Lazarus
  (or use "Open Project" on Projects/Radium.lpi and double-click the
  unit in the project inspector). The .lfm streams form properties
  the IDE designer round-trips; this .pas declares published controls
  + event handlers that match.

  Add new controls by:
    1. Drop them onto the form in Lazarus IDE; the .lfm gets updated.
    2. Lazarus regenerates the published field declarations in this
       unit (between `class(TForm)` and `private`).
  ---------------------------------------------------------------------------- }

{$mode Delphi}{$H+}

interface

uses
  Classes,
  SysUtils,
  Forms,
  Controls,
  Graphics,
  Dialogs;

type

  { TMainForm }

  TMainForm = class(TForm)
  private

  public

  end;

var
  MainForm: TMainForm;

implementation

{$R *.lfm}

end.
