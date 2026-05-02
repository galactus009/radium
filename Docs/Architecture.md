# Radium Architecture

One-pager. Read this first; the rest of the docs (when they land) are
detail.

## What Radium is

A desktop GUI client of **thoriumd**. Single Lazarus + FreePascal +
Qt6 application. No daemon, no broker connections, no state of its own
(beyond display caches).

```
+---------------------------------------------------------------+
|  Radium GUI (Lazarus + Qt6, this repo)                        |
|                                                               |
|  Source/Gui/   forms + controllers (LCL)                      |
|       |                                                       |
|       v                                                       |
|  Source/Api/   typed Pascal client of thoriumd's REST + WS    |
|       |                                                       |
+-------|-------------------------------------------------------+
        | HTTP + WS (proxy-aware via mORMot)
        v
+---------------------------------------------------------------+
|  thoriumd (Go, /Users/rbhaskar/Development/Thorium/thoriumd)  |
|                                                               |
|  REST API   /login, /api/v1/plans, /api/v1/risk, /quotes, ... |
|  WS streams /tick-stream, /event-stream                       |
|  brokers    Fyers, Indmoney, Kite, Shoonya, mock              |
|  bots       optionsbuddy + future strategies                  |
|  statedb    audit log + plans + positions + pnl               |
+---------------------------------------------------------------+
```

## Why a thin client

- **Single source of truth.** Orders, positions, fills, plans all live
  in thoriumd. The GUI never authors that state.
- **Reuse what's already shipping.** thoriumd already integrates with
  Fyers, Indmoney, Kite, Shoonya. Building it again in Pascal would
  duplicate ~20k LOC for no operational gain.
- **Multi-client.** A future iPhone app + this desktop GUI both speak
  the same thoriumd API. No client-side drift in business rules.

## Priority order

1. **`thoriumctl` parity** (Monday baseline) — login/logout/refresh,
   status/ping, plan CRUD, risk get/set. The Pascal client is a
   typed port of `thoriumd/cmd/thoriumctl/main.go`'s HTTP calls.

2. **`clerk` parity** — end-of-session report panel. Implementation:
   the GUI shells out to the existing `clerk` Go binary
   (`Process.Execute('clerk --apikey ... --base ...')`) and parses
   its `report.json` output. Zero re-implementation.

3. **Watchlist, order ticket, audit browser** — after Monday.

4. **Charts** — last, per the project rule.

## Boundaries

- The GUI thread NEVER blocks on a broker call. Network I/O runs in a
  worker thread, results posted back via `TThread.Queue`.
- No SQLite cache day 1. Add it as an event-log projection (pattern C)
  if filter latency on the audit panel becomes a problem.
- No direct broker WS dialing. The tick stream comes from thoriumd's
  WS bridge.
- Outgoing REST is proxy-aware (mORMot's `THttpClientSocket` reads
  proxy config from the Pascal-side `TProxyConfig`).

## Layout (one level under each)

```
Source/{Cid, Api, Types, Gui}
Tests/{Api, Runner}
Projects/{Radium.lpi, Radium.lpr, RadiumTests.lpi, RadiumTests.lpr}
Packages/    .lpk packages, added when needed
Bin/, Lib/   build artefacts (gitignored)
```

## Conventions

- `{$mode Delphi}{$H+}` everywhere — Delphi-portable for a future
  cross-compiler effort.
- `Radium.<Module>.<Unit>` namespace (e.g. `Radium.Api.Login`,
  `Radium.Gui.MainForm`). Filename mirrors unit name.
- Forms: `.pas` + paired `.lfm` in `Source/Gui/`. `{$R *.lfm}` in the
  unit. Standard Lazarus IDE-editable shape.
- HTTP via `mormot.net.client.THttpClientSocket`.
- JSON via `mormot.core.json.RecordLoadJson` / `RecordSaveJson` —
  one Pascal record per thoriumd JSON shape, no dynamic variants on
  the hot paths.

## Reuse references

- `Docs/ThoriumdContract.md` — **hardcoded** wire contract Radium pins
  itself to. Read first before changing anything in `Source/Api/`.
- `thoriumd/cmd/thoriumctl/main.go` — endpoint URLs and JSON shapes;
  the contract above is derived from this and `thoriumd/server/`.
- `thoriumd/cmd/clerk/main.go` — report logic; we shell out, don't
  port.
- `Thorium/openalgo` (when relevant) — broker-side wire formats; not
  consumed by Radium directly since thoriumd is the broker boundary.

## Non-goals

- Standalone operation without thoriumd.
- Plugin architecture (broker or bot) on the Radium side.
- Direct broker connectivity.
- Audit-grade persistence (thoriumd's `statedb` already does this).
