unit Radium.Bots.Sdk;

(* ----------------------------------------------------------------------------
  radium-bots SDK — the public Pascal contract every Radium bot plugin
  compiles against. Pascal-to-Pascal: same FPC version on both sides
  of the dynamic boundary; no C-ABI marshaling tax.

  Authoring a plugin
  ──────────────────
    1. Create a Lazarus library project that uses this unit.
    2. Implement IRadiumBotPlugin (capability + factory) and
       IRadiumBot (per-plan instance — receives ticks, emits orders,
       acks fills).
    3. Export `RadiumBotPluginEntry` from the library:

         function RadiumBotPluginEntry: IRadiumBotPlugin; stdcall;
         exports RadiumBotPluginEntry;

    4. Build to a .dylib / .so / .dll. Drop it in `~/.radium/plugins/`.
    5. radiumd discovers, loads, and registers the capability at
       startup. Operators see it appear in the Radium GUI's bot picker.

  Versioning
  ──────────
    SDK_VERSION_MAJOR / SDK_VERSION_MINOR. Major bumps break ABI;
    plugins must be rebuilt. Minor bumps add optional callbacks (the
    host probes for them). v0.x is unstable — pin a tag.

  Compatibility
  ─────────────
    Compilers: FreePascal 3.2+ in mode Delphi, AND Embarcadero Delphi
    11+. Stick to the common subset: AnsiString-based strings (alias
    `TBotStr` below), no generics-of-anything-fancy, RTL units only
    (`SysUtils`, `Classes`, `DateUtils`, `Math`). FPC-only directives
    sit behind `{$IFDEF FPC}`.

    Platforms: macOS (Darwin, `.dylib`) and Linux (`.so`) are both
    first-class — non-negotiable. Any platform-specific code uses
    `{$IFDEF DARWIN}` / `{$IFDEF LINUX}` and provides matching
    branches. Don't introduce a path / signal / process call that
    only works on one OS without the other wired up. Windows (`.dll`)
    is supported best-effort but not gated on for releases.

  Wire shape
  ──────────
    The host ⇄ plugin protocol is Pascal records and interfaces — no
    JSON across the boundary. Plan body comes in as JSON (the wizard
    serialised it that way for thoriumd parity), but anything between
    radiumd and the plugin is typed.
  ---------------------------------------------------------------------------- *)

