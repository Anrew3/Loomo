# Loomo guide

The details behind the [README](../README.md): every part of the app, the `crimp` command line, Claude and
other AI clients, iCloud, tests and the source layout.

## System projects

A system project (`.loomosys`, **File ▸ New System Project**, ⇧⌘N) holds devices and several harnesses:

- **System Diagram:** devices and harnesses as blocks. Drag a title to move a block. Drag from one connector row to another to mate them. Click a connector to trace its net.
- **Harnesses:** each harness in the sidebar opens the full harness editor in place. Use **Add Harness** to create one, start from the sample, or import a `.loomo` file.
- **Devices:** connectors and pin lists, with pin-list (ICD) import. "Mating Connector for…" builds the opposite half of a harness connector.
- **Mates:** pin maps for non-1:1 connections. **Auto-Mate by Name** pairs harness connectors with device connectors of the same name.
- **Signal Trace / System Netlist:** follow a signal hop by hop across harnesses and mates.
- **System BOM:** totals include each harness's quantity.
- **Rule Checker:** catches shorts between device signals, open circuits, mate problems, and every harness's own issues.
- **Print & Export:** system PDF (with every harness's drawing set) and an Excel workbook.

## Using it

- **Harness Drawing:** right-click anywhere for options. **Place Component…** (or press **C**) opens one part search across your library and every distributor, with photos. What the part is (connector, fuse holder, relay or relay socket, ring/spade terminal, ferrule…) is worked out from the distributor's category and description, and **Place as** overrides it; the part sets the cavity count and gender, and library design configurations add contacts, plugs and wedgelocks. Right-click a bundle to insert a breakout or clip, add a label or covering. Box-select or ⇧-click several items to move, duplicate (⌘D), copy (⌘C/⌘V), align or delete (⌫) them. Press **?** for every shortcut. **To Scale** redraws every segment at its true length.
- **Connectors & Pinouts:** pick a connector to get its cavity grid. Click a wire end in the palette, then click a cavity. Dropping onto an occupied cavity swaps the two.
- **Wires:** select several wires (⌘-click) to twist them, make a cable, set extra length or clear overrides.
- **Inspector:** edits whatever is selected. Every part field searches your library first, then your parts sources, and can replace a part everywhere it is used.
- **Parts Library** (⇧⌘L): internal part numbers, alternates, strip lengths, crimp tools, wire ranges, and design configurations that fill contacts, plugs and wedgelocks automatically.
- **Print & Export:** live PDF preview and page selection. Exports the drawing-set PDF, formboard 1:1 PDF, Excel workbook and WireViz YAML. **File ▸ Import** reads from-to wire lists.

## Welcome window

Loomo opens with a welcome window, like Xcode's: New Harness, New System Project and Open Existing
Project on the left; recent projects with their drawing thumbnails on the right. Turn it off with
the checkbox at the bottom; **Window ▸ Welcome to Loomo** (⇧⌘1) opens it any time.

## Harness assistant

**Harness ▸ Assistant** (⌥⌘A, or the sparkles button) opens a chat panel in place of the inspector. It runs
on Apple's on-device model (macOS 26 with Apple Intelligence turned on), so designs never leave the Mac. It can
describe the harness, explain rule-check results, and make edits: place connectors (library parts bring their
photo, terminals and seals), splices, bundles and wires, name cavity signals, rename and delete. Edits go through
`CrimpCore/HarnessScript.swift`, the same code the `crimp` CLI uses, and ⌘Z undoes them.

## Team parts library (iCloud)

The parts library can sync through CloudKit: between your own Macs, and with teammates through a standard iCloud
share (Settings ▸ Team library ▸ Share with Team…). Each part keeps its newest version, deletions travel, and
custom photos sync too. The merge rules are `CrimpCore/LibrarySync.swift` (unit-tested); the CloudKit side is
`App/Loomo/TeamLibrary.swift`.

Your preferences (units, parts source, new-wire defaults, export pages, display choices) also follow your iCloud
account through iCloud key-value storage (`App/Loomo/SettingsSync.swift`). API keys don't: they stay in each
Mac's Keychain.

iCloud needs a build signed by an Apple Developer team: the released DMG, or a source build with
`Config/Local.xcconfig` set up. Turn on **Settings ▸ Team library ▸ Sync the parts library with iCloud**.

## Shortcuts, Spotlight and Siri

Loomo adds actions to the Shortcuts app: **Check Harness**, **Summarize Harness**, **Export Drawing Set**,
**Export Manufacturing Workbook** and **Export WireViz YAML**. Each takes a .loomo file and works without
opening a window, so they fit folder automations. The first four are also App Shortcuts, available in Spotlight
and to Siri ("Check a harness in Loomo"). Code: `App/Loomo/Intents.swift`.

## Claude and other AI clients (MCP)

Claude, or any client that speaks the Model Context Protocol, can read and edit harnesses while you watch.
`crimp mcp` is the MCP server; it ships inside the app. Connect it once:

- **Claude Desktop:** Loomo ▸ Settings ▸ AI clients ▸ Add to Claude Desktop, then restart Claude Desktop.
- **Claude Code:** Settings ▸ AI clients ▸ Copy Claude Code Command, then paste it in Terminal. It runs:

```sh
claude mcp add --scope user loomo -- "/Applications/Loomo.app/Contents/MacOS/crimp" mcp
```

- **Anything else:** run `/Applications/Loomo.app/Contents/MacOS/crimp` with the argument `mcp` as a stdio server.

When Loomo is open, edits land on the open harness (the frontmost one, unless the client names another), show on the
canvas immediately, select what was added, and each is one undo step named after the tool ("Add Wire (AI)"), so ⌘Z
takes it back. When Loomo isn't running, the tools edit a `.loomo` file on disk instead, given its path.
`open_harness` opens (or creates) a file in Loomo so the session can switch to live editing.

The tools are generated from the same command catalogue as the CLI (`CrimpCore/HarnessCommands.swift`), so they
always match: describe, inspect and check the harness; add connectors, splices, nodes, bundles, wires, fuse boxes,
relays, loose pins and mated pairs; set parts, cavities and wires; rename connectors and cavities; move items;
accept deviations; pass-through wiring; remove items.

It all runs on your Mac, with no server: the app listens on a Unix-domain socket in
`~/Library/Application Support/Loomo/` that only your user account can open, and nothing listens on the network.
Settings ▸ AI clients turns live editing off.

## Files, schema and the `crimp` command line

Harnesses (`.loomo`), system projects (`.loomosys`) and the parts library (`Library.json`) are pretty-printed JSON.
The harness format is described by [Schemas/loomo.schema.json](../Schemas/loomo.schema.json); only `id`s and a
few essentials are required, everything else takes a default. Files hold the design only: wire lengths, bundle
diameters, the BOM and rule checks are computed when a file is opened.

`crimp` edits and checks harness files with the app's own engine, so IDs, lengths and rule checks always agree
with the app. Every command prints one JSON object, which makes it the natural back end for scripts; `crimp mcp` is the MCP server (see above).
It is installed inside the app at `/Applications/Loomo.app/Contents/MacOS/crimp` (and built at `Packages/CrimpKit/.build/debug/crimp`).

```sh
crimp new bench.loomo --units imperial
crimp add-connector bench.loomo --mpn DT06-2S --manufacturer "TE Connectivity / Deutsch" --x 100 --y 200
crimp add-splice bench.loomo --x 300 --y 200
crimp add-bundle bench.loomo --from C1 --to SP1 --length 6in
crimp add-wire bench.loomo --from C1:1 --to SP1 --size 18awg --color red --signal 12V
crimp validate bench.loomo      # exit 1 when there are rule-check errors
crimp accept bench.loomo --subject C1:1 --reason "Reviewed with supplier"   # accept a deviation
crimp info bench.loomo          # everything, with computed lengths and the BOM
crimp add-fuse-box bench.loomo --fuses 4 --rating "15 A"
crimp add-mated-pair bench.loomo --cavities 6        # C2F / C2M in line
crimp pass-through bench.loomo --from C3 --to C4     # pin-to-pin T-harness wiring
crimp pdf bench.loomo --out bench.pdf                # the drawing set
crimp formboard bench.loomo --out board.pdf --paper tabloid --overlap 10mm   # or --single-sheet
crimp help                         # all commands
```

An accepted check (a reviewed deviation) is stored in the file with its reason and shows as accepted in the
Rule Checker; it covers only that exact check, so it comes back if the design changes. In the app, right-click a
check ▸ Accept as Reviewed Deviation…

Parts in your library are applied automatically (photo, terminals, seals, accessories). `--lookup` searches
distributors for a photo and data, with keys from the environment (`MOUSER_API_KEY`, `DIGIKEY_CLIENT_ID` and
`DIGIKEY_CLIENT_SECRET`, `TRUSTEDPARTS_API_KEY`, `OEMSECRETS_API_KEY`, `NEXAR_CLIENT_ID` and `NEXAR_CLIENT_SECRET`),
since the CLI doesn't read the app's Keychain. Check files against the schema with
`python3 scripts/check-schema.py file.loomo` (needs `pip install jsonschema`).

## Tests, CI and profiling

- **Unit tests** (Loomo test plan, ⌘U): the CrimpKit package tests, run in random order with code coverage,
  including performance tests that time analysis, drawing and the PDF set on a 600-wire harness.
  From the command line: `scripts/build-app.sh --test`, or `cd Packages/CrimpKit && swift test`.
- **UI tests** (LoomoUI test plan): open the sample, insert from the menu, undo, browse pages. They drive the
  real app, so they need an unlocked screen:
  `xcodebuild -workspace Loomo.xcworkspace -scheme Loomo -testPlan LoomoUI test`.
- **Xcode Cloud**: `ci_scripts/ci_post_clone.sh` runs the schema check;
  `ci_scripts/ci_pre_xcodebuild.sh` stamps the CI build number with agvtool. Create the workflow in Xcode
  (Product ▸ Xcode Cloud ▸ Create Workflow) once a Team is set; suggested actions: Test (Loomo test plan) on
  every push, Archive on tags.
- **Profiling**: Product ▸ Profile (⌘I) with the Points of Interest instrument shows "Analyse harness",
  "Draw harness" and "PDF drawing set" intervals (`CrimpCore/Signposts.swift`).

## Layout

```
Loomo.xcworkspace      open this in Xcode: the app project plus the CrimpKit package
Loomo.xcodeproj        Mac app target, scheme and build settings
Loomo.xctestplan       unit test plan (LoomoUI.xctestplan: UI tests in UITests/)
ci_scripts/            Xcode Cloud scripts
App/Loomo/             SwiftUI document app
App/Resources/         Info.plist, Assets.xcassets (icon), entitlements, privacy manifest
Extensions/            Quick Look thumbnail and preview extensions for .loomo / .loomosys
Packages/CrimpKit/     Swift package:
  Sources/CrimpCore/     model, routing and lengths, analysis (BOM, cut list, nets, labels, tools, rules),
                         pinout edits, undo history, library, CSV import, XLSX writer, WireViz export
  Sources/CrimpOutputs/  CoreGraphics harness renderer and PDF drawing set (shared by canvas and export)
  Sources/PartsClient/   parts search: Mouser, Digi-Key, TrustedParts, OEMsecrets and Nexar clients, the parts database
  Sources/CrimpCLI/      `crimp` command-line tool (create, edit, validate .loomo files; JSON output)
  Tests/CrimpCoreTests/  Swift Testing suite
Config/                signing (Signing.xcconfig, and your own Local.xcconfig)
Design/Icon/           the app icon's vector master
Schemas/               JSON Schema for .loomo files
scripts/               build-app.sh (build and install), make-dmg.sh (signed, notarized DMG), release.sh,
                       make-icon.sh, check-schema.py, test-mcp.py
```
