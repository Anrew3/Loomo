import Foundation

/// Undirected graph of topology nodes connected by segments, weighted by length.
struct TopologyGraph {
    private var adjacency: [EntityID: [(node: EntityID, segment: EntityID, length: Double)]] = [:]

    init(_ h: Harness) {
        for s in h.segments {
            adjacency[s.nodeA, default: []].append((s.nodeB, s.id, s.lengthMM))
            adjacency[s.nodeB, default: []].append((s.nodeA, s.id, s.lengthMM))
        }
    }

    /// Dijkstra. Harness topologies are small (tens to hundreds of nodes), so a linear scan for the minimum is fine.
    func shortestPath(from start: EntityID, to goal: EntityID) -> (segments: [EntityID], length: Double)? {
        if start == goal { return ([], 0) }
        var dist: [EntityID: Double] = [start: 0]
        var prev: [EntityID: (node: EntityID, segment: EntityID)] = [:]
        var open: Set<EntityID> = [start]
        var closed: Set<EntityID> = []

        while let current = open.min(by: { dist[$0]! < dist[$1]! }) {
            if current == goal { break }
            open.remove(current)
            closed.insert(current)
            for edge in adjacency[current] ?? [] where !closed.contains(edge.node) {
                let candidate = dist[current]! + edge.length
                if candidate < dist[edge.node] ?? .infinity {
                    dist[edge.node] = candidate
                    prev[edge.node] = (current, edge.segment)
                    open.insert(edge.node)
                }
            }
        }
        guard let total = dist[goal] else { return nil }
        var segments: [EntityID] = []
        var node = goal
        while let p = prev[node] {
            segments.append(p.segment)
            node = p.node
        }
        return (segments.reversed(), total)
    }
}
