import Foundation

/// Merging a parts library with a shared copy (the CloudKit team library). Newest change wins, per part;
/// deletions travel as dated tombstones so a part removed on one Mac disappears on the others.
public enum LibrarySync {
    /// One part as stored in the shared copy: its latest version, or nil when it was deleted.
    public struct Item: Equatable, Sendable {
        public var id: String
        public var modifiedAt: Date
        public var part: LibraryPart?

        public init(id: String, modifiedAt: Date, part: LibraryPart?) {
            self.id = id
            self.modifiedAt = modifiedAt
            self.part = part
        }
    }

    /// What a sync does: the library to keep locally and the items to upload.
    public struct Plan: Equatable, Sendable {
        public var library: PartLibrary
        public var upload: [Item]
    }

    /// Dates the parts that are new or changed since `old` and records the ones that were removed.
    public static func stamp(_ new: PartLibrary, comparedTo old: PartLibrary, now: Date = Date()) -> PartLibrary {
        var out = new
        let before = Dictionary(old.parts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in out.parts.indices {
            let id = out.parts[i].id
            if let prior = before[id], sameContent(prior, out.parts[i]) {
                out.parts[i].modifiedAt = prior.modifiedAt
            } else {
                out.parts[i].modifiedAt = now
            }
            out.deleted?[id] = nil
        }
        let remaining = Set(out.parts.map(\.id))
        for id in before.keys where !remaining.contains(id) {
            out.deleted = out.deleted ?? [:]
            out.deleted?[id] = now
        }
        if out.deleted?.isEmpty == true { out.deleted = nil }
        return out
    }

    /// The library as sync items: every part plus every tombstone.
    public static func items(of library: PartLibrary) -> [Item] {
        library.parts.map { Item(id: $0.id, modifiedAt: $0.modifiedAt ?? .distantPast, part: $0) }
            + (library.deleted ?? [:]).map { Item(id: $0.key, modifiedAt: $0.value, part: nil) }
    }

    /// Combines the local library with the shared copy. For each part the newer side wins; local wins
    /// are uploaded, remote wins are applied locally.
    public static func merge(local: PartLibrary, remote: [Item]) -> Plan {
        var library = local
        var upload: [Item] = []
        let localItems = Dictionary(items(of: local).map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.modifiedAt >= b.modifiedAt ? a : b })
        let remoteItems = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.modifiedAt >= b.modifiedAt ? a : b })
        for id in Set(localItems.keys).union(remoteItems.keys).sorted() {
            switch (localItems[id], remoteItems[id]) {
            case let (l?, nil):
                upload.append(l)
            case let (nil, r?):
                apply(r, to: &library)
            case let (l?, r?):
                if r.modifiedAt > l.modifiedAt { apply(r, to: &library) } else if l.modifiedAt > r.modifiedAt { upload.append(l) }
            case (nil, nil):
                break
            }
        }
        return Plan(library: library, upload: upload)
    }

    private static func apply(_ item: Item, to library: inout PartLibrary) {
        if var part = item.part {
            part.modifiedAt = item.modifiedAt
            if let i = library.parts.firstIndex(where: { $0.id == item.id }) { library.parts[i] = part } else { library.parts.append(part) }
            library.deleted?[item.id] = nil
            if library.deleted?.isEmpty == true { library.deleted = nil }
        } else {
            library.parts.removeAll { $0.id == item.id }
            library.deleted = library.deleted ?? [:]
            library.deleted?[item.id] = item.modifiedAt
        }
    }

    private static func sameContent(_ a: LibraryPart, _ b: LibraryPart) -> Bool {
        var a = a, b = b
        a.modifiedAt = nil
        b.modifiedAt = nil
        return a == b
    }
}
