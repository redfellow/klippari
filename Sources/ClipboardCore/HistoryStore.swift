import Foundation
import os

/// The cleared history, which can be restored.
public struct ArchiveSummary: Equatable, Sendable {
    public var count: Int
    /// When the last clear was made.
    public var archivedAt: Date
    /// How many clears the items come from.
    public var clears: Int

    public init(count: Int, archivedAt: Date, clears: Int = 1) {
        self.count = count
        self.archivedAt = archivedAt
        self.clears = clears
    }
}

/// What a restore did.
public struct RestoreResult: Equatable, Sendable {
    /// How many items came back.
    public var restored: Int
    /// How many stayed in the archive because the history was full.
    public var noRoom: Int
    /// How many could not be moved back, and stay in the archive.
    public var failed: Int

    public init(restored: Int, noRoom: Int, failed: Int = 0) {
        self.restored = restored
        self.noRoom = noRoom
        self.failed = failed
    }

    /// What Settings says after the restore, so that one which left
    /// items behind never looks as if Restore did nothing. Nil when
    /// everything came back.
    public var note: String? {
        guard noRoom > 0 || failed > 0 else { return nil }
        if restored == 0, failed == 0 {
            return "The history is full, so nothing was restored. Raise Keep last to make room."
        }
        var note = restored == 0
            ? "Nothing was restored."
            : "Restored \(restored == 1 ? "1 item" : "\(restored) items")."
        if noRoom > 0 {
            note += " \(noRoom) did not fit: raise Keep last to restore them."
        }
        if failed > 0 {
            note += failed == 1
                ? " 1 could not be moved back and is still in the cleared history."
                : " \(failed) could not be moved back and are still in the cleared history."
        }
        return note
    }
}

/// The ordered history, newest first, mirrored to disk. Items in memory
/// carry lightened content (text and file URLs only); images and other
/// large data stay on disk until an item is pasted.
///
/// Secrets are the exception: they are never written to disk, keep their
/// full content in memory, and leave the history after `secretLifetime`.
@MainActor public final class HistoryStore {
    /// How long a secret stays in the history after it was copied.
    public static let secretLifetime: TimeInterval = 10 * 60
    /// How long each clear can be restored after it was made.
    public static let archiveLifetime: TimeInterval = 24 * 60 * 60
    /// The most the cleared history may take on disk, in bytes. Past
    /// it the oldest clears are deleted, though never the one just made.
    public var archiveSizeLimit: Int64 = 1_000_000_000

    private let storage: ItemStorage
    /// Where clearing the history moves it, so clearing can be
    /// undone: next to the storage (see `StorageLocation.archiveRoot`),
    /// with a folder for each clear.
    public let archiveRoot: URL
    private var archive: ClearedHistory { ClearedHistory(root: archiveRoot, cipher: storage.cipher) }
    private static let logger = Logger(subsystem: "com.arime.Klippari", category: "store")

    public private(set) var items: [ClipItem]

    /// Maximum number of items kept. Lowering it drops the oldest at once.
    public var limit: Int {
        didSet {
            trim()
            onChange?()
        }
    }

    /// Called after every mutation.
    public var onChange: (() -> Void)?
    /// Called when a secret joins the history, so its expiry can be
    /// timed.
    public var onSecretAdded: (() -> Void)?

    /// With `sealingPlainItems`, history written before encryption is
    /// encrypted first (see `sealPlainHistory`). The app does that on
    /// its own, off the main thread, and passes false.
    public init(storage: ItemStorage, limit: Int = 50, sealingPlainItems: Bool = true) {
        self.storage = storage
        archiveRoot = StorageLocation.archiveRoot(forItems: storage.root)
        self.limit = limit
        if sealingPlainItems {
            Self.sealPlainHistory(storage)
        } else {
            Self.tidy(storage)
        }
        self.items = storage.loadAll()
        trim()
    }

