import Foundation

/// Watches the pasteboard by polling its change count (macOS has no
/// change notification) and records new copies in the history.
@MainActor public final class ClipboardMonitor {
    private let pasteboard: PasteboardClient
    private let store: HistoryStore
    private let sourceApp: @MainActor () -> String?
    private let sourceBundleID: @MainActor () -> String?
    private let now: () -> Date
    private var lastSeenCount: Int
    private var timer: Timer?

    /// While paused nothing is recorded, and what was copied during the
    /// pause is not picked up on resume.
    public var isPaused = false {
        didSet {
            if !isPaused { lastSeenCount = pasteboard.changeCount }
        }
    }

    public init(
        pasteboard: PasteboardClient, store: HistoryStore,
        sourceApp: @escaping @MainActor () -> String?,
        sourceBundleID: @escaping @MainActor () -> String? = { nil },
        now: @escaping () -> Date = Date.init
    ) {
        self.pasteboard = pasteboard
        self.store = store
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.now = now
        // Whatever is on the clipboard at launch was not copied on our watch.
        self.lastSeenCount = pasteboard.changeCount
    }

    public func start(interval: TimeInterval = 0.5) {
        stop()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Common modes, so polling continues while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// One poll.
    public func tick() {
        let count = pasteboard.changeCount
        guard count != lastSeenCount else { return }
        lastSeenCount = count
        guard !isPaused, let content = CaptureFilter.accept(pasteboard.read()) else { return }
        let secret = Secrets.isSecret(content, frontmostBundleID: sourceBundleID())
        store.add(content, sourceApp: sourceApp(), secret: secret, now: now())
    }

    /// Puts a history item back on the clipboard without recording that
    /// write as a new copy, and moves the item to the top.
    public func paste(_ item: ClipItem, plainText: Bool) {
        // The history holds lightened content; the full bytes come from disk.
        let full = store.fullContent(for: item.id) ?? item.content
        let content = plainText ? (full.plainTextOnly ?? full.forPasting) : full.forPasting
        lastSeenCount = pasteboard.write(content)
        store.markUsed(item.id, now: now())
    }
}
