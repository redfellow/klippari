import AppKit
import ClipboardCore
import CryptoKit
import os

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private var store: HistoryStore!
    private var monitor: ClipboardMonitor!
    private var model: PanelModel!
    private var panel: PanelController!
    private var hotKey: HotKey!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!
    private var registeredShortcut: Shortcut?
    private var expiryTimer: Timer?
    private var secretTimer: Timer?
    /// Set when the history could not be opened on disk and lives in a
    /// throwaway folder for this run instead.
    private var unsavedRoot: URL?
    /// Why, for the menu and the panel to say.
    private var unsaved: UnsavedHistory?
    private static let logger = Logger(subsystem: "com.arime.Klippari", category: "app")

    func applicationDidFinishLaunching(_ notification: Notification) {
        StorageLocation.removeAbandonedUnsaved(in: StorageLocation.defaultCaches)
        settingsWindow = SettingsWindowController(settings: settings)
        statusItem = StatusItemController(settings: settings)
        statusItem.onOpenSettings = { [weak self] in self?.settingsWindow.show() }
        statusItem.onResetPanelPosition = { [weak self] in self?.settings.panelPlacement = nil }
        NSApp.mainMenu = makeMainMenu()
        LoginItem.registerOnFirstLaunch()

        let storage = openStorage()
        statusItem.unsaved = unsaved
        // What needs the history waits for it: encrypting a 1.0 history
        // happens off the main thread first, and takes a while for a
        // large one.
        open(storage) { [weak self] in self?.finishLaunching() }
    }

    /// The rest of launching, once the history is open.
    private func finishLaunching() {
        hotKey = HotKey(shortcut: settings.shortcut) { [weak self] in
            self?.hotKeyPressed()
        }
        registeredShortcut = settings.shortcut
        settings.shortcutUnavailable = !hotKey.isRegistered

        statusItem.onResetSavedHistory = { [weak self] in self?.confirmResetSavedHistory() }
        statusItem.onDeleteUnreadableItems = { [weak self] in self?.confirmDeleteUnreadableItems() }
        statusItem.onTryAgain = { [weak self] in self?.tryAgain() }
        statusItem.onClearHistory = { [weak self] in self?.confirmClearHistory() }
        settings.onChange = { [weak self] in self?.applySettings() }
        settings.onRestoreArchive = { [weak self] in self?.restoreArchive() }
        settings.onDeleteArchive = { [weak self] in self?.deleteArchive() }
        // Settings changed while the history was being encrypted.
        applySettings()

        // Timers do not fire while the Mac sleeps, and may fire late
        // after: look again on waking.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.expire()
                self?.expireSecrets()
            }
        }
        watchAppSwitches()
    }

    /// A copy belongs to the app that was in front when it was made: on
    /// every switch the monitor polls once more before the new app counts,
    /// so a password copied just before Cmd+Tab is still a secret.
    private func watchAppSwitches() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let source = SourceApp(name: app?.localizedName, bundleID: app?.bundleIdentifier)
            MainActor.assumeIsolated { self?.monitor?.appDidActivate(source) }
        }
    }

    /// Builds the history, the monitor and the panel on `storage`. Called
    /// at launch, and again when Try Again or Reset Saved History moves
    /// the history from this run's folder to the saved one: `previous` is
    /// then the history so far, which is taken over.
    ///
    /// A saved history still holding 1.0 items is encrypted first, off
    /// the main thread. The menu says so meanwhile, and the previous
    /// history, if any, goes on capturing until the new one takes over.
    /// `then` runs once the history is open.
    private func open(
        _ storage: ItemStorage, takingOver previous: HistoryStore? = nil, then: @escaping () -> Void = {}
    ) {
        let folder = StorageLocation.defaultFolder
        let migrating = unsaved == nil && !KeyCheck.exists(in: folder)
        guard migrating, ItemStorage.holdsPlainItems(in: [storage.root, StorageLocation.archiveRoot(forItems: storage.root)]) else {
            if migrating { writeKeyCheck(storage) }
            build(storage, takingOver: previous)
            then()
            return
        }
        statusItem.encrypting = true
        Task { [weak self] in
            let done = await Task.detached(priority: .userInitiated) {
                HistoryStore.sealPlainHistory(storage)
            }.value
            guard let self else { return }
            statusItem.encrypting = false
            // Written once nothing plain is left: from then on, plain
            // items no longer belong to the history.
            if done { writeKeyCheck(storage) }
            build(storage, takingOver: previous)
            then()
        }
    }

    private func build(_ storage: ItemStorage, takingOver previous: HistoryStore?) {
        monitor?.stop()
        panel?.hide()
        store = HistoryStore(storage: storage, limit: settings.historyLimit, sealingPlainItems: false)
        store.onSecretAdded = { [weak self] clearedHistoryChanged in
            self?.scheduleSecretCheck()
            // A secret also takes its copies out of the cleared history;
            // a note from the last Restore still holds.
            if clearedHistoryChanged { self?.refreshArchive() }
        }
        if let previous { store.adopt(previous) }
        store.expireArchive(now: Date())
        monitor = ClipboardMonitor(
            pasteboard: SystemPasteboard(), store: store,
            sourceApp: { NSWorkspace.shared.frontmostApplication?.localizedName },
            sourceBundleID: { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
        )
        monitor.isPaused = settings.isPaused
        // PanelModel takes over store.onChange; nothing else may set it.
        model = PanelModel(store: store)
        model.warning = unsaved?.panelWarning
        panel = PanelController(model: model, storage: storage, settings: settings)
        panel.onPaste = { [weak self] item, plainText in
            self?.paste(item, plainText: plainText)
        }
        panel.onClearAll = { [weak self] in self?.clearFromPanel() }
        showArchive()
        monitor.start()
    }

    private func writeKeyCheck(_ storage: ItemStorage) {
        do {
            try KeyCheck.write(storage.cipher, in: StorageLocation.defaultFolder)
        } catch {
            Self.logger.error("Could not write the key check: \(String(describing: error), privacy: .public)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let unsavedRoot {
            try? FileManager.default.removeItem(at: unsavedRoot.deletingLastPathComponent())
        }
    }

    /// The encrypted history in Application Support. When the folder or
    /// the keychain key cannot be had, the history is kept for this run
    /// only, in a folder in Caches with a key that never leaves memory,
    /// and the saved history is left untouched for a later launch. The
    /// menu and the panel then say that it is not being saved, and why.
    private func openStorage() -> ItemStorage {
        do {
            return try openSavedStorage()
        } catch {
            Self.logger.error("History is not saved this run: \(String(describing: error), privacy: .public)")
            unsaved = error as? UnsavedHistory ?? .folder(String(describing: error))
            let root = StorageLocation.unsavedItemsRoot(in: StorageLocation.defaultCaches)
            unsavedRoot = root
            return ItemStorage(root: root, cipher: .ephemeral())
        }
    }

    /// Throws an `UnsavedHistory` saying what stood in the way.
    private func openSavedStorage() throws -> ItemStorage {
        let folder = StorageLocation.defaultFolder
        do {
            try StorageLocation.prepare(folder)
        } catch {
            throw UnsavedHistory.folder(String(describing: error))
        }
        let items = StorageLocation.itemsRoot(in: folder)
        let roots = [items, StorageLocation.archiveRoot(forItems: items)]
        let cipher: ItemCipher
        do {
            // Never a new key over a history sealed with a missing one.
            // A key check left by an earlier key goes with it.
            let key = try ItemCipher.key(stored: KeychainKey.load(), sealedHistoryIn: roots) {
                KeyCheck.remove(in: folder)
                return try KeychainKey.create()
            }
            cipher = ItemCipher(key: key)
        } catch is ItemCipher.MissingKey {
            throw UnsavedHistory.missingKey
        } catch {
            throw UnsavedHistory.keychain(String(describing: error))
        }
        // A key that is not the history's is not used either: nothing
        // could be read with it, and what is copied would be sealed
        // with a key that may not be the user's.
        if KeyCheck.verdict(for: cipher, in: folder, sealedHistoryIn: roots) == .wrongKey {
            throw UnsavedHistory.wrongKey
        }
        return ItemStorage(root: items, cipher: cipher)
    }

    /// Reset Saved History…, offered in the menu while the saved history
    /// cannot be read because its key is missing or is another one.
    private func confirmResetSavedHistory() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reset the saved history?"
        if case .wrongKey = unsaved {
            alert.informativeText = "The saved history was encrypted with another key than the one in your "
                + "keychain. Resetting deletes what that key cannot open, the cleared history included, "
                + "and starts saving with it. This cannot be undone. "
                + "If you did not expect this, cancel, delete 'Klippari history key' in Keychain Access "
                + "and relaunch Klippari instead. "
                + "What is in the history now is kept, but not what was cleared since Klippari started."
        } else {
            alert.informativeText = "The saved history was encrypted with a key that is no longer in your "
                + "keychain, so Klippari cannot read it. Resetting deletes it, and the cleared history with it, "
                + "and starts saving again with a new key. This cannot be undone. "
                + "What is in the history now is kept, but not what was cleared since Klippari started."
        }
        alert.addButton(withTitle: "Reset Saved History")
        alert.addButton(withTitle: "Cancel")
        Self.neverDeleteByDefault(alert)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try resetSavedHistory()
        } catch {
            Self.logger.error("Could not reset the saved history: \(String(describing: error), privacy: .public)")
            stillUnsaved(error)
            let failure = NSAlert()
            failure.messageText = "The saved history could not be reset"
            failure.informativeText = "\((error as? UnsavedHistory)?.menuReason ?? String(describing: error))."
                + "\n\nHistory is still not being saved."
            failure.runModal()
        }
    }

    /// For an alert whose first button deletes: that button gets no key,
    /// so Return does nothing, and Cancel keeps Escape.
    private static func neverDeleteByDefault(_ alert: NSAlert) {
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
    }

    /// Deletes the saved items that cannot be read and moves this run's
    /// history into the saved folder, without a restart: with a new key
    /// when the old one is missing, with the keychain's when it is
    /// another one.
    private func resetSavedHistory() throws {
        let folder = StorageLocation.defaultFolder
        let items = StorageLocation.itemsRoot(in: folder)
        let roots = [items, StorageLocation.archiveRoot(forItems: items)]
        switch unsaved {
        case .missingKey:
            // If the key is back (a keychain restored or unlocked since
            // launch), nothing is deleted, and opening checks it.
            guard try KeychainKey.load() == nil else { break }
            // Only what was sealed with the lost key goes. Items still in
            // plain form (a migration that did not finish, or version 1.0
            // run again) are readable; opening the history encrypts them
            // with the new key. Should anything sealed be left, no key is
            // made.
            for root in roots {
                try ItemStorage.removeSealedItems(root)
            }
            KeyCheck.remove(in: folder)
        case .wrongKey:
            guard let stored = try KeychainKey.load() else { break }
            for item in ItemStorage.unreadableItems(in: roots, cipher: ItemCipher(key: stored), countingPlain: false) {
                try FileManager.default.removeItem(at: item)
            }
            KeyCheck.remove(in: folder)
        default:
            break
        }
        try reopenSavedHistory()
    }

    /// Opens the saved history and moves this run's history into it.
    /// Throws an `UnsavedHistory` when it still cannot be opened.
    private func reopenSavedHistory() throws {
        let storage = try openSavedStorage()
        let temporary = unsavedRoot
        unsaved = nil
        unsavedRoot = nil
        statusItem.unsaved = nil
        // This run's folder goes once its items have been taken over,
        // which may be after the saved history has been encrypted.
        open(storage, takingOver: store) {
            if let temporary {
                try? FileManager.default.removeItem(at: temporary.deletingLastPathComponent())
            }
        }
    }

    /// Try Again: opens the saved history as a relaunch would, after
    /// the keychain refused (Deny clicked by mistake, or a locked
    /// keychain) or the key was missing. This run's history moves into
    /// it. If it still cannot be opened, the menu gives the reason.
    private func tryAgain() {
        do {
            try reopenSavedHistory()
        } catch {
            Self.logger.error("History is still not saved: \(String(describing: error), privacy: .public)")
            stillUnsaved(error)
            NSSound.beep()
        }
    }

    /// Shows the reason after a failed attempt to open the saved history.
    private func stillUnsaved(_ error: Error) {
        guard let reason = error as? UnsavedHistory else { return }
        unsaved = reason
        statusItem.unsaved = reason
        model.warning = reason.panelWarning
    }

    /// Items on disk that the key cannot open: the menu counts them and
    /// offers to delete them. Once the history has its key check, plain
    /// items no longer belong to it, so they count too.
    private var unreadableItems: [URL] {
        guard unsaved == nil else { return [] }
        return store.unreadableItems(countingPlain: KeyCheck.exists(in: StorageLocation.defaultFolder))
    }

    private func confirmDeleteUnreadableItems() {
        let count = unreadableItems.count
        guard count > 0 else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Delete \(count == 1 ? "the unreadable item" : "\(count) unreadable items")?"
        alert.informativeText = "\(count == 1 ? "This item was" : "These items were") encrypted with another "
            + "key, or not written by Klippari, so Klippari cannot show \(count == 1 ? "it" : "them"). "
            + "This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        Self.neverDeleteByDefault(alert)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.removeUnreadableItems(countingPlain: KeyCheck.exists(in: StorageLocation.defaultFolder))
        showArchive()
    }

    /// Each clear is deleted a day after it was made. One timer waits
    /// for the next of those times; it is set again whenever the
    /// cleared history changes.
    private func scheduleExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let date = store.nextArchiveCheck(now: Date()) else { return }
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expire() }
        }
        // Lets macOS group the wake-up with others; a clear may outlive
        // its day by up to a minute.
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    private func expire() {
        if store.expireArchive(now: Date()) {
            showArchive()
        } else {
            scheduleExpiry()
        }
    }

    /// Secrets leave the history ten minutes after they were copied. One
    /// timer waits for the next to go, or at most 15 seconds while the
    /// panel is open, to keep its minutes current. It runs only while
    /// there are secrets. Timers stop while the Mac sleeps, so waking
    /// checks again.
    private func scheduleSecretCheck() {
        secretTimer?.invalidate()
        secretTimer = nil
        guard let next = store.nextSecretExpiry else { return }
        let now = Date()
        let date = panel?.isVisible == true ? min(next, now.addingTimeInterval(15)) : next
        let timer = Timer(fire: max(date, now), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireSecrets() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        secretTimer = timer
    }

    private func expireSecrets() {
        let expired = store.expireSecrets(now: Date())
        if !expired, panel.isVisible {
            model.refreshTimes()
        }
        scheduleSecretCheck()
    }

    private func applySettings() {
        if store.limit != settings.historyLimit {
            store.limit = settings.historyLimit
            // A note about the history being full no longer holds.
            settings.restoreNote = nil
        }
        if registeredShortcut != settings.shortcut {
            hotKey.update(settings.shortcut)
            if hotKey.isRegistered {
                registeredShortcut = settings.shortcut
                settings.shortcutUnavailable = false
            } else if let previous = registeredShortcut {
                // Never leave the app with no way to open the panel: go
                // back to the shortcut that worked. Setting it re-enters
                // this method, where the two now match and nothing happens.
                hotKey.update(previous)
                settings.shortcut = previous
                settings.shortcutUnavailable = true
            }
        }
        if monitor.isPaused != settings.isPaused {
            monitor.isPaused = settings.isPaused
        }
        statusItem.refresh()
    }

    /// The shortcut opens the panel; pressed again while it is open, it
    /// steps down the list so the modifiers can be held and V tapped.
    private func hotKeyPressed() {
        if panel.isVisible {
            model.moveSelection(by: 1)
        } else {
            // A secret whose time ran out since the last check must not
            // show for the seconds until the next one.
            store.expireSecrets(now: Date())
            panel.show()
            // While the panel is open, its minutes are kept current.
            scheduleSecretCheck()
        }
    }

    private func paste(_ item: ClipItem, plainText: Bool) {
        // A secret whose time is up is never pasted, even if its row is
        // still showing.
        expireSecrets()
        guard store.items.contains(where: { $0.id == item.id }) else { return }
        monitor.paste(item, plainText: plainText)
        guard Paster.isTrusted else {
            // Without Accessibility the item is on the clipboard but cannot
            // be pasted for the user; keep the panel open to say so.
            model.notice = "Copied. Klippari needs Accessibility to paste directly."
            model.noticeLink = Paster.accessibilitySettingsURL
            Paster.requestTrustOnce()
            return
        }
        panel.hide()
        // Let the previous app become key again before the keystroke lands.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            Paster.sendPaste()
        }
    }

    private func confirmClearHistory() {
        let secrets = store.items.filter(\.isSecret).count
        let saved = store.items.count - secrets
        guard saved + secrets > 0 else { return }
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = Self.clearWarning(saved: saved, secrets: secrets)
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            archiveHistory()
        }
    }

    /// What the alert before clearing says: what can be restored, and
    /// that secrets cannot.
    static func clearWarning(saved: Int, secrets: Int) -> String {
        let items = saved == 1 ? "1 item" : "\(saved) items"
        let secretsText = secrets == 1 ? "1 secret" : "\(secrets) secrets"
        if secrets == 0 {
            return "This clears \(saved == 1 ? items : "all " + items). Settings can restore them for 24 hours."
        }
        if saved == 0 {
            return "This removes \(secretsText), which cannot be restored."
        }
        return "This clears \(items), which Settings can restore for 24 hours, "
            + "and removes \(secretsText), which cannot be restored."
    }

    /// Shift+Cmd+Backspace in the panel: no confirmation, since the
    /// cleared history can be restored; the notice says how.
    private func clearFromPanel() {
        let secrets = store.items.filter(\.isSecret).count
        let count = archiveHistory()
        let gone = secrets - store.items.filter(\.isSecret).count
        switch (count, gone) {
        case (0, 0):
            return
        case (_, 0):
            model.notice = "Cleared \(count == 1 ? "1 item" : "\(count) items"). Restore them in Settings."
        case (0, _):
            model.notice = "Removed \(gone == 1 ? "1 secret" : "\(gone) secrets"); secrets are not kept."
        default:
            model.notice = "Cleared \(count == 1 ? "1 item" : "\(count) items"), restorable in Settings, "
                + "and removed \(gone == 1 ? "1 secret" : "\(gone) secrets")."
        }
        model.noticeLink = nil
    }

    /// Clears the history into the archive, adding to what is there.
    @discardableResult
    private func archiveHistory() -> Int {
        let count = store.archiveAll(now: Date())
        showArchive()
        return count
    }

    /// Restores what fits in the history, and says when something did
    /// not come back, so Restore never looks broken.
    private func restoreArchive() {
        showArchive(note: store.restoreArchive().note)
    }

    private func deleteArchive() {
        store.deleteArchive()
        showArchive()
    }

    /// Brings the Cleared history row in Settings, and the timer that
    /// deletes it, up to date with the cleared history.
    private func showArchive(note: String? = nil) {
        refreshArchive()
        settings.restoreNote = note
    }

    /// Updates the Cleared history row and its timer, leaving the note
    /// from the last Restore as it is.
    private func refreshArchive() {
        settings.archive = store.archiveSummary
        statusItem?.unreadable = unreadableItems.count
        scheduleExpiry()
    }

    /// A background app has no visible menu bar, but the main menu still
    /// supplies the standard shortcuts (Cmd+Q, Cmd+W, Cmd+V in text
    /// fields) to the settings window and the filter field.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Klippari", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)

        return main
    }
}
