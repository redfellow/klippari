import AppKit
import ClipboardCore
import SwiftUI

/// Sizes taken from the Paper mock ('Panel – default').
enum PanelMetrics {
    static let cardWidth: CGFloat = 640
    static let rowHeight: CGFloat = 44
    /// Nine, so every row a Cmd+digit can paste is in view when the
    /// panel opens.
    static let visibleRows = 9
    static let listPadding: CGFloat = 6
    static let searchHeight: CGFloat = 56
    static let footerHeight: CGFloat = 36
    /// Transparent margin around the card that holds its shadow.
    static let shadowInset: CGFloat = 60

    /// The app's one colour (#0A5CFF), shared with the app icon. Fixed
    /// rather than the system accent so the panel always matches the icon.
    static let blue = Color(red: 0.039, green: 0.361, blue: 1)

    static var maxCardHeight: CGFloat {
        cardHeight(rowCount: visibleRows)
    }

    /// The list's height: up to nine rows, or room for the empty message.
    static func listHeight(rowCount: Int) -> CGFloat {
        guard rowCount > 0 else { return 2 * rowHeight }
        return CGFloat(min(rowCount, visibleRows)) * rowHeight + 2 * listPadding
    }

    /// The card's height with this many rows, two dividers included.
    static func cardHeight(rowCount: Int) -> CGFloat {
        searchHeight + listHeight(rowCount: rowCount) + footerHeight + 2
    }

    static var windowSize: NSSize {
        NSSize(width: cardWidth + 2 * shadowInset, height: maxCardHeight + 2 * shadowInset)
    }
}

/// Decrypted row thumbnails, so a redraw does not decrypt them again.
/// An item's thumbnail never changes, so entries never go stale; the
/// oldest are dropped past `limit`. A thumbnail that is missing or does
/// not open is remembered too, so it is not read again on every redraw.
/// `keep` drops the entries of items no longer listed.
@MainActor final class ThumbnailCache {
    private var images: [UUID: NSImage] = [:]
    private var misses: Set<UUID> = []
    private var order: [UUID] = []
    private let limit = 100

    func image(for id: UUID, in storage: ItemStorage) -> NSImage? {
        if let image = images[id] { return image }
        guard !misses.contains(id) else { return nil }
        guard let image = storage.thumbnail(for: id).flatMap(NSImage.init(data:)) else {
            misses.insert(id)
            return nil
        }
        images[id] = image
        order.append(id)
        if order.count > limit { images[order.removeFirst()] = nil }
        return image
    }

    /// Forgets every item not in `ids`: deleted, cleared or filtered out.
    func keep(_ ids: Set<UUID>) {
        images = images.filter { ids.contains($0.key) }
        misses.formIntersection(ids)
        order.removeAll { !ids.contains($0) }
    }
}

