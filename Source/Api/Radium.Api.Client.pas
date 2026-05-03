unit Radium.Api.Client;

(* ----------------------------------------------------------------------------
  Typed Pascal client of thoriumd's REST surface. Mirrors the wire
  contract pinned in Docs/ThoriumdContract.md, one method per endpoint
  Radium consumes today (login/logout/refresh, ping, status, AI
  configure/show/ask, risk get/set, plan create/list/get/update/cancel).

  Implementation notes
  ────────────────────
  - HTTP via mORMot 2's TSimpleHttpClient — proxy-aware (system proxy
    or explicit override), reuses the underlying socket between calls,
    speaks both HTTP and HTTPS without a separate code path.
  - JSON in/out via _ObjFast / _Json / _Safe (mormot.core.variants).
    Request bodies are built variant-first so optional fields can be
    added conditionally without string-stitching.
  - Pascal records are Pascal-natural ("CamelCase") but the wire is
    snake_case. Per-field getters in this unit translate. Mirrors what
    Docs/ThoriumdContract.md and the Types.pas header promise.
  - /ping is the only endpoint that does NOT use the standard
    {status:success,data:…} envelope. It returns
    {status:"ok",message:"pong"}. We branch on path.
  - Logical errors arrive at HTTP 200 with {status:"error",message:…}.
    A subset (400 / 404 / 500 / 503) DO surface a non-2xx code. The
    envelope check looks at both — never trust HTTP code alone.
  - Thread isolation: TThoriumClient is NOT thread-safe. The GUI uses
    one client per worker; never share between threads. mORMot's
    socket reuse goal is per-instance, not cross-instance.

  Source of truth: Docs/ThoriumdContract.md. When that doc changes,
  this file changes in the same commit.
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  mormot.core.base,
  mormot.core.variants,
  Radium.Api.Types;

