program Radium;

{ ----------------------------------------------------------------------------
  Radium GUI client of thoriumd. Lazarus + FPC + Qt6 widgetset.
  Mac primary, Linux must, Windows last. Selects widgetset via the
  --ws=qt6 flag on lazbuild; same .lpr serves all three platforms.
  ---------------------------------------------------------------------------- }

{$mode Delphi}{$H+}

uses
  {$ifdef UNIX}
  cthreads,
  cwstring,
  {$endif}
  Interfaces,
  Forms,
  Radium.Gui.MainForm in '../Source/Gui/Radium.Gui.MainForm.pas';

begin
  RequireDerivedFormResource := True;
  Application.Title := 'Radium';
  Application.Scaled := True;
  Application.Initialize;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
