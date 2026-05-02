unit Radium.Gui.Errors;

(* ----------------------------------------------------------------------------
  Single helper for turning EThoriumApi (and other) exceptions into
  text the operator will actually understand. Three flavours:

    HttpCode = 0
      → transport failure: thoriumd unreachable. Most common cause is
        the daemon not running, the host URL being wrong, or a network
        path issue (proxy, VPN, firewall). The technical detail goes
        in parentheses for support tickets but doesn't lead.

    HttpCode > 0 and EThoriumApi
      → daemon responded but rejected the request. The daemon's
        own message is already human-readable (`invalid apikey`,
        `broker field required`, etc.) so we surface it verbatim
        framed by what the operator was trying to do.

    Anything else
      → bare exception, surfaced with operation framing.

  Phrasing: lead with what failed in the user's terms, then a
  short bulleted "things to check" for the transport case. Per
  Docs/LookAndFeel.md design language — plain language, less
  cognitive load.
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  SysUtils,
  Radium.Api.Types;

// HumanError formats E for an end-user message dialog.
// AOperation: short noun for what was attempted ("Sign in",
//             "Detach broker", "Refresh sessions"...). Used in the
//             daemon-responded case as a sentence lead.
// AHost:      thoriumd host URL, used in the unreachable case so
//             the operator sees what address Radium tried.
function HumanError(E: Exception; const AOperation, AHost: string): string;

implementation

function HumanError(E: Exception; const AOperation, AHost: string): string;

  // Friendly translation of common daemon-side messages. Anything that
  // doesn't match falls through to the daemon's text verbatim — the
  // current thoriumd vocabulary already reads in plain language
  // (`invalid apikey`, `broker field required`, `plan not found`).
  function HumanReason(const ARaw: string): string;
  var s: string;
  begin
    s := LowerCase(ARaw);
    if Pos('apikey', s) > 0 then
      result := 'The API key was not accepted by thoriumd. ' +
                'Open Settings and re-enter it.'
    else if Pos('broker field required', s) > 0 then
      result := 'A broker name is required. Pick one from the dropdown.'
    else if Pos('token field required', s) > 0 then
      result := 'A broker access token is required.'
    else if Pos('catalog fetch failed', s) > 0 then
      result := 'Could not load the broker''s instrument catalogue. ' +
                'Check that the access token is current and that ' +
                'the broker''s master-data service is reachable.'
    else if Pos('broker connect', s) > 0 then
      result := 'Could not connect to the broker with the supplied ' +
                'token. Tokens often expire daily — refresh and try again.'
    else if Pos('plan not found', s) > 0 then
      result := 'No matching trading plan was found.'
    else if Pos('non-json response', s) > 0 then
      result := 'thoriumd returned an unexpected response. ' +
                'Make sure the host points at a thoriumd daemon and ' +
                'not a different service on that port.'
    else
      result := ARaw;
  end;

begin
  if E is EThoriumApi then
  begin
    if EThoriumApi(E).HttpCode = 0 then
    begin
      // Transport failure. Lead with the action, then the actionable
      // checklist. No raw socket exception text — keeps the dialog
      // readable for non-developers.
      result :=
        'Unable to attach to thoriumd at ' + AHost + '.' + LineEnding +
        LineEnding +
        'Please check the network path:' + LineEnding +
        '  - thoriumd is running and listening on this host' + LineEnding +
        '  - The host URL (and port) is correct' + LineEnding +
        '  - No proxy / VPN / firewall is blocking the connection';
    end
    else
    begin
      // Daemon answered. Translate familiar messages to friendlier
      // wording; fall through to verbatim for anything novel.
      result :=
        AOperation + ' was rejected by thoriumd.' + LineEnding +
        LineEnding +
        HumanReason(E.Message);
    end;
  end
  else
    // Local / OS failure (write permission, disk full, missing file...).
    // The exception text from FPC's RTL is already in plain English.
    result := AOperation + ' could not be completed.' + LineEnding +
              LineEnding + E.Message;
end;

end.