type
  // TThoriumClient — one instance per logical session against a single
  // thoriumd. Caller owns it; Free when done.
  //
  // Construction is cheap (no socket dial); the first Request() does
  // the connect. BaseUrl uses bare `/<path>` mounts (not `/api/v1/`)
  // to match thoriumctl byte-for-byte.
  TThoriumClient = class
  private
    FBaseUrl: RawUtf8;       // 'http://localhost:8080' — no trailing slash
    FApiKey:  RawUtf8;       // operator's THORIUM_APIKEY equivalent
    FProxy:   RawUtf8;       // '' = system, 'none' = bypass, else explicit
    FTimeoutMs: Integer;     // socket connect/recv timeout per call

    function Url(const APath: RawUtf8): RawUtf8;
    function UrlWithApiKey(const APath: RawUtf8): RawUtf8;

    // DataArrayPost — common shape for the three book endpoints
    // (tradebook / positionbook / orderbook). POST {apikey,
    // instance_id?}, pull `data` from the envelope, return as raw
    // JSON for the analyzer to walk.
    function DataArrayPost(const APath, AInstanceId: RawUtf8): RawUtf8;

    // Issue an HTTP request, return raw response body and HTTP status.
    // Raises EThoriumApi only on transport failure (DNS, connection
    // refused, TLS). Logical errors (HTTP non-2xx, status:error in
    // envelope) flow through to the caller's envelope check.
    function HttpDo(const AMethod, AUrl: RawUtf8; const ABody: RawByteString;
      const AContentType: RawUtf8; out AHttpStatus: Integer): RawUtf8;

    // Pull `data` from a standard {status,data} envelope, raising
    // EThoriumApi(message, httpcode) on any error shape. The variant
    // result is a TDocVariant (PDocVariantData accessible via _Safe).
    function EnvelopeData(const ABody: RawUtf8; AHttpStatus: Integer): variant;

  public
    constructor Create(const ABaseUrl, AApiKey: RawUtf8);

    // Endpoint methods — see Docs/ThoriumdContract.md §2 for the wire
    // shapes each one drives. Every method either returns its typed
    // record (or RawUtf8 for opaque bodies) or raises EThoriumApi.

    function Login(const ABroker, AToken: RawUtf8;
      const AInstanceId: RawUtf8 = '';
      AFeed: TFeedHint = fhAuto): TLoginResult;
    function Logout(const AInstanceId: RawUtf8 = ''): RawUtf8;
    function Refresh(const ABroker, AToken: RawUtf8;
      const AInstanceId: RawUtf8 = '';
      AFeed: TFeedHint = fhAuto): TLoginResult;

    function Ping: TPingResult;

    function Status: TStatusResult;
    function StatusRaw: RawUtf8;

    procedure AiConfigure(const AProvider, AApiKey: RawUtf8;
      const AModel: RawUtf8 = ''; const ABaseUrl: RawUtf8 = '');
    function AiAsk(const APrompt: RawUtf8;
      const ASystem: RawUtf8 = '';
      const AContext: RawUtf8 = '';
      const AModel: RawUtf8 = ''): RawUtf8;
    function AiShow: TAiConfigSnapshot;

    function RiskGet: TRiskConfig;
    function RiskSet(const APatch: TRiskPatch): TRiskConfig;

    function PlanCreate(const APlanJson: RawUtf8;
      const AInstanceId: RawUtf8 = ''): RawUtf8;
    // PlanCreateTyped — convenience over PlanCreate that builds the
    // wire JSON from a TPlanCreateRequest. Returns the raw success
    // body (which contains the assigned plan_id).
    function PlanCreateTyped(const ARequest: TPlanCreateRequest): RawUtf8;
    // PlanHalt / PlanResume / PlanCancelTyped — thin wrappers over
    // PlanUpdate / PlanCancel that build the right patch JSON. Halt
    // patches status='halted' (no new entries; existing positions
    // managed). Resume patches status='running'. Cancel routes to
    // PlanCancel (a separate endpoint with terminal semantics).
    function PlanHalt(const APlanId, AInstanceId: RawUtf8;
      const ANote: RawUtf8 = ''): RawUtf8;
    function PlanResume(const APlanId, AInstanceId: RawUtf8;
      const ANote: RawUtf8 = ''): RawUtf8;
    function PlanList(const AInstanceId: RawUtf8 = '';
      const AStatusFilter: array of RawUtf8): TPlanRefArray;
    function PlanGet(const APlanId: RawUtf8;
      const AInstanceId: RawUtf8 = ''): RawUtf8;
    function PlanUpdate(const APlanId, APatchJson: RawUtf8;
      const AInstanceId: RawUtf8 = '';
      const ANote: RawUtf8 = ''): RawUtf8;
    function PlanCancel(const APlanId: RawUtf8;
      const AInstanceId: RawUtf8 = '';
      const ANote: RawUtf8 = ''): RawUtf8;

    // ── books / catalogue (clerk's data sources) ─────────────────────
    //
    // The Pascal clerk port (Radium.Clerk.Analyzer) consumes these
    // four endpoints to walk fills into round-trips. We return the
    // envelope's `data` array verbatim — the analyzer parses field
    // shapes itself because thoriumd surfaces the raw broker payload
    // (which varies across adapters).

    // TradebookGet — POST /api/v1/tradebook with optional instance_id.
    // Returns the JSON array of fills as raw bytes.
    function TradebookGet(const AInstanceId: RawUtf8 = ''): RawUtf8;

    // PositionbookGet — POST /api/v1/positionbook. Returns the broker's
    // current positions array.
    function PositionbookGet(const AInstanceId: RawUtf8 = ''): RawUtf8;

    // OrderbookGet — POST /api/v1/orderbook. Best-effort — used for
    // tag → source classification. Returns '' on transport-success
    // but daemon-error so the caller can downgrade to "all manual"
    // gracefully.
    function OrderbookGetSafe(const AInstanceId: RawUtf8 = ''): RawUtf8;

    // SymbolLookup — POST /api/v1/symbol. Resolves a (symbol,
    // exchange) into the canonical instrument (instrument_type +
    // lot_size). Returns '' on lookup miss so the caller can fall
    // back to suffix-based heuristics.
    function SymbolLookup(const ASymbol, AExchange: RawUtf8;
      const AInstanceId: RawUtf8 = ''): RawUtf8;

    // SymbolSearch — POST /api/v1/search. Free-text query over the
    // attached broker's catalogue, returns up to ALimit instrument
    // rows. AExchange is optional — pass '' to search every segment,
    // or 'NSE' / 'NFO' / etc to filter. Used by the order-pad's
    // autocomplete.
    function SymbolSearch(const AQuery, AExchange: RawUtf8;
      ALimit: Integer = 25; const AInstanceId: RawUtf8 = ''): TInstrumentArray;

    // PlaceOrder — POST /api/v1/placeorder. Returns the broker's
    // assigned orderid on success. Wire shape mirrors thoriumctl's
    // placeorder command: action, pricetype, product, quantity,
    // optional price + trigger.
    function PlaceOrder(const ACid, ACidExchange, AAction, APriceType,
                        AProduct: RawUtf8;
                        AQuantity: Integer; APrice, ATrigger: Double;
                        const AInstanceId: RawUtf8 = ''): RawUtf8;

    // ClosePosition — POST /api/v1/closeposition. Server figures out
    // direction + qty from the open positionbook entry and submits
    // the offsetting order. Returns broker orderid on success.
    function ClosePosition(const ACid, ACidExchange: RawUtf8;
      const AInstanceId: RawUtf8 = ''): RawUtf8;

    // FundsGet — GET /api/v1/funds. Returns the funds JSON envelope
    // raw (caller picks fields it needs — total / utilised /
    // available / payin / payout, names vary per broker).
    function FundsGet(const AInstanceId: RawUtf8 = ''): RawUtf8;

    // MarginGet — GET /api/v1/margin. Same shape rationale as funds.
    function MarginGet(const AInstanceId: RawUtf8 = ''): RawUtf8;

    property BaseUrl: RawUtf8 read FBaseUrl write FBaseUrl;
    property ApiKey:  RawUtf8 read FApiKey  write FApiKey;

    // Proxy URI: '' (default) = follow system proxy env; 'none' =
    // bypass entirely; anything else = explicit
    // 'http://user:pass@host:port'. Pass-through to mORMot.
    property Proxy: RawUtf8 read FProxy write FProxy;

    // Connect + per-request socket timeout, in milliseconds. thoriumctl
    // uses 120s for POST and 15s for GET; we use the larger of the two
    // here because Login can spend most of that on broker auth +
    // catalog load. Override before issuing a fast call if needed.
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
  end;

implementation

uses
  sysutils,
  variants,
  mormot.core.text,
  mormot.core.json,
  mormot.net.client;

{ ── helpers ──────────────────────────────────────────────────────────── }

// FeedHintToVariant — encodes the tri-state per Login.feed in
// Docs/ThoriumdContract.md §2.1. fhAuto returns Unassigned so the key
// is dropped from the body entirely.
function FeedHintToVariant(AFeed: TFeedHint): variant;
begin
  case AFeed of
    fhTrue:  result := True;
    fhFalse: result := False;
  else
    VarClear(result);
  end;
end;

// ParseLoginData / ParseStatusData / ParseAiData / ParseRiskData
// translate the wire's snake_case into Pascal records. One read per
// field — verbose, but the cost is paid once at the boundary and
// the rest of the GUI uses Pascal-natural names.

function ParseLoginData(const AData: variant): TLoginResult;
var
  d: PDocVariantData;
begin
  d := _Safe(AData);
  result.Broker       := d^.U['broker'];
  result.InstanceId   := d^.U['instance_id'];
  result.CatalogRows  := d^.I['catalog_rows'];
  result.IsFeedBroker := d^.B['is_feed_broker'];
end;

function ParseStatusData(const AData: variant): TStatusResult;
var
  d, sess, one: PDocVariantData;
  idx: Integer;