    /// Encrypts the history and the cleared history written before
    /// encryption. Loading skips whatever is not sealed, so this comes
    /// first. It reads and writes each such item in full, which takes a
    /// while for a large history, so it can run off the main thread.
    /// Returns whether nothing plain is left.
    @discardableResult
    nonisolated public static func sealPlainHistory(_ storage: ItemStorage) -> Bool {
        let archive = tidy(storage)
        // A clear's date is in its folder's name, so sealing its items
        // leaves when it expires unchanged.
        storage.sealPlainItems()
        for clear in archive.clears() {
            clear.storage.sealPlainItems()
        }
        return !ItemStorage.holdsPlainItems(in: [storage.root, archive.root])
    }

    /// Sorts a flat cleared history into a clear, dated by the folder's
    /// modification time (before anything rewrites items in it), and
    /// removes what interrupted saves left in the clears' folders.
    @discardableResult
    nonisolated private static func tidy(_ storage: ItemStorage) -> ClearedHistory {
        let archive = ClearedHistory(
            root: StorageLocation.archiveRoot(forItems: storage.root), cipher: storage.cipher
        )
        archive.adoptFlatLayout()
        for clear in archive.clears() {
            clear.storage.removeLeftovers()
        }
        return archive
    }

    /// Items on disk, in the history or the cleared history, that the
    /// key cannot open (see `ItemStorage.unreadableItems`). They are
    /// not loaded, so nothing else shows them.
    public func unreadableItems(countingPlain: Bool) -> [URL] {
        ItemStorage.unreadableItems(in: [storage.root, archiveRoot], cipher: storage.cipher, countingPlain: countingPlain)
    }

    /// Deletes what `unreadableItems` lists. Returns how many went.
    @discardableResult
    public func removeUnreadableItems(countingPlain: Bool) -> Int {
        var removed = 0
        for folder in unreadableItems(countingPlain: countingPlain)
        where (try? FileManager.default.removeItem(at: folder)) != nil {
            removed += 1
        }
        return removed
    }

    /// Records a copy. Content identical to an existing item moves that
    /// item to the top instead of adding a duplicate. A `secret` copy is
    /// kept in memory only, until `secretLifetime` from now, and any copy
    /// of it in the cleared history is deleted.
    @discardableResult
    public func add(_ content: ClipContent, sourceApp: String?, secret: Bool = false, now: Date) -> ClipItem {
        let hash = content.contentHash
        if secret { deleteArchivedCopies(of: hash) }
        if let index = items.firstIndex(where: { $0.contentHash == hash }) {
            guard secret else { return touch(index, now: now) }
            // Copied again as a secret: off the disk if it was on it, and
            // a fresh lifetime.
            var item = items.remove(at: index)
            if !item.isSecret { storage.delete(id: item.id) }
            item.content = content
            item.lastUsedAt = now
            item.expiresAt = now.addingTimeInterval(Self.secretLifetime)
            items.insert(item, at: 0)
            onChange?()
            onSecretAdded?()
            return item
        }

        var item = ClipItem(
            id: UUID(), capturedAt: now, lastUsedAt: now, sourceApp: sourceApp,
            content: content, imageInfo: ImageInfo.inspect(content), contentHash: hash,
            expiresAt: secret ? now.addingTimeInterval(Self.secretLifetime) : nil
        )
        if !secret {
            do {
                try storage.save(item)
                item.content = content.lightened
            } catch {
                // Keep the full content in memory, so the item can still be
                // pasted; it just will not survive a restart.
                Self.logger.error("Could not save item: \(error.localizedDescription, privacy: .public)")
            }
        }
        items.insert(item, at: 0)
        trim()
        onChange?()
        if secret { onSecretAdded?() }
        return item
    }

