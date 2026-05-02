# Radium

Lazarus + FreePascal desktop GUI client for **thoriumd** (the Go trading
daemon at `/Users/rbhaskar/Development/Thorium/thoriumd`).

Radium is a client. It does not connect to brokers directly, does not
host bots, does not own state. Every broker session, every order, every
position, every event lives in thoriumd. Radium is the operator's
window into that state — login, place orders, watch positions, manage
trading plans, browse the audit log.

## Status

Pre-alpha scaffold (slice 0). Window opens; no functionality wired yet.

Priority order:
1. **`thoriumctl` parity** — login/logout/refresh, status/ping, plan
   CRUD, risk get/set. Trading-on-Monday baseline.
2. **`clerk` parity** — end-of-session report panel (shells out to the
   existing `clerk` Go binary, parses its JSON).
3. Watchlist, order ticket, audit browser — after Monday.
4. Charts — last.

## Requirements

- **macOS** (primary) or **Linux** (must-have parity)
- Lazarus 3.0+ with Qt6 widgetset support
- FPC 3.2+
- mORMot 2 source tree available — sets `MORMOT2` env var
- thoriumd running locally (or reachable via `RADIUM_THORIUMD_URL`)

### macOS

```bash
brew install lazarus qt
make app           # builds Bin/Radium
make run           # launches it
```

### Linux

```bash
sudo apt install lazarus-ide qt6-base-dev
make app
make run
```

## Layout

```
Source/      one level under here per the project rule
  Cid/       OpenAlgo CID parse/format helpers (client-side filtering)
  Api/       thoriumd HTTP + WS client
  Types/     Pascal records mirroring thoriumd's JSON shapes
  Gui/       Lazarus LCL forms + controllers (.pas + .lfm pairs)

Tests/
  Api/       api/ unit tests (the only layer with test coverage)
  Runner/    test runner entry point

Projects/
  Radium.lpi          the desktop app (Qt6 widgetset)
  Radium.lpr
  RadiumTests.lpi     test runner
  RadiumTests.lpr

Packages/    .lpk runtime packages (added when needed)
Bin/         build output (gitignored)
Lib/         intermediate units (gitignored)
Resources/   icons, .res
Docs/
  Architecture.md
Build/       shell scripts for one-command builds
```

## Conventions

- Pascal mode: `{$mode Delphi}{$H+}`. Stays Delphi-portable so a future
  cross-compiler port is mechanical, not a rewrite.
- Strings: `RawUtf8` (mORMot UTF-8 byte buffer) on internal APIs;
  `string` only at the LCL boundary where the framework demands it.
- HTTP: `mormot.net.client.THttpClientSocket` (proxy-aware).
- Forms: standard Lazarus `.pas` + `.lfm` pair, IDE-editable.
- Tests: mORMot's `TSynTestCase`. Test scope = the `Api/` layer (the
  thoriumd integration boundary).

## Reuse, by design

- Endpoints + JSON shapes ported from `thoriumd/cmd/thoriumctl/main.go`
  (read it, don't re-design).
- Reports shell out to the existing `clerk` binary; we don't reimplement
  its tradebook/position/orderbook logic.
- mORMot for HTTP, WS, JSON, SQLite (when added).

The thoriumd wire shapes Radium pins itself to are documented as a
**hardcoded contract** in `Docs/ThoriumdContract.md`. Treat it as
required reading before touching anything in `Source/Api/`.

The visual language (colour palette, typography, menu-driven shell) is
pinned the same way in `Docs/LookAndFeel.md`. Required reading before
touching anything in `Source/Gui/`.

## Non-goals

- Direct broker connectivity (thoriumd handles it).
- In-process bot hosting (thoriumd handles it).
- Audit log of record (thoriumd's `statedb` is the source of truth).
- Multi-process broker plugin architecture (deferred — thoriumd
  already has Fyers/Indmoney/Kite/Shoonya/mock).
