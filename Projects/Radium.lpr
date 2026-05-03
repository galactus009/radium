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
  Radium.Gui.Theme    in '../Source/Gui/Radium.Gui.Theme.pas',
  Radium.Gui.QtFusion in '../Source/Gui/Radium.Gui.QtFusion.pas',
  Radium.Gui.Icons    in '../Source/Gui/Radium.Gui.Icons.pas',
  Radium.Gui.NavButton in '../Source/Gui/Radium.Gui.NavButton.pas',
  Radium.Settings     in '../Source/Gui/Radium.Settings.pas',
  Radium.Gui.MainForm in '../Source/Gui/Radium.Gui.MainForm.pas';

var
  bootSettings: TRadiumSettings;
  bootTheme:    TThemeKind;
begin
  RequireDerivedFormResource := True;
  Application.Title := 'Radium';
  Application.Scaled := True;
  Application.Initialize;
  // Fusion style + initial palette applied before CreateForm so the
  // main form inherits a fully-themed QApplication. Theme defaults to
  // light; if the operator's prior session toggled to dark it'll be
  // in settings.json — boot reads it and applies before the form
  // construction so the welcome card never flashes the wrong palette.
  InstallFusionStyle;
  bootTheme := tkLight;
  if LoadSettings(bootSettings) and (bootSettings.Theme = 'dark') then
    bootTheme := tkDark;
  ApplyFusionTheme(bootTheme);
  // Register the icon font (Phosphor TTF in Resources/Fonts/), if
  // present. Optional — system Unicode glyphs render fine without it.
  LoadIconFont;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