begin
  d := _Safe(AData);
  result.Uptime         := d^.U['uptime'];
  result.BusSubscribers := d^.I['bus_subscribers'];
  result.Goroutines     := d^.I['goroutines'];
  result.MemAllocMb     := d^.D['mem_alloc_mb'];
  result.TicksTotal     := d^.I['ticks_total'];
  result.TicksPerSec1s  := d^.D['ticks_per_sec_1s'];
  result.TicksPerSec10s := d^.D['ticks_per_sec_10s'];
  result.TicksPerSec60s := d^.D['ticks_per_sec_60s'];

  result.Sessions := nil;
  if d^.GetAsArray('sessions', sess) then
  begin
    SetLength(result.Sessions, sess^.Count);
    for idx := 0 to sess^.Count - 1 do
    begin
      one := _Safe(sess^.Values[idx]);
      result.Sessions[idx].InstanceId      := one^.U['instance_id'];
      result.Sessions[idx].Broker          := one^.U['broker'];
      result.Sessions[idx].AttachedAt      := one^.U['attached_at'];
      result.Sessions[idx].CatalogRows     := one^.I['catalog_rows'];
      result.Sessions[idx].CatalogLoadedAt := one^.U['catalog_loaded_at'];
      result.Sessions[idx].AdapterAttached := one^.B['adapter_attached'];
      result.Sessions[idx].IsFeedBroker    := one^.B['is_feed_broker'];
    end;
  end;
end;

function ParseAiData(const AData: variant; const ARaw: RawUtf8): TAiConfigSnapshot;
var
  d, u, bucket: PDocVariantData;
  i: PtrInt;
begin
  d := _Safe(AData);
  result.Provider := d^.U['provider'];
  result.Model    := d^.U['model'];
  result.BaseUrl  := d^.U['base_url'];
  result.HasKey   := d^.B['has_key'];
  result.Raw      := ARaw;

  // usage is a JSON object keyed by "provider/model" → {calls,
  // input_tokens, output_tokens}. Walk it into a flat array; missing
  // (older daemons) is fine — Usage stays nil.
  result.Usage := nil;
  u := _Safe(d^.Value['usage']);
  if u^.Kind = dvObject then
  begin
    SetLength(result.Usage, u^.Count);
    for i := 0 to u^.Count - 1 do
    begin
      bucket := _Safe(u^.Values[i]);
      result.Usage[i].Key          := u^.Names[i];
      result.Usage[i].Calls        := bucket^.I['calls'];
      result.Usage[i].InputTokens  := bucket^.I['input_tokens'];
      result.Usage[i].OutputTokens := bucket^.I['output_tokens'];
    end;
  end;
end;

function ParseRiskData(const AData: variant): TRiskConfig;
var
  d: PDocVariantData;
begin
  d := _Safe(AData);
  // Every field is omitempty on the Go side — missing keys mean
  // operator-never-set; surface as Pascal zero/empty. The GUI uses
  // the raw JSON to distinguish "absent" from "0" when that matters.
  result.CutoffTime           := d^.U['cutoff_time'];
  result.MaxOpenOrders        := d^.I['max_open_orders'];
  result.MaxDailyLoss         := d^.D['max_daily_loss'];
  result.MaxSymbolLoss        := d^.D['max_symbol_loss'];
  result.HardMaxLots          := d^.I['hard_max_lots'];
  result.HardMaxNotional      := d^.D['hard_max_notional'];
  result.MaxOptionLots        := d^.I['max_option_lots'];
  result.MaxPremiumPerLot     := d^.D['max_premium_per_lot'];
  result.MaxOptionNotional    := d^.D['max_option_notional'];
  result.IntradayLeverage     := d^.D['intraday_leverage'];
  result.ExposureUtilization  := d^.D['exposure_utilization'];
  result.MaxMarginUtilization := d^.D['max_margin_utilization'];
  result.MinAvailableMargin   := d^.D['min_available_margin'];
end;

// SerializePlanRef — pulls just the columns the plans grid renders
// (id, instance, status, note, updated_at) and stashes the full plan
// JSON into Raw for the editor / detail view.
function SerializePlanRef(const APlanVariant: variant): TPlanRef;
var
  d: PDocVariantData;
begin
  d := _Safe(APlanVariant);
  result.PlanId     := d^.U['id'];
  result.InstanceId := d^.U['instance_id'];
  result.Status     := d^.U['status'];
  result.Note       := d^.U['note'];
  result.UpdatedAt  := d^.U['updated_at'];
  result.Raw        := VariantSaveJson(APlanVariant);
end;

{ ── TThoriumClient ─────────────────────────────────────────────────── }

constructor TThoriumClient.Create(const ABaseUrl, AApiKey: RawUtf8);
begin
  inherited Create;
  FBaseUrl := ABaseUrl;
  // Strip any trailing slash so Url() can append paths without
  // doubling-up. Only trim once — '////' would be malformed input.
  if (FBaseUrl <> '') and (FBaseUrl[Length(FBaseUrl)] = '/') then
    SetLength(FBaseUrl, Length(FBaseUrl) - 1);
  FApiKey := AApiKey;
  FProxy := '';
  FTimeoutMs := 120 * 1000;
end;

function TThoriumClient.Url(const APath: RawUtf8): RawUtf8;
begin
  result := FBaseUrl + APath;
end;

function TThoriumClient.UrlWithApiKey(const APath: RawUtf8): RawUtf8;
begin
  // GET endpoints take apikey via query string. Operator-issued keys
  // are alphanumeric in practice; we don't URL-encode here. If a key
  // ever contains reserved chars, swap to UrlEncode from
  // mormot.net.sock — but keep it simple while it's not needed.
  result := FBaseUrl + APath;
  if Pos(RawUtf8('?'), APath) > 0 then
    result := result + '&apikey=' + FApiKey
  else
    result := result + '?apikey=' + FApiKey;
end;

function TThoriumClient.HttpDo(const AMethod, AUrl: RawUtf8;
  const ABody: RawByteString; const AContentType: RawUtf8;
  out AHttpStatus: Integer): RawUtf8;
var
  c: TSimpleHttpClient;
