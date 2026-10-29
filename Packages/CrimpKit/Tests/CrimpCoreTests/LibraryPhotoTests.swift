import CrimpCore
import Foundation
import Testing

@Suite struct LibraryPhotoTests {
    @Test func customPhotoBeatsDistributorPhoto() {
        var part = PartRef(mpn: "502351-0801", manufacturer: "Molex")
        part.imageURL = URL(string: "https://example.com/dist.jpg")
        var entry = LibraryPart(part: part, category: "connector")
        var lib = PartLibrary(parts: [entry])
        // A design's copy of the part (punctuation differs) finds the library entry.
        let inDesign = PartRef(mpn: "5023510801", manufacturer: "Molex Inc")
        #expect(lib.photoURL(for: inDesign) == nil)
        #expect(lib.photoURL(for: part) == part.imageURL)
        entry.customPhotoURL = URL(fileURLWithPath: "/tmp/mine.png")
        lib.upsert(entry)
        #expect(lib.photoURL(for: inDesign) == entry.customPhotoURL)
        #expect(lib.photoURL(for: part) == entry.customPhotoURL)
    }
}
