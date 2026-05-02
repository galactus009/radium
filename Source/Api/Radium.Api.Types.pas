unit Radium.Api.Types;

{ ----------------------------------------------------------------------------
  Pascal records mirroring thoriumd's REST request / response JSON.

  One record per endpoint result the GUI actually displays. Bodies that
  the GUI just round-trips opaquely (plan documents, raw AI configs)
  stay as RawUtf8 — modeling every plan field would duplicate a Go
  struct that's still in flux. The GUI is a viewer / forwarder for
  those, not an authoring surface yet.

  Naming: Pascal-style "Camel" identifiers. mORMot's RecordSaveJson
  serialises field names verbatim; on the wire we deliberately translate
  to thoriumd's snake_case via the per-field bind helpers in
  Radium.Api.Client. Keeping Pascal-natural names here means the GUI
  reads as Pascal, not as JSON-with-Pascal-syntax.
  ---------------------------------------------------------------------------- }

{$mode Delphi}{$H+}

interface

uses
  sysutils,
  mormot.core.base;

type
  // EThoriumApi — every Radium.Api.* failure raises this. Carries the
  // HTTP status code (or 0 on transport failure) plus the server's
  // `message` field if the response was a parsed error envelope.
  EThoriumApi = class(Exception)
  private
    FHttpCode: Integer;
  public
    constructor Create(const AMessage: RawUtf8; AHttpCode: Integer = 0);
    property HttpCode: Integer read FHttpCode;
  end;

  // TFeedHint — login's tri-state: auto (server picks first-attached-
  // wins) / explicit feed / explicit non-feed. Pascal enum → JSON
  // bool|absent in Radium.Api.Client.Login.
  TFeedHint = (fhAuto, fhTrue, fhFalse);

  // ── login ───────────────────────────────────────────────────────────

  // TLoginResult — the `data` block of /login's success envelope.
  TLoginResult = record
    Broker:       RawUtf8;
    InstanceId:   RawUtf8;
    CatalogRows:  Integer;
    IsFeedBroker: Boolean;
  end;

  // ── status ──────────────────────────────────────────────────────────

  // TStatusSession — one row in /status's sessions array.
  TStatusSession = record
    InstanceId:      RawUtf8;
    Broker:          RawUtf8;
    AttachedAt:      RawUtf8;
    CatalogRows:     Integer;
    CatalogLoadedAt: RawUtf8;
    AdapterAttached: Boolean;
    IsFeedBroker:    Boolean;
  end;
  TStatusSessionArray = array of TStatusSession;

  // TStatusResult — typed view of the daemon's /status snapshot.
  // Fields the GUI status panel renders directly. The full JSON is
  // also retrievable raw via TThoriumClient.StatusRaw for the "show
  // everything" toggle.
  TStatusResult = record
    Uptime:         RawUtf8;
    BusSubscribers: Integer;
    Goroutines:     Integer;
    MemAllocMb:     Double;
    TicksTotal:     Int64;
    TicksPerSec1s:  Double;
    TicksPerSec10s: Double;
    TicksPerSec60s: Double;
    Sessions:       TStatusSessionArray;
  end;

  // ── ping ────────────────────────────────────────────────────────────

  // TPingResult — round-trip latency captured by the client. The
  // server's response body is opaque; we measure wall-clock locally.
  TPingResult = record
    RoundTripMs: Double;
  end;

  // ── ai ──────────────────────────────────────────────────────────────

  // TAiConfigSnapshot — the `data` block of /admin/ai/config (GET).
  // Fields beyond these survive in the raw JSON the show panel can
  // render verbatim.
  TAiConfigSnapshot = record
    Provider: RawUtf8;
    Model:    RawUtf8;
    BaseUrl:  RawUtf8;
    HasKey:   Boolean;
    Raw:      RawUtf8;
  end;

  // ── risk ────────────────────────────────────────────────────────────

  // TRiskConfig — full snapshot from /admin/risk (GET) and the shape
  // the GUI risk panel displays in its form.
  TRiskConfig = record
    CutoffTime:           RawUtf8;
    MaxOpenOrders:        Integer;
    MaxDailyLoss:         Double;
    MaxSymbolLoss:        Double;
    HardMaxLots:          Integer;
    HardMaxNotional:      Double;
    MaxOptionLots:        Integer;
    MaxPremiumPerLot:     Double;
    MaxOptionNotional:    Double;
    IntradayLeverage:     Double;
    ExposureUtilization:  Double;
    MaxMarginUtilization: Double;
    MinAvailableMargin:   Double;
  end;

  // TRiskPatch — operator's intent on /admin/risk (POST). Each field
  // has a paired Has<Field> flag; only fields with Has=True land in
  // the JSON body, matching thoriumctl's flagWasSet semantics.
  // Distinguishes "operator wants to clear this" (Has=True, value=0)
  // from "operator didn't touch this" (Has=False).
  TRiskPatch = record
    CutoffTime:           RawUtf8;  HasCutoffTime:           Boolean;
    MaxOpenOrders:        Integer;  HasMaxOpenOrders:        Boolean;
    MaxDailyLoss:         Double;   HasMaxDailyLoss:         Boolean;
    MaxSymbolLoss:        Double;   HasMaxSymbolLoss:        Boolean;
    HardMaxLots:          Integer;  HasHardMaxLots:          Boolean;
    HardMaxNotional:      Double;   HasHardMaxNotional:      Boolean;
    MaxOptionLots:        Integer;  HasMaxOptionLots:        Boolean;
    MaxPremiumPerLot:     Double;   HasMaxPremiumPerLot:     Boolean;
    MaxOptionNotional:    Double;   HasMaxOptionNotional:    Boolean;
    IntradayLeverage:     Double;   HasIntradayLeverage:     Boolean;
    ExposureUtilization:  Double;   HasExposureUtilization:  Boolean;
    MaxMarginUtilization: Double;   HasMaxMarginUtilization: Boolean;
    MinAvailableMargin:   Double;   HasMinAvailableMargin:   Boolean;
  end;

  // ── plans ───────────────────────────────────────────────────────────

  // TPlanRef — plan_id + instance_id + status, the columns the GUI
  // plans-list grid needs. Full plan body stays as raw JSON for the
  // editor / viewer.
  TPlanRef = record
    PlanId:     RawUtf8;
    InstanceId: RawUtf8;
    Status:     RawUtf8;
    Note:       RawUtf8;
    UpdatedAt:  RawUtf8;
    Raw:        RawUtf8;
  end;
  TPlanRefArray = array of TPlanRef;

  // ── catalogue ───────────────────────────────────────────────────────

  // TInstrument — one row in /search's response (and any future
  // catalogue surface). Mirrors thoriumd/cid.Instrument verbatim.
  // Strike is 0 for non-options; Expiry blank for non-derivatives;
  // CID + CidExchange blank when conversion failed.
  TInstrument = record
    BrokerKey:      RawUtf8;
    Token:          RawUtf8;
    TradingSymbol:  RawUtf8;
    Name:           RawUtf8;
    Underlying:     RawUtf8;
    Exchange:       RawUtf8;
    InstrumentType: RawUtf8;
    Expiry:         RawUtf8;
    Strike:         Double;
    LotSize:        Integer;
    TickSize:       Double;
    Cid:            RawUtf8;
    CidExchange:    RawUtf8;
  end;
  TInstrumentArray = array of TInstrument;

  // ── feed promotion ──────────────────────────────────────────────────

  // TPromoteFeedResult — `data` block of /admin/promote_feed.
  // PreviousInstanceId == CurrentInstanceId means the call was a no-op
  // (target was already feed broker).
  TPromoteFeedResult = record
    PreviousInstanceId: RawUtf8;
    CurrentInstanceId:  RawUtf8;
  end;

  // ── trade plans (bot launch) ────────────────────────────────────────
  //
  // thoriumd's TradePlan API (POST /api/v1/plans/*) is the only way the
  // GUI launches a bot. Each plan declares a `capability` that routes to
  // a registered bot — today: options.scalper (OptionsBuddy) and
  // gamma.scalper (GammaBuddy). Adding a third bot is a wire change in
  // thoriumd, not Radium: any new capability shows up in this enum and
  // the form's capability picker.
  //
  // The records here are a typed front-end over the JSON wire shape
  // pinned in Docs/ThoriumdContract.md §2.10. The form binds to these,
  // the client serialises them to JSON. Free-form `Params` rides
  // alongside so operators can drop in any extra bot-specific knob the
  // form doesn't surface yet — flexibility-without-bloat.

  TPlanCapability = (pcOptionsScalper, pcGammaScalper);

  // TPlanInstrumentSpec — one row of TradePlan.Instruments. For both
  // options.scalper and gamma.scalper today, Type is always
  // 'options_underlying' and operators name the underlying (NIFTY,
  // BANKNIFTY...); the bot picks legs. Lots applies; Qty stays 0.
  TPlanInstrumentSpec = record
    InstrumentType: RawUtf8;   // 'options_underlying' | 'equity_intraday' | ...
    Symbol:         RawUtf8;
    Exchange:       RawUtf8;   // 'NSE_INDEX' for index underlyings
    Lots:           Integer;
    Qty:            Integer;   // unused for options today; kept for parity
    Product:        RawUtf8;   // 'MIS' | 'NRML' | 'CNC'
  end;
  TPlanInstrumentArray = array of TPlanInstrumentSpec;

  // TPlanParamKind — drives JSON encoding. The bot side coerces strings
  // permissively (asInt/asFloat/asDuration in config.go), so kPkString
  // is a safe default for the free-form advanced grid; the typed
  // surface above passes through narrower kinds.
  TPlanParamKind = (kPkString, kPkInt, kPkFloat, kPkBool, kPkDuration);

  TPlanParamPair = record
    Key:   RawUtf8;
    Kind:  TPlanParamKind;
    AsStr: RawUtf8;     // used for kPkString, kPkDuration ('30s', '14:45')
    AsInt: Int64;       // used for kPkInt
    AsFlt: Double;      // used for kPkFloat
    AsBool: Boolean;    // used for kPkBool
  end;
  TPlanParamArray = array of TPlanParamPair;

  // TPlanRisk — only the three operator-facing caps the form surfaces
  // today. Anything else (margin utilisation, hard caps) lives at the
  // instance level via /admin/risk and inherits automatically.
  // Has<Field>=False means "leave empty in the JSON body" so server
  // inheritance kicks in.
  TPlanRisk = record
    MaxDailyLoss:    Double;   HasMaxDailyLoss:    Boolean;
    MaxSymbolLoss:   Double;   HasMaxSymbolLoss:   Boolean;
    CutoffTime:      RawUtf8;  HasCutoffTime:      Boolean;
  end;

  // TPlanValidity — 'when is this plan allowed to trade'. MonitorUntil
  // is an absolute IST instant; the form composes it from today's date
  // + an HH:MM time picker. EntryWindow narrows when entries may fire.
  TPlanValiditySpec = record
    HasMonitorUntil:  Boolean;
    MonitorUntilUtc:  TDateTime;     // UTC; client renders as IST
    OnExpire:         RawUtf8;       // 'flatten' | 'drain' | 'detach' | ''
    EntryStartHHMM:   RawUtf8;       // '' = no start floor
    EntryEndHHMM:     RawUtf8;       // '' = no end ceiling
    ValidUntilCancel: Boolean;
  end;

  // TPlanCreateRequest — the entire form's output, ready to serialise.
  // Client.PlanCreateTyped owns the JSON encoding so the form stays
  // free of mORMot / variant code.
  TPlanCreateRequest = record
    InstanceId:  RawUtf8;
    Broker:      RawUtf8;
    Capability:  TPlanCapability;
    Instruments: TPlanInstrumentArray;
    Risk:        TPlanRisk;
    Validity:    TPlanValiditySpec;
    Params:      TPlanParamArray;
  end;

  // TPlanCapabilityInfo — display labels + wire ids in one place. The
  // form's capability radio reads these; nothing else hardcodes the
  // 'options.scalper' string.
  TPlanCapabilityInfo = record
    Capability:  TPlanCapability;
    WireId:      RawUtf8;     // 'options.scalper' | 'gamma.scalper'
    Title:       string;      // 'Options Scalper'
    OneLine:     string;      // human-readable description
  end;
  TPlanCapabilityInfoArray = array of TPlanCapabilityInfo;

