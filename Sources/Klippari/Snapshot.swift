import AppKit
import ClipboardCore
import SwiftUI

/// Development aid: `Klippari --snapshot <png path> [dark]` renders
/// the panel with sample items to an image and exits, so its layout can
/// be compared with the design mock without touching real history.
/// Adding `settings` renders the settings window's content instead, and
/// `archive` gives it a cleared history to show, and `full` adds the
/// note a restore leaves when the history had no room for everything.
/// `unsaved` renders the panel as it is while the history is not being
/// saved.
@MainActor enum Snapshot {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--snapshot"), flag + 1 < arguments.count else { return }
        let output = URL(fileURLWithPath: arguments[flag + 1])
        let dark = arguments.contains("dark")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Klippari-snapshot-\(UUID().uuidString)")
        let storage = ItemStorage(root: root, cipher: .ephemeral())
        let store = HistoryStore(storage: storage)
        let now = Date()
        for sample in samples().reversed() {
            store.add(
                sample.content, sourceApp: sample.app, secret: sample.secret,
                now: now.addingTimeInterval(-sample.age)
            )
        }
        let model = PanelModel(store: store, now: { now })
        model.open()
        if arguments.contains("unsaved") {
            model.warning = UnsavedHistory.missingKey.panelWarning
        }
        if let query = arguments.firstIndex(of: "--query"), query + 1 < arguments.count {
            model.query = arguments[query + 1]
        }

        // Throwaway preferences, so a snapshot never shows or changes the
        // user's settings.
        let defaults = UserDefaults(suiteName: "Klippari-snapshot-\(UUID().uuidString)") ?? .standard
        let settings = Settings(defaults: defaults)
        if arguments.contains("archive") {
            settings.archive = ArchiveSummary(
                count: 12, archivedAt: now.addingTimeInterval(-3600), clears: arguments.contains("full") ? 3 : 1
            )
            if arguments.contains("full") {
                settings.restoreNote = "Restored 38 items. 12 did not fit: raise Keep last to restore them."
            }
        }
        let view: AnyView
        if arguments.contains("settings") {
            view = AnyView(
                SettingsView(settings: settings)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
        } else {
            view = AnyView(
                PanelView(
                    model: model, focus: PanelFocus(), storage: storage, settings: settings,
                    opaqueBackground: true
                )
                    .background(Color(white: dark ? 0.2 : 0.8))
            )
        }
        let hosting = NSHostingView(rootView: view)
        let size = arguments.contains("settings") ? hosting.fittingSize : PanelMetrics.windowSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting

        // Give SwiftUI a moment to lay out the lazy list before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            hosting.layoutSubtreeIfNeeded()
            if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: output)
            }
            try? FileManager.default.removeItem(at: root)
            exit(0)
        }
        NSApplication.shared.run()
    }

    private struct Sample {
        var content: ClipContent
        var app: String
        var age: TimeInterval
        var secret = false
    }

    private static func entry(_ pairs: (String, String)...) -> ClipContent {
        ClipContent(entries: [PasteboardEntry(types: pairs.map {
            TypedData(type: $0.0, data: Data($0.1.utf8))
        })])
    }

    private static func samples() -> [Sample] {
        let code = (["func applicationDidFinishLaunching() {"] + Array(repeating: "    line()", count: 13))
            .joined(separator: "\n")
        return [
            Sample(content: entry((TypeName.plainText, "git rebase --onto main feature~3 feature")), app: "Ghostty", age: 5),
            // Made-up keys, built in pieces so they never look like real
            // ones to secret scanners.
            Sample(
                content: entry((TypeName.plainText, "sk-ant-" + "api03-" + "EXAMPLEexampleEXAMPLEexample" + "Q4fZ")),
                app: "Ghostty", age: 60, secret: true
            ),
            Sample(
                content: entry((TypeName.plainText, "sk-ant-" + "api03-" + "EXAMPLEexampleEXAMPLEexample" + "m81K")),
                app: "Ghostty", age: 200, secret: true
            ),
            Sample(
                content: entry((TypeName.plainText, "correct horse battery staple")),
                app: "Passwords", age: 300, secret: true
            ),
            Sample(content: ClipContent(entries: [PasteboardEntry(types: [
                TypedData(type: TypeName.png, data: samplePNG()),
            ])]), app: "Preview", age: 120),
            Sample(content: entry(
                (TypeName.plainText, "Meeting notes: Q4 planning, hiring and the office move"),
                (TypeName.rtf, "{\\rtf1}")
            ), app: "Notes", age: 540),
            Sample(content: entry(
                (TypeName.fileURL, "file:///Users/me/report-final.pdf"), (TypeName.plainText, "report-final.pdf")
            ), app: "Finder", age: 1440),
            Sample(content: entry(
                (TypeName.plainText, "https://developer.apple.com/documentation/appkit/nspasteboard")
            ), app: "Safari", age: 3600),
            Sample(content: entry((TypeName.plainText, code)), app: "Xcode", age: 10800),
        ]
    }

    private static func samplePNG() -> Data {
        let image = NSImage(size: NSSize(width: 1280, height: 720), flipped: false) { rect in
            NSColor(red: 0.62, green: 0.72, blue: 0.85, alpha: 1).setFill()
            rect.fill()
            NSColor(red: 0.30, green: 0.42, blue: 0.32, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: rect.height * 0.45).fill()
            return true
        }
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1280, pixelsHigh: 720, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: 1280, height: 720))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }
}
