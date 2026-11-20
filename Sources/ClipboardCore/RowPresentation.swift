import Foundation
import UniformTypeIdentifiers

public enum ItemKind: Equatable, Sendable {
    case text, styledText, link, file, image, other
}

/// What one history item looks like as a row in the panel.
public struct RowPresentation: Equatable, Sendable {
    public var kind: ItemKind
    /// One line, no newlines.
    public var title: String
    /// Greyed suffix after the title.
    public var tag: String?
    /// Lowercased text, file names and source app; for an image, also
    /// 'image' and its format.
    public var searchText: String

    public init(_ item: ClipItem) {
        let content = item.content
        let files = content.fileURLs
        let string = content.plainString
        var searchParts: [String] = []

        // A file URL wins over text: Finder puts the file name on the
        // pasteboard as plain text alongside the URL. It also wins over
        // image data, since Finder adds the file's icon, unless the copy
        // is an image that is also offered as its saved file.
        let imageIsTheFile = item.imageInfo != nil && Self.isImageOfferedAsFile(content, files)
        if item.isSecret {
            // Only the masked first line shows, and only it is searched,
            // so typing in the filter cannot confirm the hidden part.
            // Nothing else about the secret shows either: not that it is
            // a link, nor its number of lines, nor a file's name.
            kind = .text
            let firstLine = string?
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            title = firstLine.map(Secrets.mask) ?? Secrets.dots
            tag = nil
            searchParts = [title, "secret"]
        } else if !files.isEmpty, !imageIsTheFile {
            kind = .file
            title = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
            tag = "file"
            searchParts = files.map(\.lastPathComponent)
        } else if let info = item.imageInfo {
            kind = .image
            title = "Image"
            tag = "\(info.width) × \(info.height) · \(info.format)"
            searchParts = files.map(\.lastPathComponent)
        } else if let string {
            let lines = string
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            title = lines.first ?? "Empty text"
            searchParts = [string]
            if content.hasType(TypeName.rtf) || content.hasType(TypeName.html) {
                kind = .styledText
                tag = "styled"
            } else if lines.count == 1, Self.isLink(lines[0]) {
                kind = .link
                tag = nil
            } else {
                kind = .text
                tag = lines.count > 1 ? "\(lines.count) lines" : nil
            }
        } else {
            kind = .other
            let type = content.entries.first?.types.first?.type ?? ""
            title = UTType(type)?.localizedDescription ?? (type.isEmpty ? "Unknown" : type)
            tag = nil
        }

        // An image has no text of its own, so without these words it
        // could only be found by its source app. Other kinds get none:
        // 'text' or 'file' would match nearly every item.
        if kind == .image {
            searchParts.append("image")
            if let format = item.imageInfo?.format { searchParts.append(format) }
        }
        if let app = item.sourceApp { searchParts.append(app) }
        searchText = searchParts.joined(separator: "\n").lowercased()
    }

    /// True for a single image file that comes with its own PNG bytes, as
    /// screenshot helpers such as clipaste write it so that terminals can
    /// paste a path. Finder's icon for a copied file is not PNG.
    private static func isImageOfferedAsFile(_ content: ClipContent, _ files: [URL]) -> Bool {
        guard files.count == 1, content.hasType(TypeName.png),
              let type = UTType(filenameExtension: files[0].pathExtension)
        else { return false }
        return type.conforms(to: .image)
    }

    private static func isLink(_ line: String) -> Bool {
        guard !line.contains(where: \.isWhitespace),
              let url = URL(string: line),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        return url.host != nil
    }

    /// What VoiceOver reads for a secret's title: the dots as the word
    /// 'hidden' rather than one 'bullet' each.
    public var spokenTitle: String {
        title.replacingOccurrences(of: Secrets.dots, with: " hidden ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Case-insensitive substring match; an empty query matches everything.
    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return needle.isEmpty || searchText.contains(needle)
    }
}

/// Compact age for the row's right-hand column.
public func ageString(from date: Date, now: Date) -> String {
    let seconds = Int(now.timeIntervalSince(date))
    if seconds < 60 { return "now" }
    if seconds < 3600 { return "\(seconds / 60) min" }
    if seconds < 86400 { return "\(seconds / 3600) h" }
    return "\(seconds / 86400) d"
}

/// Time left before a secret leaves the history, in whole minutes rounded
/// up, so it reads '1 min' until the very end.
public func remainingString(until date: Date, now: Date) -> String {
    let minutes = max(1, Int((date.timeIntervalSince(now) / 60).rounded(.up)))
    return "\(minutes) min"
}
