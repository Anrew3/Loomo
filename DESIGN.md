# Loomo: design

## Architecture

```
┌──────────────────────── Loomo.app (SwiftUI, DocumentGroup) ────────────────────────┐
│ HarnessDocument (ReferenceFileDocument)                                                 │
│   harness ──didSet──► HarnessAnalysis (recomputed each edit)                            │
│          └─────────► UndoHistory (snapshots, coalesced) ⇄ window UndoManager            │
│ Views: drawing canvas · pinout editor · tables · inspector · BOM/cut list/nets ·        │
│        rule checker · print & export (PDFKit preview) · Parts Library window            │
├──────────────┬──────────────────────────┬───────────────────────────────────────────────┤
│ CrimpCore    │ CrimpOutputs             │ PartsClient ──HTTPS──► distributor APIs       │
│ Foundation   │ CoreGraphics renderer    │                        Nexar OAuth + GraphQL  │
│ only         │ PDF drawing set + 1:1    │                        SQLite cache, mock mode │
│              │ formboard                │                                                │
└──────────────┴──────────────────────────┴───────────────────────────────────────────────┘
```

- **Documents:** `.loomo` files are JSON (`Harness`, schema version 2). macOS provides windows, autosave, Versions and dirty state.
- **Undo:** every change to `harness` records the previous snapshot. Unnamed edits within 0.8 s merge into one step, so typing or a drag is a single undo. Named actions (`doc.perform("Assign W3·A to X1:1") { … }`) are always their own step. Each step registers with the window's `UndoManager`, so the Edit menu shows real action names. The toolbar history list can undo several steps at once.
- **Rendering:** `HarnessRenderer` draws into any y-down `CGContext`. The SwiftUI canvas calls it through `withCGContext`, and `PDFDrawingSet` calls it on flipped PDF pages, so the screen and the printout match.

## System projects (CrimpCore/SystemModel.swift, SystemAnalysis.swift)

`SystemProject` holds `Device`s (with `DeviceConnector` pin lists), `HarnessInstance`s (an embedded `Harness`, a quantity and a diagram position) and `Mate`s between two `ConnectorRef`s (`.harness(H1, X1)` or `.device(ECU, J1)`), with an optional pin map.

`SystemAnalysis` builds one graph whose nodes are pins ("H1/X1:3", "ECU/J1:12"), splices ("H1/SP1") and lone wire ends. Its edges are wires (from each harness) and mated pin pairs. Connected components are the system nets, named from device pin signals first, then wire signals. Two different device signals on one net is a short; one device signal on two nets is an open circuit. `trace(from:)` is a breadth-first walk that returns each hop. The system BOM merges each harness BOM × quantity, plus device parts.

In the app, `SystemDocument` keeps one `HarnessDocument` per open harness instance. Child edits sync up into the project without a system undo step (the child already registered one). System undo pushes the restored harness back down. All steps share the window's UndoManager. `SystemLayout` (in core) gives block and port geometry to both the canvas and `SystemRenderer`/`SystemPDF`.

## Model (CrimpCore/Model.swift)

All lengths are in mm. The model holds:

- topology: `TopologyNode`, `Segment`
- `Connector` (kind: housing, pigtail, device, ring, spade, ferrule, quick-connect) with its `Cavity` and `Accessory` lists
- `Wire` (size, colour, insulation, OD, role, cable, marker, extra length, override)
- `Cable` (shielded, jacket OD and strip) and `Twist` (lay length)
- `Splice` (including in-line diode and resistor), `Covering` with `TapeWrap`
- `BundleLabel` (synced or fixed text), `DrawingNote` (flags), `Revision`, `ToolItem`, `Annotation`, `TitleBlock`
- BOM overrides and extra lines

`PartRef` carries the MPN, internal PN, alternates, the generic flag, and terminal data: strip length, crimp tool, and wire and insulation ranges.

## Lengths

Wire length = shortest bundle path + per-end (termination allowance + insertion depth + backshell entry) + twist take-up + extra length, unless overridden. Twist take-up = path × (√(1 + (π·d/lay)²) − 1). Cut lengths round up to the cut-list step.

Bundle Ø = k·√Σdᵢ², where a cable counts once by its jacket Ø. Tape quantity comes from the bundle circumference and the wrap pitch.

## Roadmap (see FEATURES.md for the full parity list)

1. **System level, next steps:** builds and assembly stages, nested systems, and harnesses linked to external files.
2. **Team server:** add a design server with accounts, a shared library, immutable versions, read-only history, folders, status tags and partner sharing. The app keeps working offline from the local library.
3. **Drawing polish:** rulers, smart guides, page reordering, a loopback drawing, routing constraints, inline cavity renaming, a remap dialog, direct `.xlsx` import, and batch export.