begin
  c := TSimpleHttpClient.Create;
  try
    c.Options^.Proxy := FProxy;
    c.Options^.CreateTimeoutMS := FTimeoutMs;
    try
      AHttpStatus := c.Request(AUrl, AMethod, '', ABody, AContentType);
    except
      on E: Exception do
        raise EThoriumApi.Create(
          RawUtf8(E.ClassName) + ': ' + RawUtf8(E.Message), 0);
    end;
    result := c.Body;
  finally
    c.Free;
  end;
end;

function TThoriumClient.EnvelopeData(const ABody: RawUtf8;
  AHttpStatus: Integer): variant;
var
  parsed: variant;
  root: PDocVariantData;
  status, msg: RawUtf8;
  ndx: Integer;
begin
  if ABody = '' then
    raise EThoriumApi.Create(
      RawUtf8('empty response body (HTTP ') + ToUtf8(AHttpStatus) + ')',
      AHttpStatus);
  parsed := _Json(ABody);
  if VarIsEmptyOrNull(parsed) then
    raise EThoriumApi.Create('non-JSON response: ' + ABody, AHttpStatus);
  root := _Safe(parsed);
  status := root^.U['status'];
  if status <> 'success' then
  begin
    msg := root^.U['message'];
    if msg = '' then
      msg := 'thoriumd error (HTTP ' + ToUtf8(AHttpStatus) + ')';
    raise EThoriumApi.Create(msg, AHttpStatus);
  end;
  // Standard success envelope. data may be an object, array, or null
  // depending on endpoint; callers read what they expect.
  ndx := root^.GetValueIndex('data');
  if ndx >= 0 then
    result := root^.Values[ndx]
  else
    VarClear(result);
end;

{ ── login / logout / refresh ──────────────────────────────────────── }

function TThoriumClient.Login(const ABroker, AToken: RawUtf8;
  const AInstanceId: RawUtf8; AFeed: TFeedHint): TLoginResult;
var
  body: variant;
  bodyJson, response: RawUtf8;
  http: Integer;
begin
  body := _ObjFast([
    'apikey', FApiKey,
    'broker', ABroker,
    'token',  AToken
  ]);
  if AInstanceId <> '' then
    _Safe(body)^.AddValue('instance_id', AInstanceId);
  case AFeed of
    fhTrue:  _Safe(body)^.AddValue('feed', True);
    fhFalse: _Safe(body)^.AddValue('feed', False);
  end;
  bodyJson := VariantSaveJson(body);
  response := HttpDo('POST', Url('/login'), bodyJson, 'application/json', http);
  result := ParseLoginData(EnvelopeData(response, http));
end;

function TThoriumClient.Logout(const AInstanceId: RawUtf8): RawUtf8;
var
  body: variant;
  bodyJson, response: RawUtf8;
  http: Integer;
  data: variant;
begin
  body := _ObjFast(['apikey', FApiKey]);
  if AInstanceId <> '' then
    _Safe(body)^.AddValue('instance_id', AInstanceId);
  bodyJson := VariantSaveJson(body);
  response := HttpDo('POST', Url('/logout'), bodyJson, 'application/json', http);
  data := EnvelopeData(response, http);
  // /logout's data is a string today (informational). Return raw JSON
  // either way so the caller can show whatever shape arrives.
  result := VariantSaveJson(data);
end;

function TThoriumClient.Refresh(const ABroker, AToken: RawUtf8;
  const AInstanceId: RawUtf8; AFeed: TFeedHint): TLoginResult;
begin
  // Mirrors thoriumctl's `refresh` — logout, brief settle, login.
  // Errors on logout aren't fatal: an explicit refresh after a
  // crashed session may legitimately have no session to drop.
  try
    Logout(AInstanceId);
  except
    on EThoriumApi do
      ; // swallow; login result is what matters
  end;
  Sleep(200);
  result := Login(ABroker, AToken, AInstanceId, AFeed);
end;

{ ── ping ──────────────────────────────────────────────────────────── }

function TThoriumClient.Ping: TPingResult;
var
  bodyJson, response: RawUtf8;
  http: Integer;
  parsed: variant;
  start: Int64;
begin
  // Special envelope: {status:"ok",message:"pong"}. We don't go
  // through EnvelopeData because that expects status:"success".
  // Caller sees round-trip ms; the body is a sentinel.
  bodyJson := VariantSaveJson(_ObjFast(['apikey', FApiKey]));
  start := GetTickCount64;
  response := HttpDo('POST', Url('/ping'), bodyJson, 'application/json', http);
  result.RoundTripMs := GetTickCount64 - start;
  if (http < 200) or (http >= 300) then
    raise EThoriumApi.Create('ping failed (HTTP ' + ToUtf8(http) + ')', http);
  parsed := _Json(response);
  if _Safe(parsed)^.U['status'] <> 'ok' then
    raise EThoriumApi.Create(
      'ping: unexpected envelope: ' + response, http);
end;

{ ── status ───────────────────────────────────────────────────────── }

function TThoriumClient.Status: TStatusResult;
var
  http: Integer;
  body: RawUtf8;
begin
  body := HttpDo('GET', UrlWithApiKey('/status'), '', '', http);
  result := ParseStatusData(EnvelopeData(body, http));
end;

function TThoriumClient.StatusRaw: RawUtf8;
var
  http: Integer;
begin
  // Returns the daemon's full data block as JSON for the GUI's "show
  // everything" toggle. Still goes through EnvelopeData so the caller
  // never sees an error envelope masquerading as data.
  result := VariantSaveJson(EnvelopeData(
    HttpDo('GET', UrlWithApiKey('/status'), '', '', http), http));
end;

{ ── ai ───────────────────────────────────────────────────────────── }

procedure TThoriumClient.AiConfigure(const AProvider, AApiKey: RawUtf8;
  const AModel, ABaseUrl: RawUtf8);
var
  body: variant;
  bodyJson, response: RawUtf8;
  http: Integer;
begin
  // Mirrors thoriumctl's payload: api_key + model + base_url are
  // always-present; "" tells the daemon to use provider defaults.
  body := _ObjFast([
    'apikey',   FApiKey,
    'provider', AProvider,
    'api_key',  AApiKey,
    'model',    AModel,
    'base_url', ABaseUrl
  ]);
  bodyJson := VariantSaveJson(body);
  response := HttpDo('POST', Url('/admin/ai/configure'),
                     bodyJson, 'application/json', http);
  EnvelopeData(response, http); // raises on error; success body is just {message}