    /// Takes over another store's items, as when the history moves from
    /// a folder kept for one run to the saved one. Each item is saved
    /// here with its full content, read from the other store; secrets
    /// stay in memory, with the time they have left, and leave this
    /// store's cleared history. Content already here is not added twice,
    /// and the history size applies. An item whose content can no longer
    /// be read whole is left out: it could not be pasted either.
    public func adopt(_ other: HistoryStore) {
        let present = Set(items.map(\.contentHash))
        for var item in other.items where !present.contains(item.contentHash) {
            let full = other.fullContent(for: item.id) ?? item.content
            guard full.isComplete else { continue }
            item.content = full
            if item.isSecret {
                deleteArchivedCopies(of: item.contentHash)
            } else {
                do {
                    try storage.save(item)
                    item.content = full.lightened
                } catch {
                    Self.logger.error("Could not save item: \(error.localizedDescription, privacy: .public)")
                }
            }
            items.append(item)
        }
        items.sort { $0.lastUsedAt > $1.lastUsedAt }
        trim()
        onChange?()
        if items.contains(where: \.isSecret) { onSecretAdded?() }
    }

    public func markUsed(_ id: UUID, now: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        touch(index, now: now)
    }

    /// Removes the secrets whose time is up. Returns whether any were.
    @discardableResult
    public func expireSecrets(now: Date) -> Bool {
        let before = items.count
        items.removeAll { $0.expiresAt.map { $0 <= now } ?? false }
        guard items.count != before else { return false }
        onChange?()
        return true
    }

