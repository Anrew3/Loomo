# Loomo vs. RapidHarness: feature parity

This checklist follows the feature list on rapidharness.com. Status key: ✅ done · 🟡 partial · ⬜ not yet.

## Harness modelling
| Feature | Status | Notes |
|---|---|---|
| Connectors with contacts, wire seals, sealing plugs, backshells, boots | ✅ | Per-cavity terminal, seal and plug; accessories with quantities |
| Named cavities | ✅ | Rename any cavity in its side panel (A, B, 30, 87a…); wire ends, faces and accepted deviations follow |
| Pigtail connectors | ✅ | The pre-wired lead length is subtracted from the harness wire |
| Cables with shields, drain wires, twisted pairs | ✅ | Jacket Ø counts once in the bundle; jacket length and strip are in the cut list |
| Multi-wire twists | ✅ | Any number of wires; lay length drives the twist take-up |
| Splices, ferrules, ring, spade and quick-connect terminals | ✅ | |
| In-line diodes and resistors | ✅ | Splice kinds with a value |
| Coverings: sleeving, braid, tape, heat shrink, convoluted tube | ✅ | Tape: half-lap, spiral or spot, with material calculated |
| Bundle diameters and covering fit checks | ✅ | Too-small inner Ø is an error; too-loose minimum Ø is a warning |
| AWG, mm² and custom wire sizes | ✅ | |
| Device / ICD pin-list import | ✅ | CSV with Pin and Signal columns |
| One "Place Component" for every part type | ✅ | Connector, fuse holder, relay or relay socket, terminals, loose pins: detected from the distributor category and description, with a Place-as override |
| Fuse boxes and relay sockets | ✅ | Fuses, relays, jumpers, diodes and breakers plug in across cavities with a rating and part; fuses and jumpers join nets; 4/5-pin relays get ISO 30/85/86/87/87a names |
| Loose pins (no housing) | ✅ | Terminated pins to be pinned into a factory connector later; terminals in the BOM, no housing |
| In-line mated pairs | ✅ | C5F/C5M side by side with a mating mark; cavities pass through by label; gender and cavity checks |
| Pass-through (T-harness) wiring | ✅ | Select two connectors ▸ Pass-Through Wires: one wire per matching cavity, carrying its signal |
| Accessory types (TPA, CPA, wire lock, lid, lid lock, backshell…) | ✅ | Each is its own BOM type with a quantity per connector |
| Extended colours and two-colour codes | ✅ | Adds light/dark blue and green, tan and beige; "VT GY" or "VT/GY" |
| Own connector pictures with cropping | ✅ | Right-click ▸ Change Picture… then crop (for OEM connectors); wins over the part photo |

## Wire lengths
| Feature | Status | Notes |
|---|---|---|
| Lengths from the topology (shortest bundle path) | ✅ | |
| Connector insertion depth and backshell entry | ✅ | Added at each end |
| Strip lengths for contacts, ferrules and splices in tables and cut lists | ✅ | Stored on the terminal part |
| Review and override, one at a time or in bulk | ✅ | Wires page bulk actions |
| Extra length per connection | ✅ | |
| Default loopback length shown on the drawing | ⬜ | |
| Length totals in the BOM | ✅ | |

## Drawing
| Feature | Status | Notes |
|---|---|---|
| Automatic real-time harness drawing | ✅ | The canvas and the PDF share one renderer |
| To-scale 1:1 formboard | ✅ | Edge-to-edge sheets (no border; crop marks in the margin, targets across seams, optional glue overlap, assembly map) or one large plotter sheet |
| Connection tables on the drawing | ✅ | Beside each connector and splice: pin, conductor (Name.Colour), size, destination, contact, twisted with; placed clear of bundles, draggable |
| BOM item numbers on the drawing | ✅ | "[3]" after designators, balloons on coverings |
| Frames and sticky notes | ✅ | Titled frames round sub-harnesses (dashed for options/variants); yellow callout notes |
| Opens fitted and centred | ✅ | F fits and centres again |
| Shapes, arrows, text and images with front/back order | ✅ | |
| Rounded bends; bundle width scaled to Ø | ✅ | |
| Highlight a wire, cable or twist route in its colour | ✅ | |
| Metric/imperial units and snap grid | ✅ | Imperial lengths over a foot read as feet and inches (9 ft 5 in) |
| Rulers and smart alignment guides | ✅ | Rulers toggle on the view bar; dragging a node snaps to other nodes with a pink guide line |
| Numbered note flags and bundle labels on the drawing | ✅ | |

