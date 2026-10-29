import Foundation
import Testing
@testable import CrimpCore

@Suite struct LibrarySyncTests {
    let t0 = Date(timeIntervalSince1970: 1_000)
    let t1 = Date(timeIntervalSince1970: 2_000)
    let t2 = Date(timeIntervalSince1970: 3_000)

    func part(_ mpn: String, notes: String = "") -> LibraryPart {
        LibraryPart(part: PartRef(mpn: mpn, manufacturer: "TE"), category: "connector", notes: notes)
    }

    @Test func stampDatesOnlyWhatChanged() {
        var old = PartLibrary(parts: [part("A"), part("B")])
        old.parts[0].modifiedAt = t0
        old.parts[1].modifiedAt = t0
        var new = old
        new.parts[1].notes = "edited"
        new.parts.append(part("C"))
        new.parts.removeAll { $0.part.mpn == "A" }
        let stamped = LibrarySync.stamp(new, comparedTo: old, now: t1)
        #expect(stamped.parts.first { $0.part.mpn == "B" }?.modifiedAt == t1)
        #expect(stamped.parts.first { $0.part.mpn == "C" }?.modifiedAt == t1)
        #expect(stamped.deleted?[old.parts[0].id] == t1)
        // Unchanged parts keep their date.
        let again = LibrarySync.stamp(stamped, comparedTo: stamped, now: t2)
        #expect(again.parts.allSatisfy { $0.modifiedAt == t1 })
    }

    @Test func newestSideWinsAndDeletionsTravel() {
        var a = part("A", notes: "local"); a.modifiedAt = t2
        var b = part("B", notes: "local"); b.modifiedAt = t0
        var local = PartLibrary(parts: [a, b])
        local.deleted = [part("D").id: t1]
        let remote = [
            LibrarySync.Item(id: a.id, modifiedAt: t1, part: part("A", notes: "remote")),   // older: keep local, upload
            LibrarySync.Item(id: b.id, modifiedAt: t1, part: part("B", notes: "remote")),   // newer: take remote
            LibrarySync.Item(id: part("C").id, modifiedAt: t1, part: part("C")),           // new remotely: add
            LibrarySync.Item(id: part("D").id, modifiedAt: t0, part: part("D")),           // deleted here later: upload tombstone
        ]
        let plan = LibrarySync.merge(local: local, remote: remote)
        #expect(plan.library.parts.first { $0.part.mpn == "A" }?.notes == "local")
        #expect(plan.library.parts.first { $0.part.mpn == "B" }?.notes == "remote")
        #expect(plan.library.parts.contains { $0.part.mpn == "C" })
        #expect(!plan.library.parts.contains { $0.part.mpn == "D" })
        #expect(Set(plan.upload.map(\.id)) == [a.id, part("D").id])
        #expect(plan.upload.first { $0.id == part("D").id }?.part == nil)
    }

    @Test func remoteDeletionRemovesLocalPart() {
        var a = part("A"); a.modifiedAt = t0
        let plan = LibrarySync.merge(local: PartLibrary(parts: [a]), remote: [LibrarySync.Item(id: a.id, modifiedAt: t1, part: nil)])
        #expect(plan.library.parts.isEmpty)
        #expect(plan.library.deleted?[a.id] == t1)
        #expect(plan.upload.isEmpty)
    }

    @Test func mergingTwiceChangesNothing() {
        var a = part("A"); a.modifiedAt = t1
        let local = PartLibrary(parts: [a])
        let first = LibrarySync.merge(local: local, remote: [])
        let second = LibrarySync.merge(local: first.library, remote: first.upload)
        #expect(second.upload.isEmpty)
        #expect(second.library == first.library)
    }
}
