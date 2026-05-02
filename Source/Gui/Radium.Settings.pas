unit Radium.Settings;

(* ----------------------------------------------------------------------------
  Persistent operator settings — host URL + API key for the
  Radium ↔ thoriumd connection.

  These values authenticate Radium to thoriumd; they don't change per
  trading session. Per-broker credentials (client_id, access_token,
  feed-broker designation) are collected fresh on every Attach via the
  AttachBrokerForm and never persisted on disk.

  Storage:
    All platforms:   ~/.radium/settings.json

  Single home-directory path on every OS; no XDG / Application Support /
  AppData branching. Keeps every Radium artefact under one tree the
  operator can find with `ls ~/.radium`.

  File mode is restricted to 0600 (owner-readable only) on POSIX after
  every write — the apikey is the keys-to-the-kingdom for thoriumd.

  Wire format is JSON via mORMot's RecordSaveJson / RecordLoadJson. The
  Pascal record fields use snake_case here so the on-disk shape matches
  thoriumd's environment-variable names without a translation layer:
    THORIUM_HOST      → host
    THORIUM_APIKEY    → apikey
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  mormot.core.base;

type
  // TRadiumSettings — kept tiny on purpose. Theme persistence, proxy,
  // window geometry land in slice 3.x once first-run flow is solid.
  TRadiumSettings = record
    Host:   RawUtf8;
    Apikey: RawUtf8;
  end;

// Path of the on-disk settings file. Directory is auto-created by
// SaveSettings; LoadSettings returns False if the file is absent.
function SettingsPath: string;

// Load returns True only when the file exists AND parses; an empty
// or invalid file resets ASettings to the default and returns False
// so callers can route to the first-run setup flow.
function LoadSettings(out ASettings: TRadiumSettings): Boolean;

// Save writes the JSON, creating the directory if needed, and clamps
// the file mode to 0600 on POSIX. Raises an exception on disk error
// — the GUI is expected to surface it; we never silently lose config.
procedure SaveSettings(const ASettings: TRadiumSettings);

// IsValid — settings are usable (non-empty apikey + host). The host
// could still be unreachable; we don't dial here. First-run gate
// uses this to decide whether to show SetupForm.
function IsValid(const ASettings: TRadiumSettings): Boolean;

implementation

uses
  SysUtils,
  Classes,
  {$ifdef UNIX}
  BaseUnix,
  {$endif}
  mormot.core.os,
  mormot.core.text,
  mormot.core.variants;

const
  CFG_DIR_NAME  = '.radium';
  CFG_FILE_NAME = 'settings.json';

function SettingsPath: string;
begin
  // GetUserDir is LCL/RTL: $HOME on POSIX, %USERPROFILE% on Windows.
  // Always returns a trailing path delimiter, so no IncludeTrailing
  // wrapper needed.
  result := GetUserDir + CFG_DIR_NAME + PathDelim + CFG_FILE_NAME;
end;

function LoadSettings(out ASettings: TRadiumSettings): Boolean;
var
  raw: RawUtf8;
  v: variant;
  d: PDocVariantData;
begin
  ASettings.Host   := '';
  ASettings.Apikey := '';
  result := False;
  if not FileExists(SettingsPath) then
    exit;
  raw := StringFromFile(SettingsPath);
  if raw = '' then
    exit;
  v := _Json(raw);
  d := _Safe(v);
  if d^.Kind <> dvObject then
    exit;
  ASettings.Host   := d^.U['host'];
  ASettings.Apikey := d^.U['apikey'];
  result := True;
end;

procedure SaveSettings(const ASettings: TRadiumSettings);
var
  path:   string;
  dir:    string;
  body:   variant;
  json:   RawUtf8;
begin
  path := SettingsPath;
  dir  := ExtractFilePath(path);
  if (dir <> '') and (not DirectoryExists(dir)) then
    if not ForceDirectories(dir) then
      raise Exception.CreateFmt(
        'Radium settings: could not create directory %s', [dir]);

  body := _ObjFast([
    'host',   ASettings.Host,
    'apikey', ASettings.Apikey
  ]);
  json := VariantSaveJson(body);

  if not FileFromString(json, path) then
    raise Exception.CreateFmt(
      'Radium settings: could not write %s', [path]);

  {$ifdef UNIX}
  // 0600 — owner-read/write only. The apikey is sensitive; a stray
  // group-readable bit would leak it on a shared box. Octal literal
  // is &600 in FPC syntax (= 384 decimal).
  FpChmod(path, &600);
  {$endif}
end;

function IsValid(const ASettings: TRadiumSettings): Boolean;
begin
  result := (Trim(string(ASettings.Apikey)) <> '') and
            (Trim(string(ASettings.Host)) <> '');
end;

end.
