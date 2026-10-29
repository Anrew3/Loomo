@testable import CrimpCore
import Foundation

// Fixtures for the tests: a small harness and a system built around it. They used to ship in the app as
// samples; now they live only here.

extension Harness {
    /// A small sensor harness: a 4-way Deutsch DT plug feeding two sealed sensors,
    /// with a shared ground spliced at a breakout. Part numbers marked SAMPLE are placeholders.
    static var sample: Harness {
        var h = Harness(name: "Sensor Harness", revision: "A")

        h.nodes = [
            TopologyNode(id: "N1", kind: .connector, label: "C1", position: Point2D(80, 220)),
            TopologyNode(id: "N2", kind: .splice, label: "SP1", position: Point2D(340, 220)),
            TopologyNode(id: "N3", kind: .breakout, label: "BO1", position: Point2D(500, 220)),
            TopologyNode(id: "N4", kind: .connector, label: "C2", position: Point2D(700, 100)),
            TopologyNode(id: "N5", kind: .connector, label: "C3", position: Point2D(700, 340)),
            TopologyNode(id: "N6", kind: .connector, label: "C4", position: Point2D(560, 420)),
        ]
        h.segments = [
            Segment(id: "S1", nodeA: "N1", nodeB: "N2", lengthMM: 600),
            Segment(id: "S2", nodeA: "N2", nodeB: "N3", lengthMM: 150),
            Segment(id: "S3", nodeA: "N3", nodeB: "N4", lengthMM: 300),
            Segment(id: "S4", nodeA: "N3", nodeB: "N5", lengthMM: 450),
            Segment(id: "S5", nodeA: "N3", nodeB: "N6", lengthMM: 250),
        ]

        let socket = PartRef(mpn: "0462-201-16141", manufacturer: "TE Connectivity / Deutsch",
                             description: "DT socket contact, 16–20 AWG", stripLengthMM: 6, crimpTool: "HDT-48-00",
                             minWireMM2: 0.5, maxWireMM2: 1.5)
        let dtPlug = PartRef(mpn: "114017", manufacturer: "TE Connectivity / Deutsch",
                             description: "DT sealing plug, size 16")
        var x1 = Connector(id: "C1", name: "Main", part: PartRef(mpn: "DT06-4S", manufacturer: "TE Connectivity / Deutsch",
                                                                 description: "DT plug, 4-way"),
                           gender: .female, sealed: false, nodeID: "N1", cavityCount: 4,
                           accessories: [Accessory(kind: "wedgelock", part: PartRef(mpn: "W4S", manufacturer: "TE Connectivity / Deutsch",
                                                                                     description: "DT wedgelock, 4-way plug"))])
        for i in 0..<3 { x1.cavities[i].terminal = socket }
        x1.cavities[3].plug = dtPlug
        x1.cavities[0].signal = "5V"
        x1.cavities[1].signal = "GND"
        x1.cavities[2].signal = "SIG_A"

        let sensorTerm = PartRef(mpn: "SAMPLE-TERM-0.5", manufacturer: "Sample", description: "Sealed series socket, 0.35–0.75 mm²")
        let sensorSeal = PartRef(mpn: "SAMPLE-SEAL-1.4", manufacturer: "Sample", description: "Wire seal, insulation Ø1.2–1.6")
        func sensor(_ id: EntityID, node: EntityID) -> Connector {
            var c = Connector(id: id, name: "Sensor", part: PartRef(mpn: "SAMPLE-3W-HSG", manufacturer: "Sample",
                                                                   description: "3-way sealed sensor housing"),
                              gender: .female, sealed: true, nodeID: node, cavityCount: 3)
            for i in 0..<3 {
                c.cavities[i].terminal = sensorTerm
                c.cavities[i].seal = sensorSeal
            }
            return c
        }
        var ring = Connector(id: "C4", name: "Chassis ground", kind: .ringTerminal, gender: .female, nodeID: "N6", cavityCount: 1)
        ring.cavities[0].terminal = .generic("M6 ring terminal, 0.5–1.5 mm²")
        h.connectors = [x1, sensor("C2", node: "N4"), sensor("C3", node: "N5"), ring]

        h.splices = [Splice(id: "SP1", kind: .ultrasonic,
                            heatShrink: PartRef(mpn: "SAMPLE-HS-SPLICE", manufacturer: "Sample", description: "Adhesive-lined splice heat shrink"),
                            nodeID: "N2")]

        h.wires = [
            Wire(id: "W1", signal: "5V", size: .awg(20), color: WireColor("RD"), from: .pin(connector: "C1", cavity: "1"), to: .pin(connector: "C2", cavity: "1")),
            Wire(id: "W2", signal: "GND", size: .awg(18), color: WireColor("BK"), from: .pin(connector: "C1", cavity: "2"), to: .splice("SP1")),
            Wire(id: "W3", signal: "GND", size: .awg(20), color: WireColor("BK"), from: .splice("SP1"), to: .pin(connector: "C2", cavity: "2")),
            Wire(id: "W4", signal: "GND", size: .awg(20), color: WireColor("BK"), from: .splice("SP1"), to: .pin(connector: "C3", cavity: "2")),
            Wire(id: "W5", signal: "SIG_A", size: .awg(20), color: WireColor("GN", stripe: "WH"), from: .pin(connector: "C1", cavity: "3"), to: .pin(connector: "C3", cavity: "3")),
            Wire(id: "W6", signal: "GND", size: .awg(18), color: WireColor("BK"), from: .splice("SP1"), to: .pin(connector: "C4", cavity: "1"),
                 markerText: "GND"),
        ]

        h.coverings = [
            Covering(id: "CV1", kind: .convolutedTube,
                     part: PartRef(mpn: "SAMPLE-CONV-10", manufacturer: "Sample", description: "Split convoluted tube, 10 mm ID"),
                     segmentIDs: ["S1", "S2"], innerDiameterMM: 10, colorHex: "#222222"),
            Covering(id: "CV2", kind: .tape,
                     part: PartRef(mpn: "SAMPLE-TAPE-19", manufacturer: "Sample", description: "PET cloth harness tape, 19 mm"),
                     segmentIDs: ["S3", "S4"], tape: TapeWrap(style: .halfLap, widthMM: 19), colorHex: "#5A6B7C"),
        ]
        h.labels = [
            BundleLabel(id: "L1", placement: .connector("C1")),
            BundleLabel(id: "L2", placement: .segment("S1", offsetMM: 100), text: "SENSOR HARNESS"),
        ]
        h.notes = [
            DrawingNote(id: 1, text: "All dimensions in mm, tolerance ±10 mm per segment."),
            DrawingNote(id: 2, text: "Ultrasonic splice; cover with adhesive heat shrink.", attachedTo: ["SP1"]),
        ]
        h.revisions = [Revision(rev: "A", date: "2026-10-20", description: "Initial release", author: "Loomo")]
        h.titleBlock.company = "Loomo"
        h.titleBlock.drawingNumber = "CL-0001"
        h.titleBlock.drawnBy = "Loomo"
        return h
    }
}

