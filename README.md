<div align="center">

<img src="Design/Icon/loomo-icon-1024.png" width="128" alt="Loomo icon">

# Loomo

**Wire harness design for the Mac.**

Draw the harness, and Loomo works out the wire lengths, bill of materials, cut list and drawings.

[![macOS 26](https://img.shields.io/badge/macOS-26-black?logo=apple)](#install)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![MIT license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

[Install](#install) · [Features](#features) · [Quick start](#quick-start) · [Guide](docs/GUIDE.md) · [Contributing](CONTRIBUTING.md)

</div>

## Features

- **Topology drawing:** connectors, splices, breakouts and bundles. Wire lengths come from the layout.
- **Pinouts and wiring:** cavity grids, wires, cables, twists, seals, plugs and coverings.
- **Rule checks:** catch wire-size, terminal, seal and routing problems while you design.
- **Manufacturing outputs:** BOM, cut list, connection tables, labels, a PDF drawing set, a 1:1 formboard and
  an Excel workbook.
- **Parts search:** Mouser, Digi-Key, TrustedParts, OEMsecrets and Octopart, with your own free API keys.
- **System projects:** devices and several harnesses, with signal tracing across them.
- **AI editing:** Claude and other MCP clients edit the open harness live. Every edit is one undo step.
- **iCloud:** projects on all your Macs, plus a shared team parts library.
- **Command line:** the `crimp` tool scripts everything the app can do.

## Install

1. Download the latest **Loomo.dmg** from [Releases](../../releases).
2. Open it and drag **Loomo** to **Applications**.
3. Open Loomo. It's signed and notarized, so macOS opens it normally.

Requires macOS 26 on Apple silicon or Intel.

## Quick start

On first launch, a short setup assistant offers three optional steps:

| Step | What it does |
|---|---|
| **Parts sources** | Paste free API keys from distributors such as [Mouser](https://www.mouser.com/api-search/) or [Digi-Key](https://developer.digikey.com/). Keys stay in your Mac's Keychain. |
| **iCloud** | New projects save to iCloud Drive and autosave. |
| **Claude** | One click connects Claude Desktop. Then ask it to "add a 4-way Deutsch connector and wire it to C1". |

Then press **⌘N** to start a harness and **C** to place a connector.

## Build from source

```bash
git clone https://github.com/Anrew3/Loomo.git
cd Loomo
open Loomo.xcworkspace   # Run the Loomo scheme; ⌘U runs the tests
```

No Apple Developer account needed. A clone builds and runs as is, with iCloud off. To turn on iCloud, copy
`Config/Local.xcconfig.example` to `Config/Local.xcconfig` and add your Team ID.

The engine builds and tests on its own: `cd Packages/CrimpKit && swift test`.

## Command line

```bash
crimp new bench.loomo
crimp add-connector bench.loomo --mpn DT06-2S --manufacturer "TE Connectivity" --cavities 2
crimp add-connector bench.loomo --mpn DT04-2P --manufacturer "TE Connectivity" --cavities 2
crimp add-wire bench.loomo --from C1:1 --to C2:1 --size 18awg --color red
crimp validate bench.loomo
crimp pdf bench.loomo --out bench.pdf
```

`crimp` ships inside the app at `Loomo.app/Contents/MacOS/crimp`. The [guide](docs/GUIDE.md) covers every
command and the MCP tools.

## Documentation

- [Guide](docs/GUIDE.md): the app in detail, the CLI, Claude and MCP, iCloud, tests and project layout
- [Features](FEATURES.md): what's implemented
- [Design](DESIGN.md): architecture
- [Releasing](RELEASING.md): building the signed, notarized DMG

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
