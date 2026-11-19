import AppKit
import ClipboardCore

/// The enlarged image beside the panel. It is a window of its own,
/// attached to the panel so it moves with it, placed so it never covers
/// the card, and it never takes clicks or focus.
///
/// Previews are made in the background ahead of time and kept, so one
/// appears the moment it is asked for. If one is not ready yet, the
/// item's stored thumbnail stands in until it is.
@MainActor final class ImagePreviewController {
    /// Pixels on the longer side: enough for the largest preview on a
    /// Retina screen.
    static let maxPixel = 640
    /// How many previews are kept, and made ahead of time.
    static let cacheLimit = 20

    private let storage: ItemStorage
    private let window: NSPanel
    private let imageView = NSImageView()
    private var cache: [UUID: NSImage] = [:]
    /// Oldest first, for dropping previews beyond the limit.
    private var cacheOrder: [UUID] = []
    private var loading: Set<UUID> = []
    /// Items no preview could be made for, so they are not tried again
    /// on every change of the list. An item's content never changes.
    private var failed: Set<UUID> = []
    private var shownID: UUID?

    init(storage: ItemStorage) {
        self.storage = storage
        window = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.isReleasedWhenClosed = false

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 10
        imageView.layer?.masksToBounds = true
        imageView.layer?.borderWidth = 1
        imageView.layer?.borderColor = NSColor(white: 0.5, alpha: 0.35).cgColor
        window.contentView = imageView
    }

    /// Shows the item's image beside `card`, centred on its row's middle
    /// when known, or hides the preview when there is no image or no room.
    func show(_ item: ClipItem?, beside card: NSRect, rowMidY: CGFloat?, in visible: NSRect, parent: NSWindow) {
        guard let item, !item.isSecret, let info = item.imageInfo,
              let frame = PreviewPlacement.frame(
                  imageSize: CGSize(width: info.width, height: info.height), card: card,
                  rowMidY: rowMidY, in: visible
              )
        else {
            hide()
            return
        }
        shownID = item.id
        if let ready = cache[item.id] {
            imageView.image = ready
        } else {
            imageView.image = storage.thumbnail(for: item.id).flatMap(NSImage.init(data:))
            load(item.id)
        }
        window.setFrame(frame, display: true)
        if window.parent !== parent {
            window.parent?.removeChildWindow(window)
            parent.addChildWindow(window, ordered: .above)
        }
        window.orderFront(nil)
    }

    func hide() {
        shownID = nil
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
    }

    /// Makes previews for these items in the background, so they show at
    /// once when selected or hovered.
    func preload(_ ids: some Sequence<UUID>) {
        let wanted = Array(ids)
        // Forget items no longer listed: their failures, and their
        // decrypted previews, so a deleted or cleared image does not
        // stay in memory.
        let listed = Set(wanted)
        failed.formIntersection(listed)
        cache = cache.filter { listed.contains($0.key) }
        cacheOrder.removeAll { !listed.contains($0) }
        for id in wanted.prefix(Self.cacheLimit) where cache[id] == nil {
            load(id)
        }
    }

    private func load(_ id: UUID) {
        guard !failed.contains(id), loading.insert(id).inserted else { return }
        let storage = storage
        let maxPixel = Self.maxPixel
        Task { [weak self] in
            let data = await Task.detached(priority: .userInitiated) {
                storage.loadContent(id: id).flatMap { ImageInfo.thumbnailPNG($0, maxPixel: maxPixel) }
            }.value
            guard let self else { return }
            loading.remove(id)
            guard let data, let image = NSImage(data: data) else {
                failed.insert(id)
                return
            }
            remember(image, for: id)
            if shownID == id { imageView.image = image }
        }
    }

    private func remember(_ image: NSImage, for id: UUID) {
        cache[id] = image
        cacheOrder.removeAll { $0 == id }
        cacheOrder.append(id)
        while cacheOrder.count > Self.cacheLimit {
            cache[cacheOrder.removeFirst()] = nil
        }
    }
}
