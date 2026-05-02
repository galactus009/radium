# Repo layout

Single repo for the whole stack. Three binaries get built from one tree:

| Binary | Purpose | Project file |
|---|---|---|
| `Bin/Radium.app` (macOS) / `Bin/Radium` (Linux) | GUI + embedded plugin host | `Projects/Radium.lpi` |
| `Bin/Plugins/optionsbuddy.{dylib,so}` | Bot plugin | `Projects/OptionsBuddy.lpi` *(coming)* |
| `Bin/Plugins/gammabuddy.{dylib,so}` | Bot plugin | `Projects/GammaBuddy.lpi` *(coming)* |

**No separate `radiumd` daemon.** The plugin host lives inside the GUI process (`Source/Host/`). When always-on execution is needed, the plan runs **remote on thoriumd** — its existing TradePlan API + Go bots stay the cloud venue. Operators pick "Embedded" or "Remote (thoriumd)" per plan submission via the wizard's "Where to run" step.

Linux + macOS parity is non-negotiable. Windows is best-effort, not gated for releases.

## Source tree

```
Source/
  Sdk/             — plugin contract.   ABI between radiumd ⇄ plugins.
                     Compiles under FPC + Delphi.  ANY change here is a
                     breaking change for plugins.
                     One file: Radium.Bots.Sdk.pas

  Wire/            — Pascal mirror of thoriumd's JSON wire shapes.
                     Currently lives in Source/Api/ for legacy reasons;
                     will migrate.   Anything that hits the network in
                     either direction touches a unit here.

  Net/             — TThoriumClient + future radiumd REST client.
                     HTTP transport only — no business logic.   Lives
                     in Source/Api/ today; will migrate alongside Wire.

  Gui/             — Lazarus + Qt6 frames, wizard, theme, dialogs.
                     Only the GUI binary links these.   Plugins must
                     never `uses` anything from here.

  Host/            — in-process plugin host: loader, plan store
                     (SQLite), tick subscriber, order router.   Linked
                     into the GUI binary; not a separate daemon.

  Plans/           — TPlanRunner abstraction.  Shared by GUI (today's
                     server runner over HTTP) and Daemon (future local
                     runner that dispatches into a plugin).

  Clerk/           — round-trip analyzer + types.  Pascal port of the
                     Go clerk binary.  Pure (no HTTP), so callable
                     from GUI and Daemon both.

  Bots/            — plugin sources.   One subdir per plugin:
    OptionsBuddy/    Source/Bots/OptionsBuddy/ → optionsbuddy.dylib
    GammaBuddy/      Source/Bots/GammaBuddy/   → gammabuddy.dylib
                     Each plugin only `uses` Radium.Bots.Sdk.   No
                     cross-imports between plugins.   Reviewer rejects
                     anything that reaches into Source/Gui/, /Net/, etc.

  Cid/, Types/     — older scratch dirs, currently empty.   May host
                     CID parsing if it lands.
```

## Dependency rules

```
plugins (Bots/*)        →  uses ONLY Sdk/
                                                    (no Gui, no Net,
                                                     no Host, no Wire)

Host/                   →  uses Sdk, Wire, Net, Plans, Clerk
                           Loads plugins from Bin/Plugins/ at runtime
                           Linked INTO the GUI binary

GUI (Gui/)              →  uses Host (for embedded mode), Wire, Net,
                           Plans, Clerk

Sdk/                    →  uses RTL only (SysUtils, Classes)

Wire/, Net/, Plans/,    →  pure data + transport — no Gui, no Host
  Clerk/
```

If a `uses` clause violates this, the build is wrong even if it compiles.

## Where things live, by question

- **"What does my plugin compile against?"** → `Source/Sdk/Radium.Bots.Sdk.pas`
- **"How does the GUI talk to thoriumd?"** → `Source/Api/Radium.Api.Client.pas` (TThoriumClient)
- **"What does a TradePlan look like in Pascal?"** → `Source/Api/Radium.Api.Types.pas` (TPlanCreateRequest)
- **"Where is the round-trip / charges logic?"** → `Source/Clerk/Radium.Clerk.Analyzer.pas`
- **"How does the GUI render the plans list?"** → `Source/Gui/Radium.Gui.PlansFrame.pas`
- **"Where will the plugin loader live?"** → `Source/Daemon/Radium.Daemon.Plugin.Loader.pas` *(coming)*
- **"Why three sidebar buttons not four?"** → `Source/Gui/Radium.Gui.MainForm.lfm`

## Why monorepo

Single developer, three components that change together (SDK ↔ daemon ↔ plugins evolve in lockstep), one CLAUDE.md, one CI, one release tag. The "plugins authored separately" goal is satisfied by the directory boundary + dependency rules above — just as enforceable as a repo boundary, no submodule pain.

If we ever distribute the SDK to third-party plugin authors, `Source/Sdk/` is small and self-contained — extract it then. Premature extraction costs more than late extraction.
