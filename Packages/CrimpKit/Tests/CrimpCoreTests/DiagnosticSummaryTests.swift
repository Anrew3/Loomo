import Foundation
import Testing
@testable import CrimpCore

@Suite struct DiagnosticSummaryTests {
    /// Shaped like MXDiagnosticPayload.jsonRepresentation().
    let payload = #"""
    {
      "timeStampBegin": "2026-10-21 15:00:00 +0000",
      "timeStampEnd": "2026-10-21 15:59:00 +0000",
      "crashDiagnostics": [{
        "version": "1.0.0",
        "diagnosticMetaData": {
          "appVersion": "0.4.0", "exceptionType": 6, "signal": 5, "terminationReason": "",
          "objectiveCexceptionReason": {"composedMessage": "The window has been marked as needing another Update Constraints pass"}
        },
        "callStackTree": {
          "callStackPerThread": true,
          "callStacks": [{
            "threadAttributed": true,
            "callStackRootFrames": [{
              "binaryName": "AppKit", "offsetIntoBinaryTextSegment": 100,
              "subFrames": [{ "binaryName": "Loomo", "offsetIntoBinaryTextSegment": 4242, "subFrames": [] }]
            }]
          }]
        }
      }],
      "hangDiagnostics": [{
        "diagnosticMetaData": { "appVersion": "0.4.0", "hangDuration": "3.2 sec" },
        "callStackTree": { "callStacks": [] }
      }]
    }
    """#

    @Test func readsCrashesAndHangs() throws {
        let s = DiagnosticSummary.summaries(fromPayload: Data(payload.utf8))
        #expect(s.count == 2)
        let crash = try #require(s.first { $0.kind == .crash })
        #expect(crash.detail.contains("EXC_BREAKPOINT"))
        #expect(crash.detail.contains("SIGTRAP"))
        #expect(crash.detail.contains("Update Constraints"))
        #expect(crash.appFrames == ["Loomo +4242"])
        #expect(crash.appVersion == "0.4.0")
        #expect(crash.date != nil)
        #expect(s.first { $0.kind == .hang }?.detail == "Not responding for 3.2 sec")
    }

    @Test func ignoresJunk() {
        #expect(DiagnosticSummary.summaries(fromPayload: Data("nope".utf8)).isEmpty)
        #expect(DiagnosticSummary.summaries(fromPayload: Data("{}".utf8)).isEmpty)
    }
}
