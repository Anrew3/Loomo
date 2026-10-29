# Contributing to Loomo

Thanks for helping. A few things make reviews quick.

## Getting set up

```bash
open Loomo.xcworkspace        # run the Loomo scheme; ⌘U runs the tests
cd Packages/CrimpKit && swift test   # the engine alone, no Xcode project needed
```

No Apple Developer account is needed: a fresh clone builds signed to run locally, with iCloud off. To test
iCloud, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and add your Team ID.

For parts search, add your own API keys in Loomo ▸ Settings ▸ Parts sources. Never commit keys: they belong
in the Keychain (the app) or your environment (`crimp --lookup`).

## Where things live

- `Packages/CrimpKit/Sources/CrimpCore`: the model, routing, lengths, analysis and rule checks. Foundation only,
  and the place for most logic, because it's unit-tested.
- `Packages/CrimpKit/Sources/CrimpCore/HarnessCommands.swift`: every scripted edit. The CLI, the MCP tools and
  the app's live bridge all run these, so a new command added here appears in all three.
- `Packages/CrimpKit/Sources/PartsClient`: parts search and the distributor clients.
- `App/Loomo`: the SwiftUI app.

## Pull requests

- Add or update tests for behaviour changes (`Packages/CrimpKit/Tests`). Tests must not call the network; the
  distributor tests use recorded responses and a stubbed URL loader.
- Keep `swift test` and the app build passing.
- If you change an MCP tool, run `python3 scripts/test-mcp.py Packages/CrimpKit/.build/debug/crimp /tmp/mcp-test`.
- Describe what changed and why, and how you checked it.

## Reporting bugs

Include your macOS version, what you did, what you expected, and what happened. A `.loomo` file that shows
the problem helps a lot; strip anything confidential first.