end;

function TThoriumClient.AiAsk(const APrompt, ASystem, AContext, AModel: RawUtf8): RawUtf8;
var
  body, data: variant;
  bodyJson, response: RawUtf8;
  http: Integer;
begin
  body := _ObjFast([
    'apikey',  FApiKey,
    'prompt',  APrompt,
    'system',  ASystem,
    'context', AContext,
    'model',   AModel
  ]);
  bodyJson := VariantSaveJson(body);
  response := HttpDo('POST', Url('/ai/ask'), bodyJson, 'application/json', http);
  data := EnvelopeData(response, http);
  result := _Safe(data)^.U['reply'];
end;

function TThoriumClient.AiShow: TAiConfigSnapshot;
var
  http: Integer;
  body: RawUtf8;
  data: variant;
begin
  body := HttpDo('GET', UrlWithApiKey('/admin/ai/config'), '', '', http);
  data := EnvelopeData(body, http);
  result := ParseAiData(data, VariantSaveJson(data));
end;

{ ── risk ─────────────────────────────────────────────────────────── }

function TThoriumClient.RiskGet: TRiskConfig;
var
  http: Integer;
  body: RawUtf8;
begin
  body := HttpDo('GET', UrlWithApiKey('/admin/risk'), '', '', http);
  result := ParseRiskData(EnvelopeData(body, http));
end;

function TThoriumClient.RiskSet(const APatch: TRiskPatch): TRiskConfig;
var
  body: variant;
  bodyJson, response: RawUtf8;
  http: Integer;

  // Per-field add: mirrors the Has<Field>/value pair in TRiskPatch
  // and matches thoriumctl's flagWasSet semantics — only fields the
  // operator explicitly touched land on the wire. Sending a field
  // with its zero value (e.g. max_daily_loss=0) clears the cap.
  procedure AddStr(const AKey, AValue: RawUtf8; AHas: Boolean);
  begin
    if AHas then
      _Safe(body)^.AddValue(AKey, AValue);
  end;
  procedure AddInt(const AKey: RawUtf8; AValue: Integer; AHas: Boolean);
  begin
    if AHas then
      _Safe(body)^.AddValue(AKey, AValue);
  end;
  procedure AddFloat(const AKey: RawUtf8; AValue: Double; AHas: Boolean);
  begin
    if AHas then
      _Safe(body)^.AddValue(AKey, AValue);
  end;

begin
  body := _ObjFast(['apikey', FApiKey]);
  AddStr  ('cutoff_time',            APatch.CutoffTime,           APatch.HasCutoffTime);
  AddInt  ('max_open_orders',        APatch.MaxOpenOrders,        APatch.HasMaxOpenOrders);
  AddFloat('max_daily_loss',         APatch.MaxDailyLoss,         APatch.HasMaxDailyLoss);
  AddFloat('max_symbol_loss',        APatch.MaxSymbolLoss,        APatch.HasMaxSymbolLoss);
  AddInt  ('hard_max_lots',          APatch.HardMaxLots,          APatch.HasHardMaxLots);
  AddFloat('hard_max_notional',      APatch.HardMaxNotional,      APatch.HasHardMaxNotional);
  AddInt  ('max_option_lots',        APatch.MaxOptionLots,        APatch.HasMaxOptionLots);
  AddFloat('max_premium_per_lot',    APatch.MaxPremiumPerLot,     APatch.HasMaxPremiumPerLot);
  AddFloat('max_option_notional',    APatch.MaxOptionNotional,    APatch.HasMaxOptionNotional);
  AddFloat('intraday_leverage',      APatch.IntradayLeverage,     APatch.HasIntradayLeverage);
  AddFloat('exposure_utilization',   APatch.ExposureUtilization,  APatch.HasExposureUtilization);
  AddFloat('max_margin_utilization', APatch.MaxMarginUtilization, APatch.HasMaxMarginUtilization);
  AddFloat('min_available_margin',   APatch.MinAvailableMargin,   APatch.HasMinAvailableMargin);

  // Daemon rejects empty patches (only apikey present). Caller is
  // expected to set at least one Has flag — surface the rejection
  // verbatim if they didn't.
  bodyJson := VariantSaveJson(body);
  response := HttpDo('POST', Url('/admin/risk'), bodyJson, 'application/json', http);
  result := ParseRiskData(EnvelopeData(response, http));
end;

{ ── plans ────────────────────────────────────────────────────────── }

// PlanCreate / PlanUpdate take the plan body (or patch) as raw JSON
// straight from the GUI editor. Modeling every TradePlan field would
// duplicate a Go struct still in flux (capability/instruments/risk/
// validity/params); see the Types.pas header for why those stay raw.
//
// We parse the operator's JSON, merge apikey + instance_id (+ optional
// note for updates), serialize, send.

function MergePlanBody(const ARawJson, AApiKey, AInstanceId, ANote: RawUtf8): RawUtf8;
var
  body: variant;
begin
  if ARawJson = '' then
    body := _ObjFast([])
  else
  begin
    body := _Json(ARawJson);
    if VarIsEmptyOrNull(body) or
       (_Safe(body)^.Kind <> dvObject) then
      raise EThoriumApi.Create(
        'plan body must be a JSON object', 0);
  end;
  _Safe(body)^.AddOrUpdateValue('apikey', AApiKey);
  if AInstanceId <> '' then
    _Safe(body)^.AddOrUpdateValue('instance_id', AInstanceId);
  if ANote <> '' then
    _Safe(body)^.AddOrUpdateValue('note', ANote);
  result := VariantSaveJson(body);
end;

function TThoriumClient.PlanCreate(const APlanJson: RawUtf8;
  const AInstanceId: RawUtf8): RawUtf8;
var
  bodyJson, response: RawUtf8;
  http: Integer;
