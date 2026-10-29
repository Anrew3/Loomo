import Foundation
import Testing
@testable import PartsClient

@Suite struct CoveringSpecTests {
    @Test func heatShrinkDiametersComeFromDistributorSpecs() throws {
        // As TrustedParts returns Raychem RNF-100-1/4-0-SP.
        let json = """
        {"id": "tp-1", "mpn": "RNF-100-1/4-0-SP", "manufacturer": "Raychem", "specs": {
          "Inside Diameter": "6.4 mm (0.252 in)", "Recovered Diameter": "3.2 mm (0.126 in)", "Shrink Ratio": "2:1"}}
        """
        let part = try JSONDecoder().decode(PartSummary.self, from: Data(json.utf8)).partRef
        #expect(part.maxInsulationODMM == 6.4)
        #expect(part.minInsulationODMM == 3.2)
    }

    @Test func inchSpecsConvert() throws {
        let json = #"{"id": "x", "mpn": "S1", "manufacturer": "M", "specs": {"Expanded Diameter": "0.5 in"}}"#
        let part = try JSONDecoder().decode(PartSummary.self, from: Data(json.utf8)).partRef
        #expect(abs((part.maxInsulationODMM ?? 0) - 12.7) < 0.001)
    }
}

@Suite struct DataSourceTests {
    @Test func partsRememberWhichSourceSuppliedEachField() throws {
        let json = """
        {"id": "x", "mpn": "DT06-4S", "manufacturer": "TE", "source": "trustedparts", "description": "Plug",
         "imageURL": "https://img/dt.jpg", "specs": {}, "fieldSources": {"imageURL": "digikey"},
         "sources": ["trustedparts", "digikey"]}
        """
        let part = try JSONDecoder().decode(PartSummary.self, from: Data(json.utf8)).partRef
        #expect(part.dataSources == ["imageURL": "digikey", "description": "trustedparts"])
    }

    @Test func fillingCreditsTheOtherSource() throws {
        func summary(_ json: String) throws -> PartSummary { try JSONDecoder().decode(PartSummary.self, from: Data(json.utf8)) }
        let mouser = try summary(#"{"id": "m", "mpn": "W4S", "manufacturer": "TE", "source": "mouser", "specs": {}, "medianPrice": 0.3}"#)
        let oem = try summary(#"{"id": "o", "mpn": "W4S", "manufacturer": "TE", "source": "oemsecrets", "specs": {}, "imageURL": "https://img/w4s.jpg"}"#)
        let merged = mouser.filling(from: oem)
        #expect(merged.fieldSources?["imageURL"] == "oemsecrets")
        #expect(merged.sources == ["mouser", "oemsecrets"])
        #expect(merged.partRef.dataSources == ["imageURL": "oemsecrets", "medianPrice": "mouser"])
    }
}
