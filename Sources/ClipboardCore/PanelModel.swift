import Foundation
import Observation

/// State of the history panel: the filter, the visible rows and which
/// one Return will paste. Holds no UI code so it can be unit tested.
@MainActor @Observable public final class PanelModel {
    public struct Row: Identifiable, Equatable, Sendable {
        public let id: UUID
        /// 1...9 for the rows Cmd+digit can paste; nil after that.
        public var number: Int?
        public var presentation: RowPresentation
        /// Empty when the source app is unknown.
        public var sourceApp: String
        public var age: String
        /// For a secret, how long until it leaves the history ('9 min').
        public var expiresIn: String?
    }

    public enum EscapeResult: Sendable {
        case clearedQuery, close
    }

    private let store: HistoryStore
    private let now: () -> Date
    /// Rows worked out before, by item. An item keeps its id when it is
    /// copied again as a secret, and its row must then be worked out
    /// again, masked; nothing else about an item changes its row.
    private var presentations: [UUID: (isSecret: Bool, row: RowPresentation)] = [:]

    /// Typing in the panel edits this; the first match becomes selected.
    public var query: String = "" {
        didSet {
            guard query != oldValue else { return }
            rebuild(keepingSelection: false)
        }
    }

    public private(set) var rows: [Row] = []
    public private(set) var selectedID: UUID?

    /// Something wrong that lasts, such as the history not being saved.
    /// Shown in the footer in place of the key hints on every open,
    /// until it is set back to nil; a `notice` shows over it.
    public var warning: String?
    /// Replaces the footer's key hints when set.
    public var notice: String?
    /// Where to go to act on the notice, shown as a link after it.
    public var noticeLink: URL?

    public init(store: HistoryStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        store.onChange = { [weak self] in self?.rebuild(keepingSelection: true) }
        rebuild(keepingSelection: false)
    }

    public var countLabel: String {
        let total = store.items.count
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(rows.count) of \(total)"
        }
        return total == 1 ? "1 item" : "\(total) items"
    }

    /// Whether the selected row is a secret, which Cmd+S can keep as an
    /// ordinary item.
    public var selectionIsSecret: Bool {
        rows.first { $0.id == selectedID }?.expiresIn != nil
    }

    /// Keeps the selected secret as an ordinary item: it is saved, shown
    /// in full and stays selected.
    public func keepSelectedAsOrdinary() {
        guard let selectedID else { return }
        store.keepAsOrdinary(selectedID)
    }

    public var selectedItem: ClipItem? {
        guard let selectedID, rows.contains(where: { $0.id == selectedID }) else { return nil }
        return store.items.first { $0.id == selectedID }
    }

    /// The item behind a visible row; nil for an id that is not visible.
    public func visibleItem(_ id: UUID) -> ClipItem? {
        guard rows.contains(where: { $0.id == id }) else { return nil }
        return store.items.first { $0.id == id }
    }

    /// Called each time the panel is shown.
    public func open() {
        notice = nil
        noticeLink = nil
        query = ""
        rebuild(keepingSelection: false)
    }

    public func moveSelection(by delta: Int) {
        guard let current = rows.firstIndex(where: { $0.id == selectedID }) else {
            selectedID = rows.first?.id
            return
        }
        let target = min(max(current + delta, 0), rows.count - 1)
        selectedID = rows[target].id
    }

    /// The item Cmd+n pastes, counting within the visible (filtered) rows.
    public func item(quickNumber n: Int) -> ClipItem? {
        guard (1...9).contains(n), n <= rows.count else { return nil }
        let id = rows[n - 1].id
        return store.items.first { $0.id == id }
    }

    /// Selects a visible row, as clicking it does. An id that is not
    /// among the visible rows is ignored.
    public func select(_ id: UUID) {
        guard rows.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    public func deleteSelected() {
        guard let index = rows.firstIndex(where: { $0.id == selectedID }) else { return }
        let removed = rows[index].id
        if index + 1 < rows.count {
            selectedID = rows[index + 1].id
        } else if index > 0 {
            selectedID = rows[index - 1].id
        } else {
            selectedID = nil
        }
        store.remove(removed)
    }

    /// Brings ages and secrets' remaining times up to date.
    public func refreshTimes() {
        rebuild(keepingSelection: true)
    }

    public func escape() -> EscapeResult {
        if query.isEmpty { return .close }
        query = ""
        return .clearedQuery
    }

    private func rebuild(keepingSelection: Bool) {
        let items = store.items
        let liveIDs = Set(items.map(\.id))
        presentations = presentations.filter { liveIDs.contains($0.key) }

        let date = now()
        var built: [Row] = []
        for item in items {
            let presentation: RowPresentation
            if let cached = presentations[item.id], cached.isSecret == item.isSecret {
                presentation = cached.row
            } else {
                presentation = RowPresentation(item)
                presentations[item.id] = (item.isSecret, presentation)
            }
            guard presentation.matches(query) else { continue }
            built.append(Row(
                id: item.id,
                number: built.count < 9 ? built.count + 1 : nil,
                presentation: presentation,
                sourceApp: item.sourceApp ?? "",
                age: ageString(from: item.lastUsedAt, now: date),
                expiresIn: item.expiresAt.map { remainingString(until: $0, now: date) }
            ))
        }
        let oldIndex = rows.firstIndex { $0.id == selectedID }
        rows = built

        if keepingSelection, let selectedID, built.contains(where: { $0.id == selectedID }) {
            return
        }
        // The selected row went away by itself (a secret whose time ran
        // out): the row now in its place is selected, as after a delete,
        // so that Return does not paste the newest item instead.
        if keepingSelection, let oldIndex, !built.isEmpty {
            selectedID = built[min(oldIndex, built.count - 1)].id
            return
        }
        selectedID = built.first?.id
    }
}