begin
  bodyJson := MergePlanBody(APlanJson, FApiKey, AInstanceId, '');
  response := HttpDo('POST', Url('/api/v1/plans/create'),
                     bodyJson, 'application/json', http);
  result := VariantSaveJson(EnvelopeData(response, http));
end;

function TThoriumClient.PlanList(const AInstanceId: RawUtf8;
  const AStatusFilter: array of RawUtf8): TPlanRefArray;
var
  body, data: variant;
  bodyJson, response: RawUtf8;
  http, i: Integer;
  arr: variant;
  arrData, plansArr: PDocVariantData;
begin
  body := _ObjFast(['apikey', FApiKey]);
  if AInstanceId <> '' then
    _Safe(body)^.AddValue('instance_id', AInstanceId);
  if Length(AStatusFilter) > 0 then
  begin
    arr := _Arr([]);
    arrData := _Safe(arr);
    for i := 0 to High(AStatusFilter) do
      arrData^.AddItem(AStatusFilter[i]);
    _Safe(body)^.AddValue('status', arr);
  end;
  bodyJson := VariantSaveJson(body);
  response := HttpDo('POST', Url('/api/v1/plans/list'),
                     bodyJson, 'application/json', http);
  data := EnvelopeData(response, http);

  result := nil;
  if _Safe(data)^.GetAsArray('plans', plansArr) then
  begin
    SetLength(result, plansArr^.Count);
    for i := 0 to plansArr^.Count - 1 do
      result[i] := SerializePlanRef(plansArr^.Values[i]);
  end;
end;

function TThoriumClient.PlanGet(const APlanId, AInstanceId: RawUtf8): RawUtf8;
var
  body: variant;
  bodyJson, response: RawUtf8;
  http: Integer;
begin
  body := _ObjFast([
    'apikey',  FApiKey,
    'plan_id', APlanId
  ]);
  if AInstanceId <> '' then
    _Safe(body)^.AddValue('instance_id', AInstanceId);
  bodyJson := VariantSaveJson(body);
  response := HttpDo('POST', Url('/api/v1/plans/get'),
                     bodyJson, 'application/json', http);
  result := VariantSaveJson(EnvelopeData(response, http));
end;

function TThoriumClient.PlanUpdate(const APlanId, APatchJson,
  AInstanceId, ANote: RawUtf8): RawUtf8;
var
  bodyJson, response: RawUtf8;
  http: Integer;
  body: variant;
begin
  // updatePlanReq carries plan_id at the top level alongside the
  // patch fields. MergePlanBody handles apikey/instance_id/note;
  // we add plan_id explicitly afterward.
  bodyJson := MergePlanBody(APatchJson, FApiKey, AInstanceId, ANote);
  body := _Json(bodyJson);
  _Safe(body)^.AddOrUpdateValue('plan_id', APlanId);
  bodyJson := VariantSaveJson(body);
  response := HttpDo('POST', Url('/api/v1/plans/update'),
                     bodyJson, 'application/json', http);
  result := VariantSaveJson(EnvelopeData(response, http));
end;

function TThoriumClient.PlanCreateTyped(
  const ARequest: TPlanCreateRequest): RawUtf8;
var
  body, instArr, oneInst, risk, validity, params, entryWin: variant;
  arrPtr: PDocVariantData;
  i: Integer;
  ymd: string;
  monitorIso: RawUtf8;
begin
  // Build the full TradePlan JSON body up front (including apikey +
  // instance_id) and hand it to PlanCreate as a pre-merged blob. Going
  // through MergePlanBody would re-wrap our object inside another
  // object — which works, but builds an intermediate variant tree we
  // don't need.
  body := _ObjFast([
    'apikey',     FApiKey,
    'capability', PlanCapabilityWireId(ARequest.Capability),
    'broker',     ARequest.Broker
  ]);
  if ARequest.InstanceId <> '' then
    _Safe(body)^.AddValue('instance_id', ARequest.InstanceId);

  // instruments — always at least one row, wizard guarantees this.
  instArr := _Arr([]);
  arrPtr := _Safe(instArr);
  for i := 0 to High(ARequest.Instruments) do
  begin
    oneInst := _ObjFast([
      'type',     ARequest.Instruments[i].InstrumentType,
      'symbol',   ARequest.Instruments[i].Symbol,
      'exchange', ARequest.Instruments[i].Exchange
    ]);
    if ARequest.Instruments[i].Lots > 0 then
      _Safe(oneInst)^.AddValue('lots', ARequest.Instruments[i].Lots);
    if ARequest.Instruments[i].Qty > 0 then
      _Safe(oneInst)^.AddValue('qty', ARequest.Instruments[i].Qty);
    if ARequest.Instruments[i].Product <> '' then
      _Safe(oneInst)^.AddValue('product', ARequest.Instruments[i].Product);
    arrPtr^.AddItem(oneInst);
  end;
  _Safe(body)^.AddValue('instruments', instArr);

  // risk — only fields the operator explicitly set; pointer-style
  // omitempty on the Go side means absent → inherit from instance.
  risk := _ObjFast([]);
  if ARequest.Risk.HasMaxDailyLoss then
    _Safe(risk)^.AddValue('max_daily_loss', ARequest.Risk.MaxDailyLoss);
  if ARequest.Risk.HasMaxSymbolLoss then
    _Safe(risk)^.AddValue('max_symbol_loss', ARequest.Risk.MaxSymbolLoss);
  if ARequest.Risk.HasCutoffTime then
    _Safe(risk)^.AddValue('cutoff_time', ARequest.Risk.CutoffTime);
  // Always include the risk key (Go decodes risk: risk.Risk; absent
  // = zero-value pointers, which is what we want when no caps set).
  _Safe(body)^.AddValue('risk', risk);

  // validity — entry_window only if either bound is set; monitor_until
  // only if HasMonitorUntil; on_expire blank = server defaults to
  // 'flatten'.
  validity := _ObjFast([]);
  if (ARequest.Validity.EntryStartHHMM <> '') or
     (ARequest.Validity.EntryEndHHMM <> '') then
  begin
    entryWin := _ObjFast([
      'start', ARequest.Validity.EntryStartHHMM,
      'end',   ARequest.Validity.EntryEndHHMM
    ]);
    _Safe(validity)^.AddValue('entry_window', entryWin);
  end;
  if ARequest.Validity.HasMonitorUntil then
  begin
    // ISO 8601 in UTC. Go decodes time.Time and re-zones to IST.
    DateTimeToString(ymd, 'yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"',
      ARequest.Validity.MonitorUntilUtc);
    monitorIso := RawUtf8(ymd);
    _Safe(validity)^.AddValue('monitor_until', monitorIso);
  end;
  if ARequest.Validity.OnExpire <> '' then
    _Safe(validity)^.AddValue('on_expire', ARequest.Validity.OnExpire);
  if ARequest.Validity.ValidUntilCancel then
    _Safe(validity)^.AddValue('valid_until_cancel', True);
  _Safe(body)^.AddValue('validity', validity);

  // params bag — typed knobs the form surfaces + free-form rows from
  // the advanced grid. Both serialise via the same TPlanParamPair
  // shape; PlanParamKind drives the JSON value type.
  if Length(ARequest.Params) > 0 then
  begin
    params := _ObjFast([]);
    for i := 0 to High(ARequest.Params) do
      case ARequest.Params[i].Kind of
        kPkInt:
          _Safe(params)^.AddValue(ARequest.Params[i].Key, ARequest.Params[i].AsInt);
        kPkFloat:
          _Safe(params)^.AddValue(ARequest.Params[i].Key, ARequest.Params[i].AsFlt);
        kPkBool:
          _Safe(params)^.AddValue(ARequest.Params[i].Key, ARequest.Params[i].AsBool);
      else
        // kPkString and kPkDuration: the bot side coerces durations
        // from "30s" / "2m" strings, so plain string is the safe
        // wire shape for both.
        _Safe(params)^.AddValue(ARequest.Params[i].Key, ARequest.Params[i].AsStr);
      end;
    _Safe(body)^.AddValue('params', params);
  end;

  // PlanCreate's MergePlanBody would re-stamp apikey + instance_id —
  // safe since AddOrUpdateValue is idempotent — but we also pass
  // AInstanceId='' to keep the merge a no-op semantically.
  result := PlanCreate(VariantSaveJson(body), '');