## Manufacturing outputs
| Feature | Status | Notes |
|---|---|---|
| Harness drawing, optionally to scale | ✅ | |
| BOM: sort, edit quantity, exclude, manual lines | ✅ | |
| Connection (connector) tables and wiring table | ✅ | Browsable Connections page with the mating face beside each table and linked destinations; splice tables too |
| Professional drawing sheets | ✅ | Zoned border, sheet heading, full title block; BOM, notes, revisions and coverings legend beside the drawing |
| Cut list with strip lengths, terminals, seals and markers | ✅ | |
| Tools list (crimp tools from terminals, plus fixtures and equipment) | ✅ | |
| Notes and revisions on the drawing or as tables | ✅ | |
| Bundle and wire label listing; label text synced to connectors | ✅ | |
| Netlist | ✅ | Harness level (nets through splices) |
| PDF and Excel (.xlsx) export, and printing | ✅ | Also WireViz YAML |
| Title block with logo, company, drawing number, sheet sizes A4–A0, Letter, Tabloid, ARCH D | ✅ | |
| Choose which pages go in the PDF | ✅ | |
| Reorder pages by dragging | ⬜ | Order is fixed |
| Batch export across many designs | ⬜ | |

## Parts library
| Feature | Status | Notes |
|---|---|---|
| Distributor search: TrustedParts, Mouser, Digi-Key, OEMsecrets, Octopart | ✅ | Automatic fallback with budgets and cooldowns; Digi-Key and Octopart need keys; Mouser photos load through a hidden web view (Mouser blocks plain downloads) |
| Parts library database | ✅ | Every answer merged per part number; known parts cost no API calls; missing photos/datasheets filled source by source; per-field source icons in the app |
| Live price and stock refresh for the BOM | ✅ | Batched; avoids spending Octopart quota |
| Generic parts replaced later | ✅ | Flagged by the rule checker; "Replace Everywhere" |
| Private library: create, modify, import and export | ✅ | Stored in Application Support as JSON |
| Design configurations (related contacts, seals, plugs, wedgelocks, backshells, boots, tools) | ✅ | "Apply Design Configuration" on a connector |
| Internal part numbers and approved alternates | ✅ | Shown in the BOM and searchable |
| Library housekeeping: duplicates | ✅ | |
| Where-used, unused and missing parts | 🟡 | Engine functions exist; only "where used" (in Replace Everywhere) and duplicates have UI |
| Team library sharing | ⬜ | Needs a server (see the roadmap) |

