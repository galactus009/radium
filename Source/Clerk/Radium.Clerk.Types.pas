unit Radium.Clerk.Types;

(* ----------------------------------------------------------------------------
  Pascal records mirroring clerk's JSON report (cmd/clerk/main.go's
  `report` struct). One record per shape the Radium GUI displays.

  Why a separate types unit (parallel to Radium.Api.Types):
  - Clerk is a separate binary today and may become an in-process
    Pascal port tomorrow (see memory: plan_execution_target.md — same
    pattern). The wire shape is the contract; the source of the
    bytes (subprocess stdout vs in-memory) is the implementation
    detail.
  - Records here are HTTP-/process-free. The runner abstraction
    (Radium.Clerk.Runner) deserialises into these; the GUI frame
    binds to them. Swap the runner without touching anything else.

  Naming: Pascal-natural ("CamelCase") with the same JSON-key bridge
  done in Radium.Clerk.Runner. Strings stay RawUtf8 so we don't
  burn cycles converting on the boundary.
  ---------------------------------------------------------------------------- *)

{$mode Delphi}{$H+}

interface

uses
  mormot.core.base;

type
  // TClerkRoundTrip — one closed entry/exit cycle for a single
  // (symbol, exchange). Verdict is computed from NetPnL on the wire,
  // surfaced here verbatim so the GUI doesn't re-derive it.
  TClerkRoundTrip = record
    Symbol:    RawUtf8;
    Exchange:  RawUtf8;
    InstType:  RawUtf8;     // 'OPT' | 'FUT' | 'EQ' | 'ETF' | '?'
    LotSize:   Integer;
    SourceTag: RawUtf8;     // 'BOT' | 'MAN' | 'TAG' | 'MIXED'
    OpenedAt:  RawUtf8;     // RFC3339 IST-zoned
    ClosedAt:  RawUtf8;
    BuyQty:    Integer;
    SellQty:   Integer;
    BuyValue:  Double;
    SellValue: Double;
    GrossPnL:  Double;
    Charges:   Double;
    NetPnL:    Double;
  end;
  TClerkRoundTripArray = array of TClerkRoundTrip;

  TClerkOpenPosition = record
    Symbol:     RawUtf8;
    Exchange:   RawUtf8;
    InstType:   RawUtf8;
    LotSize:    Integer;
    Qty:        Integer;
    AvgPrice:   Double;
    Ltp:        Double;
    Unrealized: Double;
  end;
  TClerkOpenPositionArray = array of TClerkOpenPosition;

  // TClerkSourceStat — one row of the BOT / MAN / TAG / MIXED split.
  // The "is the bot or the human responsible for today's outcome?"
  // post-mortem table.
  TClerkSourceStat = record
    Source:   RawUtf8;
    Trips:    Integer;
    Wins:     Integer;
    Realized: Double;     // net (after charges)
    Charges:  Double;
  end;
  TClerkSourceStatArray = array of TClerkSourceStat;

  TClerkSymbolStat = record
    Symbol:     RawUtf8;
    InstType:   RawUtf8;
    Trips:      Integer;
    Wins:       Integer;
    Realized:   Double;
    Charges:    Double;
    OpenQty:    Integer;
    Unrealized: Double;
  end;
  TClerkSymbolStatArray = array of TClerkSymbolStat;

  // TClerkReport — full snapshot of one clerk run. The GUI frame
  // renders the totals card from the scalars and the three tables
  // from the arrays.
  TClerkReport = record
    Trips:        TClerkRoundTripArray;
    Open:         TClerkOpenPositionArray;
    Wins:         Integer;
    Losses:       Integer;
    Flats:        Integer;
    GrossPnL:     Double;     // before charges
    ChargesTotal: Double;
    Realized:     Double;     // net
    Unrealized:   Double;
    GrossWin:     Double;     // sum of NetPnL on WIN trips
    GrossLoss:    Double;     // sum of NetPnL on LOSS trips (negative)
    PerSymbol:    TClerkSymbolStatArray;
    PerSource:    TClerkSourceStatArray;
    // Provenance — which file / run produced this report. Surfaced
    // in the frame's small status line so the operator knows whether
    // they're looking at a live run or a stored snapshot.
    SourceLabel:  RawUtf8;    // 'live run · 14:32 IST' | '~/.thorium/clerk/2026-04-30/...'
    GeneratedAt:  RawUtf8;
  end;

implementation

end.