end;

// ── books / catalogue ────────────────────────────────────────────────

function TThoriumClient.DataArrayPost(const APath, AInstanceId: RawUtf8): RawUtf8;
var
  body: variant;
  bodyJson, response: RawUtf8;
  http: Integer;
  data: variant;
begin
  body := _ObjFast(['apikey', FApiKey]);
  if AInstanceId <> '' then
    _Safe(body)^.AddValue('instance_id', AInstanceId);
  bodyJson := VariantSaveJson(body);
  response := HttpDo('POST', Url(APath), bodyJson, 'application/json', http);
  data := EnvelopeData(response, http);
  result := VariantSaveJson(data);
end;

function TThoriumClient.TradebookGet(const AInstanceId: RawUtf8): RawUtf8;
begin
  result := DataArrayPost('/api/v1/tradebook', AInstanceId);
end;

function TThoriumClient.PositionbookGet(const AInstanceId: RawUtf8): RawUtf8;
begin
  result := DataArrayPost('/api/v1/positionbook', AInstanceId);
end;

function TThoriumClient.OrderbookGetSafe(const AInstanceId: RawUtf8): RawUtf8;
begin
  // Best-effort: an unattached broker session legitimately can't
  // produce orderbook. Swallow EThoriumApi here so the analyzer
  // downgrades cleanly to "everything is manual" rather than
  // refusing to render any report.
  try
    result := DataArrayPost('/api/v1/orderbook', AInstanceId);
  except
    on EThoriumApi do
      result := '';
  end;
end;

function TThoriumClient.SymbolLookup(const ASymbol, AExchange: RawUtf8;
  const AInstanceId: RawUtf8): RawUtf8;
var
  body: variant;
  bodyJson, response: RawUtf8;
  http: Integer;
  data: variant;
begin
  body := _ObjFast([
    'apikey',   FApiKey,
    'symbol',   ASymbol,
    'exchange', AExchange
  ]);
  if AInstanceId <> '' then
    _Safe(body)^.AddValue('instance_id', AInstanceId);
  bodyJson := VariantSaveJson(body);
  try
    response := HttpDo('POST', Url('/api/v1/symbol'),
                       bodyJson, 'application/json', http);
    data := EnvelopeData(response, http);
    result := VariantSaveJson(data);
  except
    on EThoriumApi do
      result := '';
  end;
end;

function TThoriumClient.SymbolSearch(const AQuery, AExchange: RawUtf8;
  ALimit: Integer; const AInstanceId: RawUtf8): TInstrumentArray;
var
  body, data, rows, row: variant;
  bodyJson, response: RawUtf8;
  http, i, n: Integer;
  d: PDocVariantData;
