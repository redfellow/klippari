import Foundation

/// Recognises copies that are probably secrets, which the history keeps
/// in memory only, for `HistoryStore.secretLifetime`, and shows masked.
///
/// A copy is a secret when it comes from a password app, or when its text
/// contains a credential in a well-known format. There is deliberately no
/// entropy guess: it would flag ordinary hashes and UUIDs.
public enum Secrets {
    /// Pasteboard type in which apps following the nspasteboard.org
    /// convention name themselves, as a bundle identifier.
    public static let sourceType = "org.nspasteboard.source"

    /// Password apps whose copies are secrets whatever they look like.
    /// Apps that mark their copies as concealed are skipped before this.
    public static let passwordApps: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.Passwords",
        "com.bitwarden.desktop",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "org.keepassxc.keepassxc",
    ]

    private struct Format {
        let regex: NSRegularExpression
        /// Detection only: never masked in place (a private key's header
        /// line is not the secret).
        let maskable: Bool

        init(_ pattern: String, maskable: Bool = true) {
            regex = try! NSRegularExpression(pattern: pattern)
            self.maskable = maskable
        }
    }

    /// Group 1 of a maskable format is the prefix that names the kind of
    /// credential and stays visible. Order matters: earlier formats win
    /// where matches overlap ('sk-ant-' before 'sk-').
    private static let formats: [Format] = [
        Format(#"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"#, maskable: false),
        Format(#"\b(github_pat_)[A-Za-z0-9_]{22,}"#),
        Format(#"\b(gh[pousr]_)[A-Za-z0-9]{36,}"#),
        Format(#"\b(sk-ant-)[A-Za-z0-9_-]{20,}"#),
        Format(#"\b(sk-(?:proj-|svcacct-|admin-)?)[A-Za-z0-9_-]{20,}"#),
        Format(#"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        Format(#"\b(xox[abposr]-)[A-Za-z0-9-]{10,}"#),
        Format(#"\b(eyJ)[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#),
    ]

    /// Stands in for the hidden part. Always the same length, so the mask
    /// does not tell how long the secret is.
    public static let dots = "••••••"

    /// Whether this copy should be kept as a secret. `frontmostBundleID`
    /// is the app that was in front when the copy was seen; the copy's own
    /// source marker wins over it when present.
    public static func isSecret(_ content: ClipContent, frontmostBundleID: String?) -> Bool {
        let declared = content.data(for: sourceType).flatMap { String(data: $0, encoding: .utf8) }
        if let source = declared ?? frontmostBundleID, passwordApps.contains(source) { return true }
        guard let string = content.plainString else { return false }
        return containsCredential(string)
    }

    public static func containsCredential(_ string: String) -> Bool {
        let range = NSRange(string.startIndex..., in: string)
        return formats.contains { $0.regex.firstMatch(in: string, range: range) != nil }
    }

    /// One line as a secret's row shows it. The first credential in a
    /// known format keeps its prefix and last few characters, so two keys
    /// of the same kind can be told apart. Before it, only a variable name
    /// ('export GH_TOKEN=') stays; anything else there, and anything after
    /// it, is hidden, since a secret often sits beside another one. A line
    /// with no known credential is treated as one whole secret, as a
    /// password is.
    public static func mask(_ line: String) -> String {
        if isArmorLine(line) { return line }
        guard let (range, prefix) = credentials(in: line).first else { return maskWhole(line) }
        let before = String(line[..<range.lowerBound])
        let after = line[range.upperBound...]
        var result = before.isEmpty || isAssignment(before) ? before : dots + " "
        result += maskCredential(String(line[range]), prefix: prefix)
        if after.trimmingCharacters(in: closing).isEmpty {
            result += after
        } else {
            result += " " + dots
        }
        return result
    }

    /// What may close a credential without hiding anything: quotes,
    /// separators and spaces.
    private static let closing = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'`;,"))

    private static let assignment = try! NSRegularExpression(
        pattern: #"^\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_.-]*\s*[=:]\s*["'`]?$"#
    )

    /// True for the start of a line that only names where the credential
    /// goes: 'export GH_TOKEN=', 'api_key: "'.
    private static func isAssignment(_ text: String) -> Bool {
        assignment.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let armor = try! NSRegularExpression(pattern: #"^-----(?:BEGIN|END) [A-Z0-9 ]+-----$"#)

    /// A whole '-----BEGIN … KEY-----' or '-----END … KEY-----' line names
    /// what follows and is not secret itself. A key collapsed onto one
    /// line is not such a line.
    private static func isArmorLine(_ line: String) -> Bool {
        armor.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    /// Non-overlapping maskable credentials in `line`, in order, each with
    /// its visible prefix.
    private static func credentials(in line: String) -> [(Range<String.Index>, String)] {
        let whole = NSRange(line.startIndex..., in: line)
        var found: [(Range<String.Index>, String)] = []
        for format in formats where format.maskable {
            for match in format.regex.matches(in: line, range: whole) {
                guard let range = Range(match.range, in: line),
                      let prefixRange = Range(match.range(at: 1), in: line),
                      !found.contains(where: { $0.0.overlaps(range) })
                else { continue }
                found.append((range, String(line[prefixRange])))
            }
        }
        return found.sorted { $0.0.lowerBound < $1.0.lowerBound }
    }

    private static func maskCredential(_ credential: String, prefix: String) -> String {
        let body = credential.count - prefix.count
        let tail = body >= 16 ? 4 : body >= 8 ? 2 : 0
        return prefix + dots + String(credential.suffix(tail))
    }

    /// Shows at most an eighth of the text at each end, and never more
    /// than three characters there, so a short password shows nothing.
    private static func maskWhole(_ text: String) -> String {
        let shown = min(3, text.count / 8)
        return String(text.prefix(shown)) + dots + String(text.suffix(shown))
    }
}
