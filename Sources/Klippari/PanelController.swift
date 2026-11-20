import AppKit
import Carbon.HIToolbox
import ClipboardCore
import SwiftUI

/// A panel that takes keyboard focus without activating this app, so the
/// app the user was in stays frontmost and receives the paste.
private final class HistoryPanel: NSPanel {
    /// Returns true when it handled the key.
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The window is larger than the card by a transparent margin, and
    /// its placement already keeps the card on screen. Left to itself,
    /// macOS would push the window down whenever that margin reaches into
    /// the menu bar, moving the card over the text field it was placed
    /// above.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func sendEvent(_ event: NSEvent) {
        // Intercept before the filter field sees the key, so arrows,
        // Return and Esc drive the list rather than the text cursor.
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// Set on every show for the view.
@MainActor @Observable final class PanelFocus {
    /// Bumped so the view can put focus back in the filter.
    var showCount = 0
    /// True when the panel opened above the pointer: the card then sits
    /// at the bottom of the window and grows upward.
    var cardAtBottom = false
    /// Where the pointer was when it last selected a row, or when the
    /// panel opened. Hovering selects only once the pointer has moved.
    @ObservationIgnored var lastPointer: CGPoint?
    /// True from the pointer selecting a row until the list has seen the
    /// change, so that it does not scroll for it.
    @ObservationIgnored var selectedByPointer = false
    /// Frames of the rows on show, in the window's content coordinates
    /// (origin top left), so the image preview can line up with its row.
    /// Empty while the Images setting is off.
    var rowFrames: [UUID: CGRect] = [:]
}

@MainActor final class PanelController: NSObject, NSWindowDelegate {
    private let model: PanelModel
    private let panel: HistoryPanel
    private let focus = PanelFocus()
    private let settings: Settings
    /// Where the app last put the window itself, to tell its own moves
    /// from the user dragging the panel.
    private var placedOrigin: NSPoint?
    private let preview: ImagePreviewController
    /// The image row whose thumbnail the pointer is over. It is shown
    /// instead of the selection while the pointer stays there.
    private var hoveredImage: UUID? {
        didSet { if hoveredImage != oldValue { refreshPreview() } }
    }

    /// Called with the chosen item and whether to paste it as plain text.
    var onPaste: ((ClipItem, _ plainText: Bool) -> Void)?
    /// Called on Shift+Cmd+Backspace, to clear the whole history.
    var onClearAll: (() -> Void)?

    var isVisible: Bool { panel.isVisible }

