import Foundation

/// Keeps history items on disk, one directory per item:
///
///     <root>/<uuid>/manifest.json
///     <root>/<uuid>/e<entry>-t<type>.bin   raw bytes of one pasteboard type
///     <root>/<uuid>/thumb.png              only for images
///
/// Every file is sealed with `cipher`; nothing is written in plain form.
/// Directories are 0700 and files 0600.
///
/// Data file names come from indices, never from the type string, because
/// type identifiers are arbitrary text chosen by other apps.
public struct ItemStorage: Sendable {
    public enum StorageError: Error {
        /// A lightened item was passed where full content is needed.
        case incompleteContent
        case missingItem
        case writeFailed(String)
    }

    public let root: URL
    public let cipher: ItemCipher

    private struct Manifest: Codable {
        struct TypeRecord: Codable {
            var type: String
            var file: String
        }

        var id: UUID
        var capturedAt: Date
        var lastUsedAt: Date
        var sourceApp: String?
        var imageInfo: ImageInfo?
        /// Absent in manifests written before hashes were stored.
        var contentHash: String?
        var entries: [[TypeRecord]]
        /// True when the user said the item is not a secret; absent
        /// otherwise, and in manifests written before secrets.
        var notSecret: Bool?
    }

    private static let manifestName = "manifest.json"
    private static let thumbnailName = "thumb.png"
    private static let temporaryPrefix = ".tmp-"

    public init(root: URL, cipher: ItemCipher) {
        self.root = root
        self.cipher = cipher
        let fm = FileManager.default
        try? fm.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        // Never through a symbolic link: that would change another folder.
        if fm.isRealDirectory(root) {
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }
    }