/// Behind-window blur, which SwiftUI materials cannot do in a
/// transparent window.
private struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct PanelView: View {
    @Bindable var model: PanelModel
    var focus: PanelFocus
    let storage: ItemStorage
    var settings: Settings
    /// Called on a click on a row, with whether Shift was held.
    var onActivate: (UUID, _ plainText: Bool) -> Void = { _, _ in }
    /// Snapshots render offscreen, where behind-window blur draws nothing.
    var opaqueBackground = false
    /// Called when the pointer enters or leaves an image row's thumbnail,
    /// while the Images setting is on.
    var onHoverImage: (UUID, _ inside: Bool) -> Void = { _, _ in }
    @FocusState private var filterFocused: Bool
    @State private var thumbnails = ThumbnailCache()

    var body: some View {
        VStack(spacing: 0) {
            searchRow
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: PanelMetrics.cardWidth)
        .background {
            if opaqueBackground {
                Color(nsColor: .windowBackgroundColor)
            } else {
                PanelBackground()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 30, y: 16)
        .padding(PanelMetrics.shadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: focus.cardAtBottom ? .bottom : .top)
        .onAppear { filterFocused = true }
        .onChange(of: focus.showCount) { filterFocused = true }
        .onChange(of: model.rows.map(\.id)) { _, ids in thumbnails.keep(Set(ids)) }
    }

    private var searchRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Type to filter", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .padding(5)
                .focused($filterFocused)
            Text(model.countLabel)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .frame(height: PanelMetrics.searchHeight)
    }

    @ViewBuilder private var list: some View {
        if model.rows.isEmpty {
            Text(model.query.isEmpty ? "Nothing copied yet" : "No matches")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: PanelMetrics.listHeight(rowCount: 0))
        } else {
            let appWidth = appColumnWidth
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows) { row in
                            RowView(
                                row: row, isSelected: row.id == model.selectedID,
                                appWidth: appWidth, thumbnail: { thumbnails.image(for: row.id, in: storage) },
                                onHoverThumbnail: settings.magnifyImages
                                    ? { inside in onHoverImage(row.id, inside) } : nil
                            )
                            .id(row.id)
                            .modifier(RowFrame(enabled: settings.magnifyImages, id: row.id, focus: focus))
                            .modifier(RowMouse(
                                enabled: settings.mouseOnRows,
                                hover: {
                                    // Only a pointer that moved selects, not a
                                    // row scrolling under a still pointer while
                                    // arrowing, nor the row under it on open.
                                    let pointer = NSEvent.mouseLocation
                                    guard pointer != focus.lastPointer else { return }
                                    focus.lastPointer = pointer
                                    guard row.id != model.selectedID else { return }
                                    focus.selectedByPointer = true
                                    model.select(row.id)
                                },
                                activate: {
                                    onActivate(row.id, NSEvent.modifierFlags.contains(.shift))
                                }
                            ))
                        }
                    }
                    .padding(PanelMetrics.listPadding)
                }
                .frame(height: PanelMetrics.listHeight(rowCount: model.rows.count))
                .onChange(of: model.selectedID) { _, id in
                    // The pointer picked a row it can see; scrolling would
                    // move the list under it.
                    if focus.selectedByPointer {
                        focus.selectedByPointer = false
                        return
                    }
                    if let id { proxy.scrollTo(id) }
                }
                // The list keeps its scroll position while the panel is
                // hidden, and reopening selects the first row again, which
                // is no change of selection. Scroll to it on every open, or
                // a list scrolled by trackpad would reopen with the
                // selected row out of sight.
                .onChange(of: focus.showCount) {
                    if let id = model.selectedID { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
    }

    /// As wide as the longest app name on show, capped, so the app and
    /// age columns line up without wasting space on short names.
    private var appColumnWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        let widest = model.rows
            .map { ($0.sourceApp as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return min(ceil(widest), 110)
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 20) {
            if let notice = model.notice {
                if let link = model.noticeLink {
                    // The whole notice is the link: a click anywhere on it
                    // opens the place it asks the user to go to.
                    Button {
                        NSWorkspace.shared.open(link)
                    } label: {
                        HStack(spacing: 6) {
                            Text(notice).foregroundStyle(.primary)
                            Text("Open Accessibility Settings").foregroundStyle(PanelMetrics.blue).underline()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                } else {
                    Text(notice)
                        .foregroundStyle(.primary)
                }
                Spacer()
            } else if let warning = model.warning {
                // What is wrong matters more than the key hints.
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(warning).foregroundStyle(.primary).lineLimit(1)
                }
                .help(warning)
                Spacer()
            } else {
                KeyHint(keys: "↩", label: "Paste")
                KeyHint(keys: "⇧ ↩", label: "Plain text")
                KeyHint(keys: "⌘ 1–9", label: "Quick paste")
                Spacer()
                // Shift turns Delete into clearing everything.
                HStack(spacing: 6) {
                    KeyHint(keys: "⌘ ⌫", label: "Delete")
                    KeyHint(keys: "⇧", label: "all")
                }
                KeyHint(keys: "esc", label: "Close")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .frame(height: PanelMetrics.footerHeight)
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 6) {
            Text(keys)
                .fontWeight(.medium)
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .foregroundStyle(.secondary)
        }
        // A hint never wraps; the footer is laid out to fit them all.
        .fixedSize()
    }
}

/// Reports where a row is, for the image preview to line up with it.
/// Only with the Images setting on: frames change on every scroll step,
/// and nothing else reads them.
private struct RowFrame: ViewModifier {
    let enabled: Bool
    let id: UUID
    let focus: PanelFocus

    func body(content: Content) -> some View {
        if enabled {
            content
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    focus.rowFrames[id] = frame
                }
                .onDisappear { focus.rowFrames[id] = nil }
        } else {
            content
        }
    }
}

/// With the mouse setting on, moving the pointer over a row selects it
/// and a click pastes it. With it off, rows ignore the mouse, as before
/// the setting existed.
private struct RowMouse: ViewModifier {
    let enabled: Bool
    let hover: () -> Void
    let activate: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active = phase { hover() }
                }
                .onTapGesture(perform: activate)
        } else {
            content
        }
    }
}

private struct RowView: View {
    let row: PanelModel.Row
    let isSelected: Bool
    let appWidth: CGFloat
    /// The item's thumbnail; only called for image rows.
    let thumbnail: () -> NSImage?
    /// Set when hovering an image's thumbnail should enlarge it.
    var onHoverThumbnail: ((Bool) -> Void)?

    private var primary: Color { isSelected ? .white : .primary }
    private var secondary: Color { isSelected ? .white.opacity(0.8) : .secondary }

    var body: some View {
        HStack(spacing: 12) {
            Text(row.number.map(String.init) ?? "")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(secondary)
                .frame(width: 16, alignment: .trailing)

            icon
                .frame(width: 28, height: 28)

            title
                .frame(maxWidth: .infinity, alignment: .leading)

            if let expiresIn = row.expiresIn {
                // A secret: masked, and gone from the history in this long.
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill")
                    Text(expiresIn).monospacedDigit()
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(primary.opacity(0.1), in: Capsule())
                .fixedSize()
                .help("Kept in memory only and removed after 10 minutes")
            }

            HStack(spacing: 6) {
                Text(row.sourceApp)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: appWidth, alignment: .leading)
                Text(row.age)
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            .font(.system(size: 13))
            .foregroundStyle(secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: PanelMetrics.rowHeight)
        .background(
            isSelected ? PanelMetrics.blue : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    /// A title too long for the row loses its middle, so both the start
    /// and the end (a file's extension, a key's last characters) stay in
    /// view. The tag always shows in full.
    private var title: some View {
        HStack(spacing: 0) {
            Text(row.presentation.title)
                .font(.system(size: 15, weight: isSelected ? .medium : .regular))
                .foregroundStyle(primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let tag = row.presentation.tag {
                // An image's tag follows its title directly; other tags are
                // set off with a dot, as in the mock.
                let separator = row.presentation.kind == .image ? " " : " · "
                Text(separator + tag)
                    .font(.system(size: 15))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if row.presentation.kind == .image, let image = thumbnail() {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12)))
                .onHover { inside in onHoverThumbnail?(inside) }
        } else {
            Image(systemName: symbolName)
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
        }
    }

    private var symbolName: String {
        switch row.presentation.kind {
        case .text: "text.alignleft"
        case .styledText: "textformat"
        case .link: "link"
        case .file: "doc"
        case .image: "photo"
        case .other: "questionmark.square"
        }
    }
}
