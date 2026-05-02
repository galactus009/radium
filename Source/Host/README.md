# Source/Host — in-process plugin host

The plugin host that loads `.dylib` / `.so` plugins from `~/.radium/plugins/` and runs them inside the **Radium GUI process**. Not a separate daemon — the host code links straight into `Bin/Radium.app`.

## Two execution venues for a plan

A plan submitted from the GUI wizard runs in **one** of two places:

| Venue | Implementation | When to use |
|---|---|---|
| **Embedded** (default) | Plugin host in this directory + Pascal plugin from `Source/Bots/` | Default for normal trading. Single-binary, zero daemon setup. |
| **Remote** | thoriumd's existing TradePlan API (Go bots: optionsbuddy, gammabuddy) | When you need always-on execution that survives a laptop close. |

Both flow through the same `TPlanRunner` abstraction in `Source/Plans/`:

```
TPlanRunner ─┬─ TEmbeddedPlanRunner  → uses Source/Host/   (this directory)
             └─ TServerPlanRunner    → uses Source/Api/Radium.Api.Client.pas
                                         → POST to thoriumd /api/v1/plans/*
```

The wizard's "Where to run" step at submission time picks one. Same `TPlanCreateRequest`; different runner.

## What lives here

*(skeleton — files added as Phase 1 lands)*

| File | Role |
|---|---|
| `Radium.Host.PluginLoader.pas` | Discovers plugins under `~/.radium/plugins/`, dlopens, calls `RadiumBotPluginEntry`, registers capabilities. |
| `Radium.Host.HostApi.pas` | Implements the `THostApi` record from `Source/Sdk/`: log → file + GUI panel; HttpGet/HttpPost via TThoriumClient; LlmAsk via thoriumd `/ai/ask`; SymbolLookup via thoriumd `/symbol`; NowEpochMs in IST. |
| `Radium.Host.PlanStore.pas` | SQLite-backed local plan store (mORMot sqlite3). Schema: `plans(id, capability, instance_id, status, payload TEXT)`. Same `~/.radium/radium.db` as clerk. |
| `Radium.Host.TickSubscriber.pas` | Subscribes to thoriumd's WS/UDS tick feed; fans out to active plugins by symbol. |
| `Radium.Host.OrderRouter.pas` | Translates `TBotOrderIntent` → thoriumd order REST. Reuses TThoriumClient. |

## Linux + macOS parity

Plugin loading uses `dynlibs.LoadLibrary` (POSIX `dlopen` under the hood on both targets). File extension differs:

```pascal
const
  PLUGIN_EXT = {$IFDEF DARWIN}'.dylib'{$ELSE}{$IFDEF LINUX}'.so'{$ELSE}'.dll'{$ENDIF}{$ENDIF};
```

Both branches must build and ship for every change.