// PlanCapabilityWireId — the registry key thoriumd routes on. Same
// strings as in thoriumd/bot/<name>/<name>.go const Capability. Adding
// a capability means adding the enum, the wire id here, and the
// PlanCapabilityCatalog entry — three lines in one diff.
function PlanCapabilityWireId(ACap: TPlanCapability): RawUtf8;

// PlanCapabilityCatalog — every capability the form lets the operator
// pick. Source of truth for the picker UI. Order = display order.
function PlanCapabilityCatalog: TPlanCapabilityInfoArray;

implementation

constructor EThoriumApi.Create(const AMessage: RawUtf8; AHttpCode: Integer);
begin
  inherited Create(string(AMessage));
  FHttpCode := AHttpCode;
end;

function PlanCapabilityWireId(ACap: TPlanCapability): RawUtf8;
begin
  case ACap of
    pcOptionsScalper: result := 'options.scalper';
    pcGammaScalper:   result := 'gamma.scalper';
  else
    result := '';
  end;
end;

function PlanCapabilityCatalog: TPlanCapabilityInfoArray;
begin
  // Order = wizard's display order. Options scalper first because it's
  // the everyday workhorse; gamma is expiry-day only.
  SetLength(result, 2);

  result[0].Capability := pcOptionsScalper;
  result[0].WireId     := 'options.scalper';
  result[0].Title      := 'Options Scalper';
  result[0].OneLine    :=
    'AI-driven multi-underlying intraday options. Picks structures, sizes legs, ' +
    'manages SL/TP/trail. Best for normal trading days.';

  result[1].Capability := pcGammaScalper;
  result[1].WireId     := 'gamma.scalper';
  result[1].Title      := 'Gamma Scalper';
  result[1].OneLine    :=
    'Pure-rules expiry-day VIX-gated short straddle (or low-VIX directional). ' +
    'No LLM. Best for expiry day premium decay.';
end;

end.