{$IFDEF FPC}
  {$mode Delphi}
{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  Classes;

const
  // Bump MAJOR when the interface shape changes (existing methods'
  // signatures, removed methods). Bump MINOR when adding optional
  // capabilities (host queries via QueryInterface; missing → host
  // falls back).
  SDK_VERSION_MAJOR = 0;
  SDK_VERSION_MINOR = 1;

type
  // String alias so plugins don't have to choose between mORMot's
  // RawUtf8 and the RTL's AnsiString. This is plain AnsiString under
  // the hood — UTF-8 by convention; the host re-encodes at JSON-in /
  // JSON-out boundaries.
  TBotStr = type AnsiString;

  // ── data records ──────────────────────────────────────────────────

  // TBotTick — one tick passed to OnTick. Symbol+exchange identify
  // the instrument (matches thoriumd's tick bus). TimeEpochMs is
  // milliseconds since unix epoch (UTC); plugin code that needs
  // IST adds the offset itself. Optional fields (oi, vix) carry 0
  // when unsourced — plugin checks for sentinel before using.
  TBotTick = record
    Symbol:      TBotStr;
    Exchange:    TBotStr;
    Ltp:         Double;
    Bid:         Double;
    Ask:         Double;
    Volume:      Int64;
    OpenInt:     Int64;     // open interest where applicable; 0 = unknown
    Vix:         Double;    // host-side decoration; 0 if no VIX feed
    TimeEpochMs: Int64;
  end;

  // TBotOrderIntent — what a plugin returns from OnDecision. The
  // host translates one intent into one /place_order REST call against
  // thoriumd. Plugin never speaks to brokers directly.
  //
  // OrderType:   'MARKET' | 'LIMIT' | 'SL' | 'SL-M'
  // Side:        'BUY' | 'SELL'
  // Product:     'MIS' | 'NRML' | 'CNC'
  // Tag:         operator-supplied (e.g. 'scalperNIFTYlongstra'); the
  //              host appends client-id prefix per broker shape so
  //              clerk's tagResolver can classify the source.
  TBotOrderIntent = record
    Symbol:    TBotStr;
    Exchange:  TBotStr;
    Side:      TBotStr;
    Qty:       Integer;
    OrderType: TBotStr;
    Product:   TBotStr;
    LimitPx:   Double;       // 0 for MARKET orders
    StopPx:    Double;       // 0 for non-SL orders
    Tag:       TBotStr;
  end;
  TBotOrderIntentArray = array of TBotOrderIntent;

  // TBotFill — host calls OnFill when an order placed by this plugin
  // gets filled at the broker. Plugin uses fills to update its own
  // round-trip / leg state without re-querying /tradebook.
  TBotFill = record
    OrderId:     TBotStr;
    Symbol:      TBotStr;
    Exchange:    TBotStr;
    Side:        TBotStr;
    Qty:         Integer;
    Price:       Double;
    Tag:         TBotStr;
    TimeEpochMs: Int64;
  end;

  // TBotInstrumentInfo — symbol metadata returned by HostApi.SymbolLookup.
  // Plugin caches per (symbol, exchange) for the life of one plan.
  TBotInstrumentInfo = record
    InstrumentType: TBotStr;   // 'OPT' | 'FUT' | 'EQ' | 'ETF' | '?'
    LotSize:        Integer;
    TickSize:       Double;
    Strike:         Double;     // 0 for non-options
    Expiry:         TBotStr;    // 'YYYY-MM-DD' for derivatives, '' otherwise
    Found:          Boolean;
  end;

  // TBotLogLevel — radiumd writes plugin logs to its own log file +
  // forwards to the GUI's bot-output panel via REST.
  TBotLogLevel = (blDebug, blInfo, blWarn, blError);

  // ── host API (callbacks the plugin calls into) ───────────────────

  // THostApi — record-of-method-pointers passed to the plugin on
  // OnLoad. Method-of-object so the host's actual `self` is bound;
  // the plugin doesn't need to manage that.
  //
  // Why a record (not an interface): the host's lifetime is the
  // daemon process; the plugin's lifetime is bounded by OnLoad +
  // OnUnload. Reference counting an interface here would mean the
  // plugin could keep the host alive past plugin unload, which is
  // never what we want. A record of method pointers stays inert
  // when the plugin lets it go.
  THostApi = record
    Log:           procedure(Level: TBotLogLevel; const AMessage: TBotStr) of object;

    // HttpGet / HttpPost — generic out-of-band HTTP for plugins that
    // need data the host doesn't pre-fetch (an external option-chain
    // API, an alternative VIX source). Plugin discipline: don't put
    // synchronous HTTP on the OnTick hot path.
    HttpGet:       function(const AUrl: TBotStr; out AResponse: TBotStr): Integer of object;
    HttpPost:      function(const AUrl, ABody, AContentType: TBotStr;
                            out AResponse: TBotStr): Integer of object;

    // LlmAsk — routes to thoriumd's /ai/ask via radiumd. Single-shot,
    // returns the model's reply or '' on transport failure (host
    // logs at error level).
    LlmAsk:        function(const APrompt, ASystem, AContext, AModel: TBotStr): TBotStr of object;

    // SymbolLookup — resolve (symbol, exchange) to canonical instrument
    // info. Cached by the host per-plan; plugin doesn't need its own
    // cache. AInfo.Found=False means catalog miss; plugin falls back
    // to suffix-based heuristics if it cares.
    SymbolLookup:  function(const ASymbol, AExchange: TBotStr;
                            out AInfo: TBotInstrumentInfo): Boolean of object;

    // NowEpochMs — host's notion of "now", in IST. Single source so
    // plugin tests can stub time. Don't use SysUtils.Now directly.
    NowEpochMs:    function: Int64 of object;
  end;

  // ── interfaces ────────────────────────────────────────────────────

  // IRadiumBot — per-plan instance. The plugin's NewBot factory
  // returns one of these for each plan submission. Lifecycle:
  //
  //   NewBot ─ OnTick* ─ OnDecision ─ OnFill* ─ OnHalt|OnResume*
  //                                          └─ OnCancel ─▶ release
  //
  // OnTick is fired every tick_every (default 1s); OnDecision is
  // fired every decision_every (default 5s). The host coalesces
  // ticks between decision frames so the plugin sees them in order
  // but doesn't re-evaluate strategy on every quote.
  //
  // OnFill arrives asynchronously (broker callback). Implementations
  // must be re-entrant: OnTick and OnFill may interleave on different
  // threads. Plan to use a critical section if you mutate shared
  // state across both.
  IRadiumBot = interface
    ['{F4DB4A50-1A9B-4F2D-9D16-92E2A3FBA901}']
    procedure OnTick(const ATick: TBotTick);
    function OnDecision: TBotOrderIntentArray;
    procedure OnFill(const AFill: TBotFill);
    procedure OnHalt;
    procedure OnResume;
    procedure OnCancel;
  end;

  // IRadiumBotPlugin — the plugin singleton. Returned by the library's
  // RadiumBotPluginEntry export. Owns the capability identity; the
  // factory is what radiumd calls to spin up a per-plan IRadiumBot.
  //
  // Multiple plans with the same capability call NewBot multiple
  // times — each gets its own IRadiumBot. The plugin singleton
  // remains shared (it's where you cache strategy-wide config /
  // model handles).
  IRadiumBotPlugin = interface
    ['{6F7D8B6F-3E4B-4E3F-9C9B-2F6B8E5A6D11}']
    // Capability — wire id matched against TradePlan.Capability.
    // Same identifier strings thoriumd's Go bots use today
    // ('options.scalper', 'gamma.scalper'). Adding a third plugin
    // means picking a new id.
    function Capability: TBotStr;

    // DisplayName — what the wizard's bot picker shows.
    function DisplayName: TBotStr;

    // OneLineDescription — wizard's body copy under the picker.
    function OneLineDescription: TBotStr;

    // ParamSchemaJson — JSON describing the param fields the wizard
    // should surface in the "Tuning" step. Same shape as thoriumd's
    // /api/v1/bots/schema response so existing GUIs can consume it.
    // Empty string = "no extra params; advanced grid only".
    function ParamSchemaJson: TBotStr;

    // OnLoad — host calls this once at plugin load. Plugin caches
    // `AHost` for the duration; it stays valid until OnUnload.
    procedure OnLoad(const AHost: THostApi);
    procedure OnUnload;

    // NewBot — factory. APlanJson is the full TradePlan body the
    // operator submitted via the GUI wizard. Plugin parses what it
    // needs (instruments, risk, params, validity) and returns a new
    // IRadiumBot. Raise an exception if the plan is malformed —
    // radiumd surfaces it back to the GUI as a plan-rejection error.
    function NewBot(const APlanJson: TBotStr): IRadiumBot;
  end;

  // The signature radiumd's loader expects from every plugin DLL.
  // Each plugin exports exactly one function with this name.
  TRadiumBotPluginEntry = function: IRadiumBotPlugin; stdcall;

const
  RADIUM_BOT_PLUGIN_ENTRY_NAME = 'RadiumBotPluginEntry';

implementation

end.