extension SystemProject {
    /// A two-harness, two-device sample: an ECU, a body harness, a sensor harness joined by an in-line connector, and a sensor.
    static var sample: SystemProject {
        var p = SystemProject(name: "Sensor System", revision: "A")
        p.titleBlock.company = "Loomo"
        p.titleBlock.drawingNumber = "CL-S001"

        var ecu = Device(id: "ECU", name: "Engine controller", position: Point2D(40, 60))
        var j1 = DeviceConnector(id: "J1", name: "Main", gender: .male, pinCount: 4)
        j1.pins[0].signal = "5V"; j1.pins[1].signal = "GND"; j1.pins[2].signal = "SIG_A"
        ecu.connectors = [j1]
        var sensor = Device(id: "SNS", name: "Pressure sensor", position: Point2D(760, 300))
        var sj = DeviceConnector(id: "J1", name: "Sensor", gender: .male, pinCount: 3)
        sj.pins[0].signal = "5V"; sj.pins[1].signal = "GND"; sj.pins[2].signal = "SIG_A"
        sensor.connectors = [sj]
        p.devices = [ecu, sensor]

        // H1: the sample harness from ECU to an in-line connector C2 and a second sensor C3.
        var body = Harness.sample
        body.name = "Body harness"
        // H2: a short jumper from the in-line connector to the remote sensor.
        var jumper = Harness(name: "Sensor jumper")
        jumper.nodes = [TopologyNode(id: "N1", kind: .connector, label: "P1", position: Point2D(100, 200)),
                        TopologyNode(id: "N2", kind: .connector, label: "P2", position: Point2D(500, 200))]
        jumper.segments = [Segment(id: "S1", nodeA: "N1", nodeB: "N2", lengthMM: 800)]
        var p1 = Connector(id: "P1", name: "Inline", gender: .male, sealed: false, nodeID: "N1", cavityCount: 3)
        for i in 0..<3 { p1.cavities[i].terminal = .generic("Pin contact, 0.5 mm²") }
        var p2 = Connector(id: "P2", name: "Sensor", gender: .female, sealed: false, nodeID: "N2", cavityCount: 3)
        for i in 0..<3 { p2.cavities[i].terminal = .generic("Socket contact, 0.5 mm²") }
        jumper.connectors = [p1, p2]
        jumper.wires = [
            Wire(id: "W1", signal: "5V", size: .awg(20), color: WireColor("RD"), from: .pin(connector: "P1", cavity: "1"), to: .pin(connector: "P2", cavity: "1")),
            Wire(id: "W2", signal: "GND", size: .awg(20), color: WireColor("BK"), from: .pin(connector: "P1", cavity: "2"), to: .pin(connector: "P2", cavity: "2")),
        ]
        p.harnesses = [HarnessInstance(id: "H1", harness: body, position: Point2D(320, 40)),
                       HarnessInstance(id: "H2", harness: jumper, quantity: 1, position: Point2D(420, 330))]
        p.mates = [
            Mate(id: "M1", a: .harness("H1", connector: "C1"), b: .device("ECU", connector: "J1")),
            Mate(id: "M2", a: .harness("H1", connector: "C2"), b: .harness("H2", connector: "P1")),
            Mate(id: "M3", a: .harness("H2", connector: "P2"), b: .device("SNS", connector: "J1")),
        ]
        return p
    }
}
