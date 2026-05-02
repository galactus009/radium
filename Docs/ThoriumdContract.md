# Thoriumd Wire Contract — Hardcoded Requirement

**Status:** HARDCODED. This document is the authoritative wire contract
between Radium (client) and thoriumd (Go daemon). The shapes below are
not negotiated, discovered, or reflected at runtime — Radium pins them
into Pascal types in `Source/Api/`. When thoriumd changes shape, this
file changes first, then `Radium.Api.Types.pas` and
`Radium.Api.Client.pas` change to match. There is no version negotiation
on the wire.

**Source of truth (Go-side):**
- Routes registered in `thoriumd/server/server.go` (`buildMux`).
- Envelope helpers in `thoriumd/server/envelope.go`.
- Per-endpoint request/response structs colocated with their handlers
  in `thoriumd/server/handlers_*.go` and `thoriumd/server/ai.go`.

**Scope of this contract for Radium:**
- Control-plane parity with `thoriumctl` (priority #1, today).
- Clerk parity is *out of band*: Radium shells out to the existing
  `clerk` Go binary and parses `report.json`. No direct REST surface.
- Data-plane endpoints (`/placeorder`, `/orderbook`, `/quotes`,
  `/optionchain`, …) are NOT consumed by Radium today. They are listed
  at the bottom of this file as known-not-used so future slices can
  switch them on without re-discovering shapes.

> **Deviation rule:** if Radium's behaviour disagrees with this file,
> Radium is wrong. If thoriumd's behaviour disagrees with this file,
> thoriumd is wrong. Either way, the fix is a code change on the side
> that drifted, and a doc update here in the same commit.

---

## 0. Transport

- **Base URL:** operator-supplied. Default `http://localhost:8080`.
  thoriumctl reads `THORIUM_HOST`; Radium stores it in app settings.
- **Mounts:** every route is dual-mounted at `/<path>` and
  `/api/v1/<path>`. Radium uses the bare `/<path>` form to match
  thoriumctl byte-for-byte.
- **Content-Type (request):** `application/json` on every POST.
- **Content-Type (response):** `application/json; charset=utf-8` for
  every endpoint except `GET /health` (returns `text/plain` "ok").
- **Auth:** API key. Submitted via:
  - JSON body field `"apikey"` for POST endpoints.
  - Query string `?apikey=…` for GET endpoints (`/status`,
    `/admin/ai/config`, `/admin/risk`).
  - `/ping` is the only endpoint that explicitly does NOT require apikey.
- **HTTP timeout policy (client side):** thoriumctl uses 120s for
  POSTs (login can take a while — broker auth + catalog load) and 15s
  for GETs. Radium mirrors this.

---

## 1. Response envelopes

Three envelope shapes exist on the wire. Two are standard; one is
unique to `/ping`.

### 1.1 Standard success
```json
{ "status": "success", "data": { … } }
```
HTTP 200.

### 1.2 Standard error
```json
{ "status": "error", "message": "human-readable reason" }
```
HTTP code is **almost always 200** (OpenAlgo convention — clients
branch on the `status` field, not on HTTP code). A subset of failures
DO return non-200:
- `400` — invalid JSON body.
- `404` — `plan_id` not found on `/plans/get`.
- `500` — internal failure (e.g. risk persist).
- `503` — store/dependency not configured.

Pascal client must therefore inspect both the HTTP status code and the
`status` JSON field. `EThoriumApi` carries `HttpCode` for diagnostics.

### 1.3 `/ping` envelope (the odd one)
```json
{ "status": "ok", "message": "pong" }
```
HTTP 200. **Not** the standard `{status,data}` shape — `status` is
literally `"ok"`, not `"success"`, and there is no `data` field.
`Radium.Api.Client.Ping` measures wall-clock round-trip locally and
returns a `TPingResult.RoundTripMs`; the body is a sentinel.

---

## 2. Endpoints used by Radium (control plane)

Order matches the on-screen menu structure of Radium's GUI shell.

### 2.1 `POST /login` — attach broker, build catalog, pre-subscribe

Request:
```json
{
  "apikey":      "…",
  "broker":      "fyers",
  "token":       "<APP_ID>:<JWT>",
  "instance_id": "alpha",     // optional; server defaults to broker name
  "feed":        true          // optional; tri-state, see below
}
```
- `feed` tri-state:
  - **omitted** → auto, first-attached-wins.
  - `true` → force-promote this session to feed; demote any prior feed.
  - `false` → trading-only; never feed even if no other feed exists.
  - Pascal mapping: `TFeedHint = (fhAuto, fhTrue, fhFalse)`. `fhAuto`
    skips the JSON field entirely.

#### 2.1.1 Future field — `listen_interface` (PINNED)

Reserved for an upcoming thoriumd capability. The Radium attach
modal already exposes the selector and emits the values listed
below; thoriumd ignores the field today. Pinned now so when the
daemon implements it, both sides match byte-for-byte without a
migration.

```json
{
  "apikey":           "…",
  "broker":           "fyers",
  "token":            "<APP_ID>:<JWT>",
  "feed":             true,
  "listen_interface": "uds"   // or "websocket"; only sent when feed=true
}
```

- `"uds"` — thoriumd opens a Unix Domain Socket and consumes the
  feed from a forwarder process pushing into it. Default path TBD
  (likely `/tmp/thorium.<instance>.sock`).
- `"websocket"` — thoriumd binds a WebSocket listener on `0.0.0.0`
  for the feed. Default port TBD.
- **omitted** — current behaviour: thoriumd dials the broker
  directly. Required default until thoriumd supports listening.

Pascal mapping: `TAttachBrokerForm.ListenInterface: RawUtf8`,
returning `'uds'` / `'websocket'` / `''`. Until thoriumd ships
the field, `Radium.Api.Client.Login` does NOT pass this value on
the wire; MainForm reads it for local state only. The day thoriumd
ships it, the wire-passing line is the only edit on Radium's side.

Success `data`:
```json
{
  "instance_id":    "alpha",
  "broker":         "fyers",
  "attached_at":    "2026-05-02T09:14:23Z",   // RFC3339 UTC
  "catalog_rows":   148231,
  "is_feed_broker": true
}
```
Pascal: `TLoginResult` (Pascal-natural names; client maps to/from
snake_case).

### 2.2 `POST /logout` — detach broker

Request:
```json
{ "apikey": "…", "instance_id": "alpha" }   // instance_id optional
```
Single-session callers may omit `instance_id` — server auto-resolves.

Success `data`: opaque (currently a string message). Radium treats it
as RawUtf8.

### 2.3 `POST /ping` — health probe

Request: any body, including `{"apikey":"…"}` (apikey ignored).
Response: special envelope (see §1.3). Radium returns
`TPingResult.RoundTripMs`.

### 2.4 `GET /status?apikey=…` — operator snapshot

Success `data`:
```json
{
  "now":                 "2026-05-02T09:14:23Z",
  "uptime":              "1h2m3s",
  "bus_subscribers":     7,
  "ticks_total":         182331,
  "ticks_per_sec_1s":    142.0,
  "ticks_per_sec_10s":   138.7,
  "ticks_per_sec_60s":   135.4,
  "goroutines":          93,
  "mem_alloc_mb":        212,
  "registered_brokers":  ["fyers", "kite", "shoonya", …],
  "feed_broker":         "fyers",
  "feed_instance":       "alpha",
  "feed_status":         "live",   // "live" | "stale" | "down"
  "bots_supervised":     2,
  "bots":                [ … ],   // optional; see thoriumd handlers_status.go
  "sessions":            [ … ]
}
```
Each `sessions[]` entry:
```json
{
  "instance_id":       "alpha",
  "broker":            "fyers",
  "attached_at":       "2026-05-02T09:00:00Z",
  "catalog_rows":      148231,
  "catalog_loaded_at": "2026-05-02T09:00:14Z",
  "adapter_attached":  true,
  "is_feed_broker":    true
}
```
Pascal: `TStatusResult` + `TStatusSession`. The full raw JSON also
reaches the GUI (for the "show everything" panel toggle) via
`TThoriumClient.StatusRaw`.

### 2.5 `GET /admin/ai/config?apikey=…` — show AI provider

Success `data`:
```json
{
  "provider": "anthropic",
  "model":    "claude-opus-4-7",
  "base_url": "https://api.anthropic.com",
  "has_key":  true
}
```
Radium never sees the raw key; only `has_key` boolean. Pascal:
`TAiConfigSnapshot` + verbatim raw JSON.

### 2.6 `POST /admin/ai/configure` — set AI provider

Request:
```json
{
  "apikey":   "…",
  "provider": "anthropic",   // anthropic | openai | grok | ollama | gemini
  "api_key":  "sk-…",
  "model":    "",            // optional; "" = provider default
  "base_url": ""             // optional; "" = provider default
}
```
Success `data`:
```json
{ "message": "configured" }
```

### 2.7 `POST /ai/ask` — single-shot prompt

Request:
```json
{
  "apikey":  "…",
  "prompt":  "…",
  "system":  "",        // optional
  "context": "",        // optional, prepended to prompt
  "model":   ""         // optional override
}
```
Success `data`:
```json
{ "reply": "…" }
```

### 2.8 `GET /admin/risk?apikey=…` — current risk knobs

Success `data` mirrors `risk.Risk` exactly. All fields are pointer
typed in Go (`*float64`, `*int`, `*string`) and serialised with
`omitempty` — **fields the operator has never set are missing from the
JSON entirely**. The Pascal `TRiskConfig` record fills missing fields
with zero / empty string; the GUI distinguishes "unset" via the raw
JSON, not the typed view.

```json
{
  "cutoff_time":            "15:06",
  "max_open_orders":        20,
  "max_daily_loss":         10000.0,
  "max_symbol_loss":        2500.0,
  "hard_max_lots":          50,
  "hard_max_notional":      2500000.0,
  "max_option_lots":        20,
  "max_premium_per_lot":    600.0,
  "max_option_notional":    1000000.0,
  "intraday_leverage":      5.0,
  "exposure_utilization":   0.8,
  "max_margin_utilization": 0.9,
  "min_available_margin":   25000.0
}
```

### 2.9 `POST /admin/risk` — patch risk knobs

Same field set as §2.8. Operator semantics:

- Field present in request body → set/override on server.
- Field absent from request body → **leave server value alone**.
- Field present with zero value (e.g. `"max_daily_loss": 0`) → clear
  to zero (operator wants to remove the cap).

Pascal mirror: `TRiskPatch` carries paired `Has<Field>: Boolean` flags
per field. Only fields with `Has = True` land in the JSON body. This
matches thoriumctl's `flagWasSet` semantics byte-for-byte.

Success `data` is the merged effective config (same shape as §2.8).

### 2.10 `POST /api/v1/plans/create` — submit a TradePlan

Request body is the plan JSON itself (operator-authored; opaque to
Radium today) merged with `apikey` and optional `instance_id`:
```json
{
  "apikey":      "…",
  "instance_id": "alpha",       // optional
  "capability":  "options.scalper",
  "broker":      "fyers",       // optional
  "instruments": [ … ],
  "risk":        { … },         // risk.Risk shape
  "validity":    { … },
  "params":      { … }
}
```

Success `data` is the full `plans.TradePlan` (id, status, revision,
history, …) — Radium captures it raw into `TPlanRef.Raw` and surfaces
the columns the grid needs (`PlanId`, `InstanceId`, `Status`, `Note`,
`UpdatedAt`).

### 2.11 `POST /api/v1/plans/list` — list plans for an instance

Request:
```json
{
  "apikey":      "…",
  "instance_id": "alpha",                  // optional
  "status":      ["running", "halted"]     // optional
}
```

Success `data`:
```json
{
  "plans": [ … TradePlan … ],
  "count": 12
}
```
Empty result is `{"plans": [], "count": 0}` (NOT `null`).

### 2.12 `POST /api/v1/plans/get` — fetch one plan

Request:
```json
{ "apikey": "…", "plan_id": "…", "instance_id": "alpha" }
```
`plan_id` required → 400 if blank. Not-found → HTTP 404.

Success `data`: full `plans.TradePlan`.

### 2.13 `POST /api/v1/plans/update` — patch a plan

Request:
```json
{
  "apikey":          "…",
  "instance_id":     "alpha",
  "plan_id":         "…",
  "expect_revision": 3,           // optional optimistic-lock check
  "note":            "tighten SL",
  "status":          "halted",    // optional, *string
  "risk":            { … },       // optional, *risk.Risk
  "instruments":     [ … ],       // optional, whole-list replace
  "validity":        { … },       // optional
  "params":          { … }        // optional
}
```
Per `updatePlanReq` in `handlers_plans.go`: pointer / slice / map nil
sentinel = "don't touch this field". `instruments`, when present, is a
**whole-list replace** — to add/remove a single instrument, send the
full new list. This is non-obvious and Radium's plan-edit dialog must
guard against it.

Success `data`: updated full `plans.TradePlan`.

### 2.14 `POST /api/v1/plans/cancel` — cancel a plan

Request:
```json
{ "apikey": "…", "plan_id": "…", "instance_id": "alpha", "note": "EOD" }
```
Success `data`: cancelled `plans.TradePlan` (status flips to
`cancelled`).

---

## 3. Streaming — `GET /ws/ticks` (deferred past control plane)

WebSocket. Client opens, sends an initial JSON frame:
```json
{ "symbols": ["NSE_INDEX:NIFTY", "NFO:NIFTY26MAY24500CE", …] }
```
…and then receives one JSON object per tick:
```json
{
  "cid":       "…",                  // OpenAlgo CID — non-negotiable
  "symbol":    "NIFTY26MAY24500CE",
  "exchange":  "NFO",
  "ltp":       182.4,
  "bid":       182.3,
  "ask":       182.5,
  "bid_qty":   75,
  "ask_qty":   75,
  "open":      180.0,
  "high":      183.1,
  "low":       179.5,
  "close":     181.2,
  "volume":    34125,
  "oi":        152000,
  "timestamp": 1748848463000          // unix ms
}
```
Radium consumes via `mormot.net.ws.client.THttpClientWebSockets`.
**Not implemented** before control-plane parity is done.

---

## 4. Endpoints Radium does NOT consume today

These exist on thoriumd (registered in `server.go` lines ~482–605) but
Radium does not call them in the control-plane phase. They are listed
so a future slice can wire them up without re-deriving the shape.

- Catalog: `/symbol`, `/search`, `/expiry`.
- Read-only broker: `/funds`, `/margin`, `/positionbook`, `/holdings`,
  `/orderbook`, `/tradebook`, `/order_status`, `/quotes`, `/history`.
- Subscriptions: `/subscribe`, `/unsubscribe`, `/subscriptions`,
  `/ltp`.
- Order placement: `/placeorder`, `/modifyorder`, `/cancelorder`,
  `/cancel_all_orders`, `/closeposition`, `/basketorder`,
  `/placesmartorder`.
- Options surface: `/optionchain`, `/optiongreeks`, `/multiquotes`,
  `/depth`, `/openposition`, `/pnl`, `/chart`, `/option/gex`,
  `/option/maxpain`, `/option/payoff`, `/option/strategy`,
  `/option/synthetic`, `/option/oi_profile`,
  `/option/expiry_metrics`, `/scan/options`.
- AI streaming: `/ai/chat`, `/ai/stream`.
- Admin: `/admin/promote_feed`.
- Bots: `/bots/schema`.
- Events: `/events` (SSE; Radium uses the WS tick channel for live
  data and the future SQLite projection for historical).
- MCP: `/mcp` (in-process tool dispatch — not a Radium concern).
- Health: `/health` (Radium uses `/ping` instead — same purpose,
  authenticated round-trip with timing).

When a future slice adopts one of these, the entry moves up to §2 with
the full request/response shape, and a paired Pascal record lands in
`Radium.Api.Types.pas`.

---

## 5. CID — non-negotiable

Every instrument identifier crossing this wire is an OpenAlgo-compliant
CID. Radium's CID encoder/decoder (`Source/Cid/`, when re-introduced)
must produce byte-equivalent output to `thoriumd/cid` and OpenAlgo's
reference. This is not negotiable; do not propose alternative
encodings, lossless or otherwise.

---

## 6. Change discipline

1. Discovering a shape mismatch on the wire is a P0 — operator-facing
   surfaces will misrender or refuse to send.
2. Fix order: this doc → Pascal types → Pascal client → GUI consumer →
   thoriumd if the issue is on that side.
3. Every commit that changes a wire shape touches both this file and
   the affected `Source/Api/Radium.Api.*.pas` units in the same diff.
   Reviewers reject splits.