    /// The item's complete content for pasting. Falls back to what is in
    /// memory if the disk copy cannot be read.
    public func fullContent(for id: UUID) -> ClipContent? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        if item.content.isComplete { return item.content }
        return storage.loadContent(id: id) ?? item.content
    }

    public func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        storage.delete(id: id)
        onChange?()
    }

    /// Clears the history by moving it to the archive, as a clear of its
    /// own beside those made before: an archived copy of something
    /// cleared again now gives way to the newer one. Secrets are dropped,
    /// never archived. Returns how many items were archived, which is
    /// how many can be restored. An item kept only in memory, because saving
    /// it failed, is saved into the archive. An item that could not be
    /// moved or saved stays in the history and is not counted; 0 means
    /// nothing changed. If the archive has grown past
    /// `archiveSizeLimit`, the oldest clears are deleted.
    @discardableResult
    public func archiveAll(now: Date) -> Int {
        guard !items.isEmpty else { return 0 }
        let archive = archive
        let earlier = archive.items()
        let clear = archive.storage(for: now)
        var (moved, left) = storage.archive(items.lazy.filter { !$0.isSecret }.map(\.id), to: clear)
        // An item whose save failed is only in memory, with its full
        // content: save it into the archive instead. If that fails too,
        // it stays in the history. A secret is never written to disk.
        for item in items where !item.isSecret && !moved.contains(item.id) && !left.contains(item.id) {
            do {
                try clear.save(item)
                moved.insert(item.id)
            } catch {
                left.insert(item.id)
            }
        }
        if !left.isEmpty {
            Self.logger.error("Could not archive \(left.count) items")
        }

        let cleared = Set(items.filter { moved.contains($0.id) }.map(\.contentHash))
        for old in earlier where cleared.contains(old.item.contentHash) {
            // The same item moved into the same folder has replaced itself.
            if old.clear.storage.root.path == clear.root.path && moved.contains(old.item.id) { continue }
            old.clear.storage.delete(id: old.item.id)
        }
        archive.removeEmpty()
        archive.trim(toBytes: archiveSizeLimit, keeping: clear)

        // What was archived is gone from the history, so the list never
        // shows an item whose files have moved, and the count is only
        // of items that can be restored. Secrets go too, unarchived.
        let before = items.count
        let archived = items.filter { moved.contains($0.id) }.count
        items.removeAll { moved.contains($0.id) || $0.isSecret }
        guard items.count != before else { return 0 }
        onChange?()
        return archived
    }

    /// Deletes every item in the cleared history whose content is `hash`,
    /// so that a secret cannot be restored from there as a saved item. A
    /// clear's date is in its folder's name, so its time left is kept.
    private func deleteArchivedCopies(of hash: String) {
        let archive = archive
        for old in archive.items() where old.item.contentHash == hash {
            old.clear.storage.delete(id: old.item.id)
        }
        archive.removeEmpty()
    }

    /// The archived history, if there is one.
    public var archiveSummary: ArchiveSummary? {
        archive.summary
    }

    /// When the oldest clear is due to be deleted; nil when nothing is
    /// cleared.
    public var nextArchiveExpiry: Date? {
        archive.nextExpiry(lifetime: Self.archiveLifetime)
    }

    /// The shortest wait before checking the cleared history again.
    public static let archiveRetryInterval: TimeInterval = 60

    /// When to next check the cleared history: when the oldest clear is
    /// due, but never sooner than `archiveRetryInterval` from `now`. A
    /// clear that is overdue because it could not be deleted is then
    /// tried again once a minute, rather than over and over at once.
    /// Nil when nothing is cleared.
    public func nextArchiveCheck(now: Date) -> Date? {
        nextArchiveExpiry.map { max($0, now.addingTimeInterval(Self.archiveRetryInterval)) }
    }

    /// Deletes the archive for good.
    public func deleteArchive() {
        try? FileManager.default.removeItem(at: archiveRoot)
    }

    /// Deletes each clear `archiveLifetime` after it was made. Returns
    /// whether any was deleted.
    @discardableResult
    public func expireArchive(now: Date) -> Bool {
        archive.expire(now: now, lifetime: Self.archiveLifetime)
    }

    /// Puts back as many archived items as the history has room for,
    /// newest first by when each was last used, merged with what was
    /// copied since. The rest stay in the archive, so a restore never
    /// deletes an item or pushes one out of the history. The only thing
    /// it removes from the archive besides what came back is a copy of
    /// something already in the history. An item that could not be
    /// moved stays there too, in its clear, to be restored later. A
    /// secret in the history never comes back as a saved item: its
    /// archived copy is deleted instead, even if adding the secret could
    /// not delete it.
    @discardableResult
    public func restoreArchive() -> RestoreResult {
        let archive = archive
        // Secrets included: an archived copy of one is deleted, not restored.
        var seen = Set(items.map(\.contentHash))
        var waiting: [(item: ClipItem, clear: ClearedHistory.Clear)] = []
        // Newest first, so a second copy of the same content is the older.
        for old in archive.items() {
            if seen.insert(old.item.contentHash).inserted {
                waiting.append(old)
            } else {
                old.clear.storage.delete(id: old.item.id)
            }
        }

        // An item that cannot be moved leaves its room to the next one.
        let room = max(limit - items.count, 0)
        var result = RestoreResult(restored: 0, noRoom: 0, failed: 0)
        for (item, clear) in waiting {
            guard result.restored < room else {
                result.noRoom += 1
                continue
            }
            do {
                try clear.storage.move(id: item.id, to: storage)
                items.append(item)
                result.restored += 1
            } catch {
                Self.logger.error("Could not restore item: \(error.localizedDescription, privacy: .public)")
                result.failed += 1
            }
        }
        archive.removeEmpty()
        if result.restored > 0 {
            items.sort { $0.lastUsedAt > $1.lastUsedAt }
            onChange?()
        }
        return result
    }

    /// Moves an item to the top. Only its manifest is rewritten; the data
    /// files, which can be large, are left alone. A secret has nothing on
    /// disk, and its lifetime does not restart when it is pasted.
    @discardableResult
    private func touch(_ index: Int, now: Date) -> ClipItem {
        var item = items.remove(at: index)
        item.lastUsedAt = now
        items.insert(item, at: 0)
        if !item.isSecret {
            do {
                try storage.updateManifest(item)
            } catch {
                Self.logger.error("Could not update item: \(error.localizedDescription, privacy: .public)")
            }
        }
        onChange?()
        return item
    }

    private func trim() {
        let keep = max(limit, 0)
        while items.count > keep {
            storage.delete(id: items.removeLast().id)
        }
    }
}