begin
  SetLength(result, 0);
  if Trim(string(AQuery)) = '' then exit;

  body := _ObjFast([
    'apikey', FApiKey,
    'query',  AQuery,
    'limit',  ALimit
  ]);
  if AExchange <> '' then
    _Safe(body)^.AddValue('exchange', AExchange);
  if AInstanceId <> '' then
    _Safe(body)^.AddValue('instance_id', AInstanceId);

  bodyJson := VariantSaveJson(body);
  try
    response := HttpDo('POST', Url('/api/v1/search'),
                       bodyJson, 'application/json', http);
  except
    on EThoriumApi do exit;
  end;
  data := EnvelopeData(response, http);
  d := _Safe(data);
  // Server may return either {results:[...]} or a bare array under
  // data — handle both shapes.
  rows := d^.GetValueOrDefault('results', data);
  if not VarIsArray(rows) then exit;
  n := _Safe(rows)^.Count;
  SetLength(result, n);
  for i := 0 to n - 1 do
  begin
    row := _Safe(rows)^.Values[i];
    result[i].BrokerKey      := _Safe(row)^.U['symbol'];
    if result[i].BrokerKey = '' then
      result[i].BrokerKey    := _Safe(row)^.U['broker_key'];
    result[i].Token          := _Safe(row)^.U['token'];
    result[i].TradingSymbol  := _Safe(row)^.U['trading_symbol'];
    if result[i].TradingSymbol = '' then
      result[i].TradingSymbol := _Safe(row)^.U['tradingsymbol'];
    result[i].Name           := _Safe(row)^.U['name'];
    result[i].Underlying     := _Safe(row)^.U['underlying'];
    result[i].Exchange       := _Safe(row)^.U['exchange'];
    result[i].InstrumentType := _Safe(row)^.U['instrumenttype'];
    if result[i].InstrumentType = '' then
      result[i].InstrumentType := _Safe(row)^.U['instrument_type'];
    result[i].Expiry         := _Safe(row)^.U['expiry'];
    result[i].Strike         := _Safe(row)^.D['strike'];
    result[i].LotSize        := _Safe(row)^.I['lot_size'];
    if result[i].LotSize = 0 then
      result[i].LotSize      := _Safe(row)^.I['lotsize'];
    result[i].TickSize       := _Safe(row)^.D['tick_size'];
    result[i].Cid            := _Safe(row)^.U['cid'];
    result[i].CidExchange    := _Safe(row)^.U['cid_exchange'];
    if result[i].CidExchange = '' then
      result[i].CidExchange  := _Safe(row)^.U['exchange'];
  end;
end;

function TThoriumClient.PlaceOrder(const ACid, ACidExchange, AAction,
  APriceType, AProduct: RawUtf8;
  AQuantity: Integer; APrice, ATrigger: Double;
  const AInstanceId: RawUtf8): RawUtf8;
var
  body, data: variant;
  bodyJson, response: RawUtf8;
  http: Integer;
begin
  body := _ObjFast([
    'apikey',    FApiKey,
    'symbol',    ACid,
    'exchange',  ACidExchange,
    'action',    AAction,
    'pricetype', APriceType,
    'product',   AProduct,
    'quantity',  AQuantity
  ]);
  // LIMIT / SL want price; SL / SL-M want trigger. We always send
  // both when non-zero; the server ignores irrelevant fields per
  // pricetype.
  if APrice > 0 then
    _Safe(body)^.AddValue('price', APrice);
  if ATrigger > 0 then
    _Safe(body)^.AddValue('trigger_price', ATrigger);
  if AInstanceId <> '' then
    _Safe(body)^.AddValue('instance_id', AInstanceId);

  bodyJson := VariantSaveJson(body);
  response := HttpDo('POST', Url('/api/v1/placeorder'),
                     bodyJson, 'application/json', http);
  data := EnvelopeData(response, http);
  result := _Safe(data)^.U['orderid'];
  if result = '' then
    result := _Safe(data)^.U['order_id'];
end;

function TThoriumClient.ClosePosition(const ACid, ACidExchange: RawUtf8;
  const AInstanceId: RawUtf8): RawUtf8;
var
  body, data: variant;
  bodyJson, response: RawUtf8;
  http: Integer;
begin
  body := _ObjFast([
    'apikey',   FApiKey,
    'symbol',   ACid,
    'exchange', ACidExchange
  ]);
  if AInstanceId <> '' then
    _Safe(body)^.AddValue('instance_id', AInstanceId);
  bodyJson := VariantSaveJson(body);
  response := HttpDo('POST', Url('/api/v1/closeposition'),
                     bodyJson, 'application/json', http);
  data := EnvelopeData(response, http);
  result := _Safe(data)^.U['orderid'];
  if result = '' then
    result := _Safe(data)^.U['order_id'];
end;

function TThoriumClient.FundsGet(const AInstanceId: RawUtf8): RawUtf8;
var
  http: Integer;
  body: RawUtf8;
  data: variant;
  url:  RawUtf8;
begin
  url := UrlWithApiKey('/api/v1/funds');
  if AInstanceId <> '' then
    url := url + '&instance_id=' + AInstanceId;
  try
    body := HttpDo('GET', url, '', '', http);
    data := EnvelopeData(body, http);
    result := VariantSaveJson(data);
  except
    on EThoriumApi do
      result := '';
  end;
end;

function TThoriumClient.MarginGet(const AInstanceId: RawUtf8): RawUtf8;
var
  http: Integer;
  body: RawUtf8;
  data: variant;
  url:  RawUtf8;
begin
  url := UrlWithApiKey('/api/v1/margin');
  if AInstanceId <> '' then
    url := url + '&instance_id=' + AInstanceId;
  try
    body := HttpDo('GET', url, '', '', http);
    data := EnvelopeData(body, http);
    result := VariantSaveJson(data);
  except
    on EThoriumApi do
      result := '';
  end;
end;

function TThoriumClient.PlanHalt(const APlanId, AInstanceId,
  ANote: RawUtf8): RawUtf8;
begin
  // {"status":"halted"} patch — dispatcher signals the bot to stop
  // accepting new entries while letting in-flight positions run their
  // exits. Reversible via PlanResume.
  result := PlanUpdate(APlanId, RawUtf8('{"status":"halted"}'), AInstanceId, ANote);
end;

function TThoriumClient.PlanResume(const APlanId, AInstanceId,
  ANote: RawUtf8): RawUtf8;
begin
  result := PlanUpdate(APlanId, RawUtf8('{"status":"running"}'), AInstanceId, ANote);
end;

function TThoriumClient.PlanCancel(const APlanId, AInstanceId,
  ANote: RawUtf8): RawUtf8;
var
  body: variant;
  bodyJson, response: RawUtf8;
  http: Integer;
begin
  body := _ObjFast([
    'apikey',  FApiKey,
    'plan_id', APlanId
  ]);
  if AInstanceId <> '' then
    _Safe(body)^.AddValue('instance_id', AInstanceId);
  if ANote <> '' then
    _Safe(body)^.AddValue('note', ANote);
  bodyJson := VariantSaveJson(body);
  response := HttpDo('POST', Url('/api/v1/plans/cancel'),
                     bodyJson, 'application/json', http);
  result := VariantSaveJson(EnvelopeData(response, http));
end;

end.