    private func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString)
    }

    /// What a file is bound to when sealed: its item and its name.
    private static func context(_ id: UUID, _ file: String) -> String {
        "\(id.uuidString)/\(file)"
    }

    /// Seals `data` and writes it as a new 0600 file.
    private func writeSealed(_ data: Data, to url: URL, id: UUID) throws {
        let sealed = try cipher.seal(data, context: Self.context(id, url.lastPathComponent))
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(atPath: url.path, contents: sealed, attributes: [.posixPermissions: 0o600]) else {
            throw StorageError.writeFailed(url.lastPathComponent)
        }
    }

    private func readSealed(_ url: URL, id: UUID) throws -> Data {
        try cipher.open(Data(contentsOf: url), context: Self.context(id, url.lastPathComponent))
    }

    /// The item's thumbnail PNG, decrypted; nil when it has none.
    public func thumbnail(for id: UUID) -> Data? {
        try? readSealed(directory(for: id).appendingPathComponent(Self.thumbnailName), id: id)
    }

    /// Writes a new item with its full content. The item is built in a
    /// hidden temporary directory and renamed into place, so a visible
    /// item directory is always complete.
    ///
    /// With `durable`, the new files are flushed to disk before they
    /// replace an existing directory, so a power loss right after cannot
    /// leave the item with neither copy. Encrypting a 1.0 item uses it,
    /// since its plain copy goes in the swap.
    public func save(_ item: ClipItem, durable: Bool = false) throws {
        guard item.content.isComplete else { throw StorageError.incompleteContent }
        let fm = FileManager.default
        let temporary = root.appendingPathComponent(Self.temporaryPrefix + item.id.uuidString)
        try? fm.removeItem(at: temporary)
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        do {
            var records: [[Manifest.TypeRecord]] = []
            for (entryIndex, entry) in item.content.entries.enumerated() {
                var entryRecords: [Manifest.TypeRecord] = []
                for (typeIndex, typed) in entry.types.enumerated() {
                    guard let data = typed.data else { continue }
                    let file = "e\(entryIndex)-t\(typeIndex).bin"
                    try writeSealed(data, to: temporary.appendingPathComponent(file), id: item.id)
                    entryRecords.append(Manifest.TypeRecord(type: typed.type, file: file))
                }
                records.append(entryRecords)
            }
            if item.imageInfo != nil, let thumbnail = ImageInfo.thumbnailPNG(item.content) {
                try writeSealed(thumbnail, to: temporary.appendingPathComponent(Self.thumbnailName), id: item.id)
            }
            let manifest = Manifest(
                id: item.id, capturedAt: item.capturedAt, lastUsedAt: item.lastUsedAt,
                sourceApp: item.sourceApp, imageInfo: item.imageInfo,
                contentHash: item.contentHash, entries: records, notSecret: item.notSecret ? true : nil
            )
            try writeSealed(
                JSONEncoder().encode(manifest), to: temporary.appendingPathComponent(Self.manifestName), id: item.id
            )

            if durable {
                for name in try fm.contentsOfDirectory(atPath: temporary.path) {
                    try Self.flush(temporary.appendingPathComponent(name))
                }
                try Self.flush(temporary)
            }

            let destination = directory(for: item.id)
            if fm.fileExists(atPath: destination.path) {
                // Swap in one step, so an interruption never leaves the
                // item with neither the old nor the new directory.
                // The swapped-in directory takes on the old one's mode.
                let swapped = try fm.replaceItemAt(destination, withItemAt: temporary) ?? destination
                try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: swapped.path)
            } else {
                try fm.moveItem(at: temporary, to: destination)
            }
            // And the swap itself, which lives in the parent folder.
            if durable { try? Self.flush(root) }
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    /// Flushes a file or directory to the disk itself, not only to the
    /// drive's cache.
    private static func flush(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw StorageError.writeFailed(url.lastPathComponent) }
        defer { close(descriptor) }
        if fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 {
            throw StorageError.writeFailed(url.lastPathComponent)
        }
    }

    /// Records a change to an item's metadata (its last-used time) without
    /// touching its data files, which can be many megabytes.
    public func updateManifest(_ item: ClipItem) throws {
        let directory = directory(for: item.id)
        guard var manifest = manifest(in: directory, id: item.id) else { throw StorageError.missingItem }
        manifest.capturedAt = item.capturedAt
        manifest.lastUsedAt = item.lastUsedAt
        manifest.sourceApp = item.sourceApp
        manifest.contentHash = item.contentHash
        manifest.notSecret = item.notSecret ? true : nil

        // Write beside it and rename over it, so the manifest is never
        // half written.
        let url = directory.appendingPathComponent(Self.manifestName)
        let staged = directory.appendingPathComponent(Self.temporaryPrefix + Self.manifestName)
        let sealed = try cipher.seal(JSONEncoder().encode(manifest), context: Self.context(item.id, Self.manifestName))
        try? FileManager.default.removeItem(at: staged)
        guard FileManager.default.createFile(
            atPath: staged.path, contents: sealed, attributes: [.posixPermissions: 0o600]
        ) else { throw StorageError.writeFailed(Self.manifestName) }
        guard rename(staged.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: staged)
            throw StorageError.writeFailed(Self.manifestName)
        }
    }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: directory(for: id))
    }

    /// Moves these items into `archive`, adding to what is already there;
    /// an item whose id is there already replaces that one. Each item
    /// moves on its own, so one that cannot be moved stays here and is
    /// reported in `left`, and the rest are still archived. Ids with
    /// nothing on disk are skipped, and so is everything else in the
    /// folder: an item that could not be decrypted is not in the
    /// history, and stays.
    public func archive(
        _ ids: some Sequence<UUID>, to archive: ItemStorage
    ) -> (moved: Set<UUID>, left: Set<UUID>) {
        let fm = FileManager.default
        var moved: Set<UUID> = []
        var left: Set<UUID> = []
        for id in ids where fm.fileExists(atPath: directory(for: id).path) {
            let destination = archive.directory(for: id)
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: directory(for: id), to: destination)
                moved.insert(id)
            } catch {
                left.insert(id)
            }
        }
        return (moved, left)
    }

    /// Moves one item's directory into another storage.
    public func move(id: UUID, to other: ItemStorage) throws {
        try FileManager.default.moveItem(at: directory(for: id), to: other.directory(for: id))
    }

    /// Encrypts items written before the history was encrypted: each one
    /// is read in plain form, saved again sealed (which replaces its
    /// directory) and so loses its plain files. A plain item whose data
    /// files cannot all be read is removed, as loading did before. A
    /// manifest that is neither sealed nor a plain one (a later format,
    /// or a sealed one with damaged first bytes) is left alone: it is not
    /// known to be unreadable. An item that fails to save (a full disk)
    /// is left as it was, to be tried again on the next launch. Returns
    /// how many items were encrypted.
    @discardableResult
    public func sealPlainItems() -> Int {
        let fm = FileManager.default
        var sealed = 0
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            guard let id = UUID(uuidString: name) else { continue }
            let url = root.appendingPathComponent(name)
            guard let raw = try? Data(contentsOf: url.appendingPathComponent(Self.manifestName)),
                  !ItemCipher.isSealed(raw)
            else { continue }
            guard let manifest = try? JSONDecoder().decode(Manifest.self, from: raw), manifest.id == id else {
                continue
            }
            guard let full = content(of: manifest, in: url, full: true, plain: true), full.isComplete else {
                try? fm.removeItem(at: url)
                continue
            }
            let item = ClipItem(
                id: id, capturedAt: manifest.capturedAt, lastUsedAt: manifest.lastUsedAt,
                sourceApp: manifest.sourceApp, content: full, imageInfo: manifest.imageInfo,
                contentHash: manifest.contentHash
            )
            if (try? save(item, durable: true)) != nil { sealed += 1 }
        }
        return sealed
    }

    /// Every item, newest `lastUsedAt` first, with lightened content: only
    /// text and file URL bytes are read. Directories that are not complete
    /// (interrupted writes, missing data files) are removed.
    ///
    /// An item whose manifest was sealed with another key is skipped and
    /// left on disk: the key may only be missing for now, and without it
    /// nothing tells a damaged item from a healthy one. Items still in
    /// plain form, which `sealPlainItems` could not encrypt yet, are also
    /// skipped and kept, for it to retry.
    public func loadAll() -> [ClipItem] {
        let fm = FileManager.default
        var items: [ClipItem] = []
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] {
            let url = root.appendingPathComponent(name)
            // A symbolic link is never followed, so nothing outside the
            // history is read or deleted through one.
            guard fm.isRealDirectory(url) else { continue }
            guard let id = UUID(uuidString: name) else {
                // Not an item: what an interrupted save left.
                try? fm.removeItem(at: url)
                continue
            }
            let raw: Data
            do {
                raw = try Data(contentsOf: url.appendingPathComponent(Self.manifestName))
            } catch {
                // An item that never got its manifest goes. One whose
                // manifest is there but cannot be read now (permissions,
                // a disk error) may be whole, and stays.
                if Self.isMissing(error) { try? fm.removeItem(at: url) }
                continue
            }
            guard !raw.isEmpty else {
                try? fm.removeItem(at: url)
                continue
            }
            guard ItemCipher.isSealed(raw),
                  let opened = try? cipher.open(raw, context: Self.context(id, Self.manifestName))
            else { continue }
            if let manifest = try? JSONDecoder().decode(Manifest.self, from: opened), manifest.id == id,
               let item = loadItem(manifest, in: url) {
                items.append(item)
            } else {
                // The manifest is ours, so what is wrong is the item.
                try? fm.removeItem(at: url)
            }
        }
        return items.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    /// Deletes what an interrupted save left behind: its hidden
    /// temporary directories. Loading the history does this as it goes;
    /// a clear's folder is not loaded until it is restored, so it is
    /// done there at launch.
    public func removeLeftovers() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.hasPrefix(Self.temporaryPrefix) {
            try? fm.removeItem(at: root.appendingPathComponent(name))
        }
    }

    /// How many items have a manifest that opens with the key. Reads
    /// only manifests and changes nothing on disk.
    public func readableItemCount() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { name in
            guard let id = UUID(uuidString: name) else { return false }
            return manifest(in: directory(for: id), id: id) != nil
        }.count
    }

    /// True when `root`, or a clear's folder in it, holds an item that
    /// was sealed, with whatever key, or might: a folder that cannot be
    /// listed, or a manifest that is there but cannot be read, counts
    /// too. Such a history can only be read with the key it was sealed
    /// with, so a new key must not be made while this is true.
    public static func holdsSealedItems(_ root: URL) -> Bool {
        let scan = scan(root, foldersDeep: 1, upTo: 1)
        return !scan.sealed.isEmpty || scan.unsure
    }

    /// Deletes every sealed item in `root` and in its clears' folders,
    /// for Reset Saved History… once their key is gone. Items still in
    /// plain form are kept: they need no key, and are encrypted with the
    /// new one when the history opens. So is anything that cannot be
    /// read, which `holdsSealedItems` then still reports.
    public static func removeSealedItems(_ root: URL) throws {
        for url in scan(root, foldersDeep: 1, upTo: .max).sealed {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Up to `limit` sealed item folders in `root`, also looking
    /// `foldersDeep` levels into folders that are not items, such as the
    /// cleared history's folder for each clear. `unsure` is set when a
    /// folder or manifest that is there could not be read.
    private static func scan(_ root: URL, foldersDeep: Int, upTo limit: Int) -> (sealed: [URL], unsure: Bool) {
        let fm = FileManager.default
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: root.path)
        } catch {
            return ([], !isMissing(error))
        }
        var found: [URL] = []
        var unsure = false
        for name in names where found.count < limit {
            let url = root.appendingPathComponent(name)
            guard UUID(uuidString: name) != nil else {
                if foldersDeep > 0, fm.isRealDirectory(url) {
                    let inner = scan(url, foldersDeep: foldersDeep - 1, upTo: limit - found.count)
                    found += inner.sealed
                    unsure = unsure || inner.unsure
                }
                continue
            }
            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: url.appendingPathComponent(manifestName))
            } catch {
                if !isMissing(error) { unsure = true }
                continue
            }
            defer { try? handle.close() }
            guard let head = try? handle.read(upToCount: 4) else {
                unsure = true
                continue
            }
            if ItemCipher.isSealed(head) { found.append(url) }
        }
        return (found, unsure)
    }

    /// Every sealed item folder in `root` and in its clears' folders.
    static func sealedItemFolders(in root: URL) -> [URL] {
        scan(root, foldersDeep: 1, upTo: .max).sealed
    }

    /// Whether the item in `folder` has a manifest that opens with
    /// `cipher` and names that item.
    static func manifestOpens(_ folder: URL, with cipher: ItemCipher) -> Bool {
        guard let id = UUID(uuidString: folder.lastPathComponent),
              let raw = try? Data(contentsOf: folder.appendingPathComponent(manifestName)),
              let opened = try? cipher.open(raw, context: context(id, manifestName))
        else { return false }
        return (try? JSONDecoder().decode(Manifest.self, from: opened))?.id == id
    }

    /// What an item's manifest is, read without changing anything.
    private enum ManifestForm {
        /// Not there, or there but unreadable for now: left to loading.
        case notRead
        case sealed(Data)
        /// A 1.0 manifest, written before encryption.
        case plain
        /// Neither: a later format, or a sealed one with damaged bytes.
        case unknown
    }

    private static func manifestForm(_ folder: URL) -> ManifestForm {
        guard let id = UUID(uuidString: folder.lastPathComponent),
              let raw = try? Data(contentsOf: folder.appendingPathComponent(manifestName)), !raw.isEmpty
        else { return .notRead }
        if ItemCipher.isSealed(raw) { return .sealed(raw) }
        if (try? JSONDecoder().decode(Manifest.self, from: raw))?.id == id { return .plain }
        return .unknown
    }

    /// Item folders in `roots` and in their clears' folders, without
    /// following symbolic links.
    private static func itemFolders(in roots: [URL]) -> [URL] {
        let fm = FileManager.default
        func folders(in root: URL, foldersDeep: Int) -> [URL] {
            ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).flatMap { name -> [URL] in
                let url = root.appendingPathComponent(name)
                guard fm.isRealDirectory(url) else { return [] }
                if UUID(uuidString: name) != nil { return [url] }
                return foldersDeep > 0 ? folders(in: url, foldersDeep: foldersDeep - 1) : []
            }
        }
        return roots.flatMap { folders(in: $0, foldersDeep: 1) }
    }

    /// Whether `roots` hold an item still in 1.0's plain form.
    public static func holdsPlainItems(in roots: [URL]) -> Bool {
        itemFolders(in: roots).contains {
            if case .plain = manifestForm($0) { return true }
            return false
        }
    }

    /// The items in `roots` that `cipher` cannot open: sealed with
    /// another key, or in no known form, and with `countingPlain` also
    /// those still in plain form. A manifest that cannot be read right
    /// now is not counted. Loading skips all of these and leaves them.
    public static func unreadableItems(in roots: [URL], cipher: ItemCipher, countingPlain: Bool) -> [URL] {
        itemFolders(in: roots).filter { folder in
            switch manifestForm(folder) {
            case .notRead: false
            case .sealed: !manifestOpens(folder, with: cipher)
            case .plain: countingPlain
            case .unknown: true
            }
        }
    }

    /// Whether `error` says the file is not there, rather than that it
    /// could not be read.
    static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) {
            return true
        }
        return false
    }

    /// The item's full content, for pasting. Nil when it cannot all be read.
    public func loadContent(id: UUID) -> ClipContent? {
        let directory = directory(for: id)
        guard let manifest = manifest(in: directory, id: id) else { return nil }
        return content(of: manifest, in: directory, full: true)
    }

    private func manifest(in directory: URL, id: UUID) -> Manifest? {
        guard let data = try? readSealed(directory.appendingPathComponent(Self.manifestName), id: id),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.id == id
        else { return nil }
        return manifest
    }

    private func loadItem(_ manifest: Manifest, in directory: URL) -> ClipItem? {
        guard let light = content(of: manifest, in: directory, full: false) else { return nil }

        var hash = manifest.contentHash
        if hash == nil {
            // Written before hashes were stored: compute it once from the
            // full content. It is saved the next time the manifest is.
            hash = content(of: manifest, in: directory, full: true)?.contentHash
        }
        guard let hash else { return nil }
        return ClipItem(
            id: manifest.id, capturedAt: manifest.capturedAt, lastUsedAt: manifest.lastUsedAt,
            sourceApp: manifest.sourceApp, content: light, imageInfo: manifest.imageInfo,
            contentHash: hash, notSecret: manifest.notSecret ?? false
        )
    }

    /// With `full` false, bytes are read only for the types kept in
    /// memory; the other data files are just checked for existence.
    /// `plain` reads files written before encryption.
    private func content(of manifest: Manifest, in directory: URL, full: Bool, plain: Bool = false) -> ClipContent? {
        let fm = FileManager.default
        var entries: [PasteboardEntry] = []
        for records in manifest.entries {
            var types: [TypedData] = []
            for record in records {
                // Only ever touch a plain file name inside the item directory.
                guard record.file == (record.file as NSString).lastPathComponent else { return nil }
                let url = directory.appendingPathComponent(record.file)
                if full || TypeName.keptInMemory.contains(record.type) {
                    let data = plain ? try? Data(contentsOf: url) : try? readSealed(url, id: manifest.id)
                    guard let data else { return nil }
                    types.append(TypedData(type: record.type, data: data))
                } else {
                    guard fm.fileExists(atPath: url.path) else { return nil }
                    types.append(TypedData(type: record.type, data: nil))
                }
            }
            entries.append(PasteboardEntry(types: types))
        }
        return ClipContent(entries: entries)
    }
}

extension FileManager {
    /// Whether `url` is a directory itself, not a symbolic link to one.
    func isRealDirectory(_ url: URL) -> Bool {
        (try? attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }
}
