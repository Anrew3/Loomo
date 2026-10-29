import Foundation

/// Snapshot undo for a value-type document.
///
/// Edits from bindings (typing, dragging, steppers) arrive as many small changes, so
/// unnamed changes within `coalesceWindow` of each other merge into one step.
/// Named actions such as "Assign W3" always start a new step and are never merged.
public struct UndoHistory<State: Equatable> {
    public struct Entry {
        public var state: State
        public var name: String
    }

    public private(set) var undoStack: [Entry] = []
    public private(set) var redoStack: [Entry] = []
    public var limit: Int
    public var coalesceWindow: TimeInterval

    private var lastChange: Date?
    private var groupOpen = false

    public init(limit: Int = 200, coalesceWindow: TimeInterval = 0.8) {
        self.limit = limit
        self.coalesceWindow = coalesceWindow
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoName: String? { undoStack.last?.name }
    public var redoName: String? { redoStack.last?.name }

    /// Call after each change with the state from before it.
    /// `name == nil` marks an unnamed edit that may merge with the previous one.
    /// Returns true when a new undo step was pushed (false when the change merged into the open step).
    @discardableResult
    public mutating func record(previous: State, name: String?, at now: Date = Date()) -> Bool {
        defer { lastChange = now }
        if name == nil, groupOpen, let last = lastChange, now.timeIntervalSince(last) < coalesceWindow {
            return false  // the open step already holds the state from before this burst of edits
        }
        undoStack.append(Entry(state: previous, name: name ?? "Edit"))
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
        groupOpen = name == nil
        return true
    }

    /// Ends the current burst so the next edit starts a new step (e.g. after saving).
    public mutating func closeGroup() { groupOpen = false }

    /// Returns the state to restore, or nil when there is nothing to undo.
    public mutating func undo(current: State) -> State? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(Entry(state: current, name: entry.name))
        groupOpen = false
        return entry.state
    }

    public mutating func redo(current: State) -> State? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(Entry(state: current, name: entry.name))
        groupOpen = false
        return entry.state
    }

    public mutating func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
        groupOpen = false
        lastChange = nil
    }
}
