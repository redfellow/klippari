import Foundation

/// The app a copy is credited to.
public struct SourceApp: Equatable, Sendable {
    public var name: String?
    public var bundleID: String?

    public init(name: String?, bundleID: String?) {
        self.name = name
        self.bundleID = bundleID
    }
}

/// Watches the pasteboard by polling its change count (macOS has no
/// change notification) and records new copies in the history.
///
/// A copy is credited to the app that was in front when it was made, not
/// when the poll saw it: `appDidActivate` polls once more before the
/// switch counts. And while a password app has been in front at any
/// moment since the last timed poll, a new copy is a secret whoever it
/// is credited to, since a masked row costs little and a password shown
/// in clear cannot be taken back.
@MainActor public final class ClipboardMonitor {
    private let pasteboard: PasteboardClient
    private let store: HistoryStore
    private let sourceApp: @MainActor () -> String?
    private let sourceBundleID: @MainActor () -> String?
    private let now: () -> Date
    private var lastSeenCount: Int
    private var timer: Timer?
    /// The app in front as of the last poll or switch.
    private var frontmost: SourceApp
    /// Whether a password app has been in front since the last timed poll.
    private var passwordAppWasFrontmost: Bool

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
        let front = SourceApp(name: sourceApp(), bundleID: sourceBundleID())
        self.frontmost = front
        self.passwordAppWasFrontmost = Secrets.isPasswordApp(front.bundleID)
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

    /// One timed poll. A change is credited to the app in front now.
    public func tick() {
        let front = SourceApp(name: sourceApp(), bundleID: sourceBundleID())
        record(from: front)
        frontmost = front
        passwordAppWasFrontmost = Secrets.isPasswordApp(front.bundleID)
    }

    /// Call when another app comes to the front, before anything else
    /// reads the pasteboard. A change not yet seen was made in the app
    /// that was in front until now, and is credited to it.
    public func appDidActivate(_ app: SourceApp) {
        record(from: frontmost)
        frontmost = app
        if Secrets.isPasswordApp(app.bundleID) { passwordAppWasFrontmost = true }
    }

    private func record(from source: SourceApp) {
        let count = pasteboard.changeCount
        guard count != lastSeenCount else { return }
        lastSeenCount = count
        guard !isPaused, let content = CaptureFilter.accept(pasteboard.read()) else { return }
        let secret = passwordAppWasFrontmost || Secrets.isSecret(content, frontmostBundleID: source.bundleID)
        store.add(content, sourceApp: source.name, secret: secret, now: now())
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
