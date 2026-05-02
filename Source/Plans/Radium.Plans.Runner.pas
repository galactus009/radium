unit Radium.Plans.Runner;

(* ----------------------------------------------------------------------------
  Plan runner abstraction. The wizard produces a TPlanCreateRequest;
  a TPlanRunner submits / lists / mutates plans. Today the only runner
  is TServerPlanRunner — a thin wrapper over TThoriumClient hitting
  thoriumd's /api/v1/plans/* endpoints. Tomorrow's TLocalPlanRunner
  will execute the same TPlanCreateRequest in-process by routing on
  capability to a Pascal port of the bot.

  Why an abstraction now: the wizard is HTTP-free by design (memory:
  plan_execution_target.md). MainForm holds a TPlanRunner, not a
  TThoriumClient, for plan operations — so swapping execution targets
  is a single field reassignment, not a re-write of every call site.

  Lifetimes: the runner does NOT own the underlying TThoriumClient.
  MainForm owns one client for everything (sessions, status, plans);
  the runner just borrows it. Free the runner before the client.

  Contract: every method either succeeds (returning the raw success
  body for endpoints that hand back data, or '' for endpoints that
  don't) or raises EThoriumApi via the underlying client. Callers
  that want typed parsing pull plan_id / status from the success body
  themselves — keeps this layer thin.
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  Classes,
  SysUtils,
  mormot.core.base,
  Radium.Api.Types,
  Radium.Api.Client;

type
  // TPlanRunner — abstract base. All public methods are virtual+abstract;
  // concrete subclasses implement against either thoriumd's REST surface
  // (today) or an in-process bot dispatch (future).
  TPlanRunner = class
  public
    constructor Create; virtual;

    // Submit a freshly-built plan. Returns the raw success body of
    // /plans/create — caller extracts plan_id from it. Raises on
    // transport / daemon-side failure.
    function Submit(const ARequest: TPlanCreateRequest): RawUtf8; virtual; abstract;

    // List plans for a given instance + status filter. Pass '' for
    // AInstanceId to list across all instances; pass [] for AStatuses
    // for "all statuses".
    function List(const AInstanceId: RawUtf8;
      const AStatuses: array of RawUtf8): TPlanRefArray; virtual; abstract;

    // Get full plan body as raw JSON. Used by the View / Edit panels
    // to render or pre-populate a wizard.
    function GetPlan(const APlanId, AInstanceId: RawUtf8): RawUtf8; virtual; abstract;

    // Patch — APatchJson is the operator's intended changes (status
    // change, risk tighten, param tweak). Raw JSON in, raw response
    // body out so the caller stays in control of the wire shape.
    function Patch(const APlanId, APatchJson, AInstanceId,
      ANote: RawUtf8): RawUtf8; virtual; abstract;

    // Halt / Resume are convenience patches over Patch. Defaults
    // implement them in terms of Patch so subclasses only need to
    // override Patch when the underlying mechanism is the same.
    function HaltPlan(const APlanId, AInstanceId: RawUtf8;
      const ANote: RawUtf8 = ''): RawUtf8; virtual;
    function ResumePlan(const APlanId, AInstanceId: RawUtf8;
      const ANote: RawUtf8 = ''): RawUtf8; virtual;

    // Cancel — terminal. Subclasses implement directly (the server
    // route is /plans/cancel; the local runner will have to stop the
    // in-process bot loop, then mark its persisted state cancelled).
    function Cancel(const APlanId, AInstanceId: RawUtf8;
      const ANote: RawUtf8 = ''): RawUtf8; virtual; abstract;
  end;

  // TServerPlanRunner — runner backed by thoriumd's /api/v1/plans/*.
  // Borrows a TThoriumClient from the caller; does not own it.
  TServerPlanRunner = class(TPlanRunner)
  private
    FClient: TThoriumClient;
  public
    constructor Create(AClient: TThoriumClient); reintroduce;
    function Submit(const ARequest: TPlanCreateRequest): RawUtf8; override;
    function List(const AInstanceId: RawUtf8;
      const AStatuses: array of RawUtf8): TPlanRefArray; override;
    function GetPlan(const APlanId, AInstanceId: RawUtf8): RawUtf8; override;
    function Patch(const APlanId, APatchJson, AInstanceId,
      ANote: RawUtf8): RawUtf8; override;
    function Cancel(const APlanId, AInstanceId: RawUtf8;
      const ANote: RawUtf8 = ''): RawUtf8; override;
  end;

implementation

{ TPlanRunner ───────────────────────────────────────────────────────── }

constructor TPlanRunner.Create;
begin
  inherited Create;
end;

function TPlanRunner.HaltPlan(const APlanId, AInstanceId, ANote: RawUtf8): RawUtf8;
begin
  // Status patches are JSON literals — small enough to inline rather
  // than build a variant for. Keeps this layer mORMot-free.
  result := Patch(APlanId, '{"status":"halted"}', AInstanceId, ANote);
end;

function TPlanRunner.ResumePlan(const APlanId, AInstanceId, ANote: RawUtf8): RawUtf8;
begin
  result := Patch(APlanId, '{"status":"running"}', AInstanceId, ANote);
end;

{ TServerPlanRunner ─────────────────────────────────────────────────── }

constructor TServerPlanRunner.Create(AClient: TThoriumClient);
begin
  inherited Create;
  FClient := AClient;
end;

function TServerPlanRunner.Submit(const ARequest: TPlanCreateRequest): RawUtf8;
begin
  // PlanCreateTyped owns the JSON encoding (variant tree); we keep
  // this method a one-liner so swapping serialisation strategies in
  // the client doesn't ripple here.
  result := FClient.PlanCreateTyped(ARequest);
end;

function TServerPlanRunner.List(const AInstanceId: RawUtf8;
  const AStatuses: array of RawUtf8): TPlanRefArray;
begin
  result := FClient.PlanList(AInstanceId, AStatuses);
end;

function TServerPlanRunner.GetPlan(const APlanId, AInstanceId: RawUtf8): RawUtf8;
begin
  result := FClient.PlanGet(APlanId, AInstanceId);
end;

function TServerPlanRunner.Patch(const APlanId, APatchJson, AInstanceId,
  ANote: RawUtf8): RawUtf8;
begin
  result := FClient.PlanUpdate(APlanId, APatchJson, AInstanceId, ANote);
end;

function TServerPlanRunner.Cancel(const APlanId, AInstanceId, ANote: RawUtf8): RawUtf8;
begin
  result := FClient.PlanCancel(APlanId, AInstanceId, ANote);
end;

end.