    init(model: PanelModel, storage: ItemStorage, settings: Settings) {
        self.model = model
        self.settings = settings
        preview = ImagePreviewController(storage: storage)
        panel = HistoryPanel(
            contentRect: NSRect(origin: .zero, size: PanelMetrics.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()

        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        // Like Spotlight, the panel can be dragged by any part of the card
        // that is not a control, and reopens where it was left.
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The shadow is drawn by the SwiftUI content, which is smaller
        // than the window and changes height with the list.
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: PanelView(
                model: model, focus: focus, storage: storage, settings: settings,
                onActivate: { [weak self] id, plainText in
                    guard let self else { return }
                    model.select(id)
                    if let item = model.selectedItem { onPaste?(item, plainText) }
                },
                onHoverImage: { [weak self] id, inside in
                    guard let self else { return }
                    if inside {
                        hoveredImage = id
                    } else if hoveredImage == id {
                        hoveredImage = nil
                    }
                }
            )
        )
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        trackPreview()
    }

    // MARK: Enlarged image

    /// Follows the selection, the list and the Images setting, so the
    /// preview changes as soon as any of them does, keyboard included.
    private func trackPreview() {
        refreshPreview()
        withObservationTracking {
            _ = model.selectedID
            _ = model.rows
            _ = settings.magnifyImages
            _ = focus.rowFrames
        } onChange: { [weak self] in
            // Called before the change lands; look once it has.
            Task { @MainActor in self?.trackPreview() }
        }
    }

    /// Makes the image rows' previews ahead of time, then shows the
    /// hovered image, or else the selected one if it is an image.
    private func refreshPreview() {
        guard settings.magnifyImages else {
            preview.hide()
            // Nothing is listed for previews: let go of the decrypted ones.
            preview.preload([])
            if !focus.rowFrames.isEmpty { focus.rowFrames = [:] }
            return
        }
        preview.preload(model.rows.lazy.filter { $0.presentation.kind == .image }.map(\.id))
        guard panel.isVisible, let visible = panel.screen?.visibleFrame else {
            preview.hide()
            return
        }
        let selectedImage = model.rows.first {
            $0.id == model.selectedID && $0.presentation.kind == .image
        }?.id
        let target = hoveredImage ?? selectedImage
        let card = cardFrame
        // The row's middle on screen, kept within the card for a row
        // that is partly scrolled out of the list.
        let rowMidY = target.flatMap { focus.rowFrames[$0] }.map { frame in
            min(max(panel.frame.maxY - frame.midY, card.minY), card.maxY)
        }
        preview.show(target.flatMap(model.visibleItem), beside: card, rowMidY: rowMidY, in: visible, parent: panel)
    }

    /// The card's frame on screen, which is smaller than the window.
    private var cardFrame: NSRect {
        let inset = PanelMetrics.shadowInset
        let height = PanelMetrics.cardHeight(rowCount: model.rows.count)
        let frame = panel.frame
        let y = focus.cardAtBottom ? frame.minY + inset : frame.maxY - inset - height
        return NSRect(x: frame.minX + inset, y: y, width: frame.width - 2 * inset, height: height)
    }

    func show() {
        model.open()
        let mouse = NSEvent.mouseLocation
        focus.lastPointer = mouse
        // With Position on, open next to the text field being typed in
        // when it can be read, else at the pointer. Read before the panel
        // shows, while the other app's field still has focus.
        let anchor = settings.openAtPointer
            ? FocusedField.anchorFrame() ?? CGRect(origin: mouse, size: .zero) : nil
        let spot = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? mouse
        let screen = NSScreen.screens.first { NSMouseInRect(spot, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            let frame: NSRect
            if let anchor {
                let placement = PointerPlacement(
                    anchor: anchor, cardHeight: PanelMetrics.cardHeight(rowCount: model.rows.count),
                    windowSize: PanelMetrics.windowSize, inset: PanelMetrics.shadowInset, in: visible
                )
                focus.cardAtBottom = placement.isAbovePointer
                frame = placement.windowFrame
            } else {
                // The remembered spot is relative to the screen, so the
                // panel still opens on the screen being used.
                focus.cardAtBottom = false
                frame = (settings.panelPlacement ?? .default).windowFrame(
                    windowSize: PanelMetrics.windowSize, inset: PanelMetrics.shadowInset, in: visible
                )
            }
            placedOrigin = frame.origin
            panel.setFrame(frame, display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        focus.showCount += 1
        hoveredImage = nil
        refreshPreview()
    }

    /// Remembers where the user dragged the panel. Not while it follows
    /// the pointer, where the next open goes to the pointer anyway.
    func windowDidMove(_ notification: Notification) {
        guard panel.isVisible, !settings.openAtPointer, panel.frame.origin != placedOrigin,
              let visible = panel.screen?.visibleFrame
        else { return }
        placedOrigin = panel.frame.origin
        settings.panelPlacement = PanelPlacement(
            windowFrame: panel.frame, inset: PanelMetrics.shadowInset, in: visible
        )
    }

    func hide() {
        preview.hide()
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = Int(event.keyCode)

        switch key {
        case kVK_Escape:
            if model.escape() == .close { hide() }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard flags.isSubset(of: [.shift]) else { return false }
            if let item = model.selectedItem {
                onPaste?(item, flags.contains(.shift))
            }
            return true
        case kVK_DownArrow:
            model.moveSelection(by: 1)
            return true
        case kVK_UpArrow:
            model.moveSelection(by: -1)
            return true
        case kVK_ANSI_N where flags == [.control]:
            model.moveSelection(by: 1)
            return true
        case kVK_ANSI_P where flags == [.control]:
            model.moveSelection(by: -1)
            return true
        case kVK_Delete where flags == [.command]:
            model.deleteSelected()
            return true
        case kVK_Delete where flags == [.command, .shift]:
            onClearAll?()
            return true
        case kVK_ANSI_S where flags == [.command]:
            model.keepSelectedAsOrdinary()
            return true
        default:
            break
        }

        if flags == [.command], let number = Self.digitKeys[key] {
            if let item = model.item(quickNumber: number) {
                onPaste?(item, false)
            }
            return true
        }
        return false
    }

    private static let digitKeys: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]
}