## Power tools
| Feature | Status | Notes |
|---|---|---|
| Rule checker that jumps to the item | ✅ | Wire range, seal range, splice rating, sealing, plugs, shared cavities, routes, twists, cables, labels, generic parts, duplicate designators |
| Bundle inspection (contents of each segment) | ✅ | Segment inspector |
| Configurable bundle routing | 🟡 | Shortest path only; no forced or pinned routes yet |
| Twist and untwist; swap a wire's part | ✅ | |
| Copy and paste harness sections including wires | ✅ | ⌥⌘C / ⌥⌘V |
| Remap connections when a design changes | ✅ | Right-click a connector ▸ Remap Connections…: move every wire to another connector, pin by pin, with a preview of unmatched ends |
| Switch terminal types everywhere | ✅ | Replace Everywhere |
| Import wire lists / from-to lists | ✅ | CSV/TSV saved from Excel; direct .xlsx import is not yet supported |
| Undo and redo with a history list | ✅ | Native Edit menu; each step is named |
| Pinout editor (click or drag wire ends into cavities, swap cavities) | ✅ | Mating-face or wire-side view; Grid or Face display |
| Connector face drawings with colour-coded wires | ✅ | Generated in-house: presets, distributor rows/pitch, or traced over a datasheet image/PDF page; shared per part in the library; PDF "Connector faces" page and SVG export |
| Cavity count, rows, pitch and gender from distributor data | ✅ | Majority vote across distributor descriptions; editable before placing; "Refresh from Distributors" fixes placed connectors |
| 3D connector models | ⬜ | Needs STEP import (CAD kernel); 2D faces cover drawings today |
| Right-click menus everywhere on the drawing | ✅ | Empty canvas, connector, splice, breakout/clip, bundle, label, annotation, multi-selection; also connector/wire tables and the system diagram |
| Multi-select, box-select, move, duplicate and delete groups | ✅ | ⇧-click, drag a rectangle, drag the selection, ⌘D, ⌫, ⌘C/⌘X/⌘V, arrow-key nudge, align |
| Keyboard shortcuts | ✅ | One-shot keys insert at the pointer (C R S J K W B L T A X I); the mouse never changes mode. F zoom to fit, ? for the full list (Help ▸ Keyboard Shortcuts, ⌘/) |
| Unified mouse + Insert menu | ✅ | Click selects, drag moves or box-selects, ⌥-drag node→node draws a bundle; everything is added from right-click, the Insert menu or a key |
| Wires to and from splices | ✅ | New Wire sheet: either end can be a connector cavity or a splice |
| Double crimp (two wires in one terminal) | ✅ | Per-cavity flag; checked against the terminal's max wire size; split-colour cavity on the face drawing |
| Cross-source part data | ✅ | /parts/detail fills a part from each source in turn until it has a photo, datasheet and description |
| iCloud Drive projects | ✅ | New projects are created in iCloud Drive ▸ Loomo and autosave (at least every 30 s); they appear on the welcome window of every Mac with the same Apple ID |
| Claude and other AI clients (MCP) | ✅ | `crimp mcp`: an MCP server whose tools edit the harness open in Loomo live (one undo step each), or a file when Loomo is closed; Settings ▸ AI clients connects Claude Desktop and Claude Code |
| Harness assistant (on-device AI) | ✅ | Harness ▸ Assistant (⌥⌘A): Apple's on-device model reads and edits the harness through the same operations as `crimp`; ⌘Z undoes its edits; nothing leaves the Mac |
| Welcome window | ✅ | Xcode-style launch window: new harness/system/sample, open existing, recent projects with drawing thumbnails; Window ▸ Welcome (⇧⌘1) |
| Settings in iCloud | ✅ (needs iCloud signing) | Preferences follow the iCloud account via key-value storage; API keys stay in each Mac's Keychain |
| Tests, CI and profiling | ✅ | Unit + performance tests, XCUITest suite, Xcode Cloud scripts, Instruments signposts; analysis is 10× faster on large harnesses |
| Crash and hang reports (MetricKit) | ✅ | Reports from macOS are kept in ~/Library/Logs/Loomo/Diagnostics; Help ▸ Diagnostic Reports summarises them |
| Tips (TipKit) | ✅ | One-time tips for right-click/keys, ⌥-drag bundles, moving photos and the assistant; Help ▸ Show Tips Again |
| Charts (Swift Charts) | ✅ | BOM cost and pieces by category, wire to cut by size, bundle diameters in the overview; hideable |
| Team parts library (CloudKit) | ✅ (needs iCloud signing) | Sync between Macs and share with teammates; newest change per part wins, deletions and custom photos sync |
| Shortcuts, Spotlight and Siri (App Intents) | ✅ | Check Harness, Summarize Harness, Export Drawing Set (PDF), Export Manufacturing Workbook, Export WireViz YAML; work on files without opening a window |
| Quick Look in Finder | ✅ | Thumbnails show the harness drawing; Space previews drawing, faces, wiring table and BOM (PDF) |
| Custom library photos | ✅ | Parts Library ▸ Photo: choose or drop an image; overrides the distributor photo everywhere |
| Connector designators C1, C2… | ✅ | Harness ▸ Renumber Connectors |
| Placing a connector opens part search (library + Octopart) with photos | ✅ | Positions and contact gender come from the part's specs; library design configurations apply automatically |
| Part photos | ✅ | Octopart's best image, cached on disk; shown in search, inspector, pinout editor, on the drawing and in the PDF harness drawing (toggle "Photos") |

## System-level design
| Feature | Status | Notes |
|---|---|---|
| System projects (`.loomosys`) holding several harnesses and devices | ✅ | Harnesses are stored in the project and edited in place with the full harness editor; import/export `.loomo` |
| Devices with connectors and pin lists | ✅ | Pin-list (ICD) CSV import; "Mating Connector for…" creates the opposite-gender half with the same pins and signals |
| Mated connectors (harness ⇄ device, harness ⇄ harness in-line) | ✅ | Drag between connectors on the system diagram; pin maps for non-1:1 mates; Auto-Mate by name |
| System diagram | ✅ | Devices and harness blocks with ports and mate links; drag to arrange; nets highlight when traced |
| Signal tracing across harnesses | ✅ | Hop-by-hop through wires, splices and mates; click a wire to open it in its harness |
| System netlist | ✅ | Nets named from device pin signals; open-circuit and short detection |
| System BOM | ✅ | Every harness × its quantity, plus device parts, with a per-harness breakdown |
| System rule checker | ✅ | Mate gender, missing partner pins, double mates, unmated connectors, shorts between device signals, a split signal (open circuit), signal-name mismatches, plus every harness's own errors and warnings |
| System PDF and Excel | ✅ | Diagram, netlist, BOM, mates and rule check, followed by each harness's drawing set |
| Builds and assembly stages | ⬜ | |
| A system reused inside another system (hierarchy) | ⬜ | Harnesses are reused by duplicating or importing; nested systems are not supported yet |
| Harness designs linked to external files (update everywhere) | ⬜ | Harnesses are embedded copies today |

## Teams, version control, collaboration, cloud
| Feature | Status | Notes |
|---|---|---|
| Version history | 🟡 | Local: macOS autosave/Versions plus the revision table. No server-side history |
| Read-only historical copies; immutable versions; recycle bin | ⬜ | |
| Team folders, status tags, partner sharing and permissions | ⬜ | Needs a design server with accounts |
| Cloud storage and sign-in from any machine | ⬜ | |
