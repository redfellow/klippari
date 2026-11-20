import Foundation
import Testing
import ClipboardCore

// Made-up credentials, built from pieces so that secret scanners never
// see anything that looks like a real one in the source.
let fakeAnthropicKey = "sk-ant-" + "api03-" + String(repeating: "x", count: 30) + "Q4fZ"
let otherAnthropicKey = "sk-ant-" + "api03-" + String(repeating: "x", count: 30) + "m81K"
let fakeOpenAIKey = "sk-" + "proj-" + "Ab3" + String(repeating: "x", count: 40) + "Zq9"
let fakeGitHubToken = "gh" + "p_" + String(repeating: "a", count: 32) + "WXYZ"
let fakeAWSKey = "AK" + "IA" + "ABCDEFGHIJKLMNOP"
let fakeSlackToken = "xo" + "xb-" + "1234567890-" + "abcdefghij"
let fakeJWT = "ey" + "J" + "hbGciOiJIUzI1NiJ9" + ".eyJzdWIiOiIxMjM0NTY3ODkwIn0" + ".SflKxwRJSMeKKF2QT4fwpM"
let fakePrivateKey = ["-----BEGIN OPENSSH " + "PRIVATE KEY-----", "b3BlbnNzaC1rZXktdjEAAAAA", "-----END OPENSSH PRIVATE KEY-----"]
    .joined(separator: "\n")

@MainActor @Suite struct SecretHistoryTests {
    let root = temporaryRoot()

    func makeStore(limit: Int = 50) -> HistoryStore {
        HistoryStore(storage: ItemStorage(root: root, cipher: testCipher), limit: limit)
    }

    func itemsOnDisk() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).count
    }

    @Test func secretsStayInMemoryOnly() {
        let store = makeStore()
        let item = store.add(text(fakeAnthropicKey), sourceApp: "Ghostty", secret: true, now: at(0))
        #expect(item.expiresAt == at(HistoryStore.secretLifetime))
        #expect(itemsOnDisk() == 0)
        #expect(store.fullContent(for: item.id) == text(fakeAnthropicKey))
        #expect(makeStore().items.isEmpty)
    }

    @Test func secretsLeaveAfterTenMinutes() {
        let store = makeStore()
        store.add(text("plain"), sourceApp: nil, now: at(0))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: true, now: at(0))
        #expect(!store.expireSecrets(now: at(599)))
        #expect(store.items.count == 2)
        #expect(store.expireSecrets(now: at(600)))
        #expect(store.items.map(\.content) == [text("plain")])
    }

    @Test func pastingDoesNotExtendASecretButCopyingAgainDoes() {
        let store = makeStore()
        let item = store.add(text(fakeAnthropicKey), sourceApp: nil, secret: true, now: at(0))
        store.markUsed(item.id, now: at(300))
        #expect(store.items[0].expiresAt == at(600))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: true, now: at(400))
        #expect(store.items.count == 1)
        #expect(store.items[0].expiresAt == at(1000))
    }

    @Test func copyingASavedItemAsASecretTakesItOffTheDisk() {
        let store = makeStore()
        store.add(text("hunter2-but-longer"), sourceApp: "Notes", now: at(0))
        #expect(itemsOnDisk() == 1)
        let item = store.add(text("hunter2-but-longer"), sourceApp: "Passwords", secret: true, now: at(1))
        #expect(itemsOnDisk() == 0)
        #expect(item.isSecret)
        #expect(store.items.count == 1)
    }

    /// The same password as Notes copies it: plain text beside rich text.
    func richCopy(_ string: String) -> ClipContent {
        content(typed(TypeName.plainText, string), typed(TypeName.rtf, "{\\rtf1 \(string)}"))
    }

    @Test func aSecretTakesARichCopyOfItsTextOffTheDisk() {
        let store = makeStore()
        store.add(richCopy("hunter2-but-longer"), sourceApp: "Notes", now: at(0))
        store.add(text("other"), sourceApp: "Notes", now: at(1))
        #expect(itemsOnDisk() == 2)
        let item = store.add(text("hunter2-but-longer"), sourceApp: "Passwords", secret: true, now: at(2))
        #expect(itemsOnDisk() == 1)
        #expect(store.items.map(\.id) == [item.id, store.items[1].id])
        #expect(store.items.map(\.isSecret) == [true, false])
        #expect(store.items[0].sourceApp == "Passwords")
    }

    @Test func aSecretTakesARichCopyOfItsTextOutOfTheClearedHistory() {
        let store = makeStore()
        store.add(richCopy("hunter2-but-longer"), sourceApp: "Notes", now: at(0))
        store.add(text("other"), sourceApp: "Notes", now: at(1))
        store.archiveAll(now: at(2))
        store.add(text("hunter2-but-longer"), sourceApp: "Passwords", secret: true, now: at(3))
        #expect(store.archiveSummary?.count == 1)
        store.expireSecrets(now: at(1000))
        store.restoreArchive()
        #expect(store.items.map(\.content) == [text("other")])
    }

    @Test func theSameTextFromAnyAppIsTheSecretAgain() {
        let store = makeStore()
        store.add(text("hunter2-but-longer"), sourceApp: "Passwords", secret: true, now: at(0))
        let rich = store.add(richCopy("hunter2-but-longer"), sourceApp: "Notes", now: at(300))
        #expect(itemsOnDisk() == 0)
        #expect(store.items.count == 1)
        #expect(store.items[0].isSecret)
        #expect(store.items[0].expiresAt == at(900))
        // Copied again exactly, from an ordinary app: the same row, with a
        // fresh lifetime.
        store.add(richCopy("hunter2-but-longer"), sourceApp: "Notes", now: at(400))
        #expect(store.items.count == 1)
        #expect(store.items[0].expiresAt == at(1000))
        #expect(store.items[0].id == rich.id)
    }

    @Test func keepingASecretAsOrdinarySavesIt() {
        let store = makeStore()
        let item = store.add(text(fakeAnthropicKey), sourceApp: "Ghostty", secret: true, now: at(0))
        store.keepAsOrdinary(item.id)
        #expect(store.items.map(\.isSecret) == [false])
        #expect(itemsOnDisk() == 1)
        #expect(!store.expireSecrets(now: at(1000)))
        #expect(makeStore().items.map(\.content) == [text(fakeAnthropicKey)])
        // Copied again, it is not taken for a secret this run.
        store.add(text(fakeAnthropicKey), sourceApp: "Ghostty", secret: true, now: at(1001))
        #expect(store.items.map(\.isSecret) == [false])
        #expect(itemsOnDisk() == 1)
    }

    @Test func clearingDropsSecretsAndArchivesTheRest() {
        let store = makeStore()
        store.add(text("plain"), sourceApp: nil, now: at(0))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: true, now: at(1))
        // Only what can be restored is counted.
        #expect(store.archiveAll(now: at(2)) == 1)
        #expect(store.items.isEmpty)
        #expect(store.archiveSummary?.count == 1)
        store.restoreArchive()
        #expect(store.items.map(\.content) == [text("plain")])
    }

    @Test func secretsDoNotPushSavedItemsOut() {
        let store = makeStore(limit: 2)
        store.add(text("oldest"), sourceApp: nil, now: at(0))
        store.add(text("newer"), sourceApp: nil, now: at(1))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: true, now: at(2))
        store.add(text(otherAnthropicKey), sourceApp: nil, secret: true, now: at(3))
        #expect(store.items.count == 4)
        #expect(itemsOnDisk() == 2)
        store.expireSecrets(now: at(1000))
        #expect(store.items.map(\.content) == [text("newer"), text("oldest")])
        // A saved copy past the limit still drops the oldest saved item.
        store.add(text(fakeGitHubToken), sourceApp: nil, secret: true, now: at(1001))
        store.add(text("newest"), sourceApp: nil, now: at(1002))
        #expect(store.items.map(\.content) == [text("newest"), text(fakeGitHubToken), text("newer")])
    }

    @Test func restoreLeavesSecretsOutOfItsRoom() {
        let store = makeStore(limit: 2)
        store.add(text("a"), sourceApp: nil, now: at(0))
        store.add(text("b"), sourceApp: nil, now: at(1))
        store.archiveAll(now: at(2))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: true, now: at(3))
        #expect(store.restoreArchive() == RestoreResult(restored: 2, noRoom: 0))
        #expect(store.items.count == 3)
    }

    @Test func clearingOnlySecretsKeepsThePreviousArchive() {
        let store = makeStore()
        store.add(text("plain"), sourceApp: nil, now: at(0))
        store.archiveAll(now: at(1))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: true, now: at(2))
        #expect(store.archiveAll(now: at(3)) == 0)
        #expect(store.items.isEmpty)
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(1)))
    }

    /// Ari's reproduction: the cleared copy of a password must not come
    /// back once the secret it became has expired.
    @Test func aClearedCopyOfASecretCannotBeRestored() {
        let store = makeStore()
        let password = "correct horse battery staple"
        store.add(text(password), sourceApp: "Notes", now: at(0))
        store.archiveAll(now: at(1))
        store.add(text(password), sourceApp: "Passwords", secret: true, now: at(2))
        #expect(store.archiveSummary == nil)
        store.expireSecrets(now: at(2 + HistoryStore.secretLifetime))
        #expect(store.items.isEmpty)
        #expect(store.restoreArchive().restored == 0)
        #expect(store.items.isEmpty)
        #expect(itemsOnDisk() == 0)
    }

    @Test func aSecretLeavesTheClearedHistoryAndTheRestStays() {
        let store = makeStore()
        store.add(text("plain"), sourceApp: nil, now: at(0))
        store.add(text(fakeAnthropicKey), sourceApp: nil, now: at(0))
        store.archiveAll(now: at(1))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: true, now: at(2))
        // The clear keeps its date, and so its time left.
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(1)))
        store.expireSecrets(now: at(2 + HistoryStore.secretLifetime))
        #expect(store.restoreArchive().restored == 1)
        #expect(store.items.map(\.content) == [text("plain")])
    }

    @Test func restoreDeletesTheArchivedCopyOfASecretInMemory() {
        let password = "correct horse battery staple"
        let store = makeStore()
        store.add(text(password), sourceApp: "Passwords", secret: true, now: at(0))
        // A copy reaches the cleared history after the secret was added,
        // here through another store on the same folder.
        let other = makeStore()
        other.add(text(password), sourceApp: "Notes", now: at(1))
        other.archiveAll(now: at(2))
        #expect(store.archiveSummary?.count == 1)

        #expect(store.restoreArchive().restored == 0)
        #expect(store.items.count == 1)
        #expect(store.items[0].isSecret)
        #expect(store.archiveSummary == nil)
        #expect(itemsOnDisk() == 0)
    }

    @Test func takingOverASecretDeletesItsClearedCopy() {
        let password = "correct horse battery staple"
        let store = makeStore()
        store.add(text(password), sourceApp: "Notes", now: at(0))
        store.archiveAll(now: at(1))
        let unsaved = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))
        unsaved.add(text(password), sourceApp: "Passwords", secret: true, now: at(2))
        store.adopt(unsaved)
        #expect(store.items.map(\.isSecret) == [true])
        #expect(store.archiveSummary == nil)
    }

    @Test func secretsHaveNoThumbnail() {
        let store = makeStore()
        let png = content(TypedData(type: TypeName.png, data: makePNG(width: 20, height: 20)))
        let item = store.add(png, sourceApp: nil, secret: true, now: at(0))
        // The panel and the preview read thumbnails from the storage.
        #expect(ItemStorage(root: root, cipher: testCipher).thumbnail(for: item.id) == nil)
    }
}

@Suite struct SecretDetectionTests {
    @Test func knownCredentialFormats() {
        for credential in [fakeAnthropicKey, fakeOpenAIKey, fakeGitHubToken, fakeAWSKey, fakeSlackToken, fakeJWT, fakePrivateKey] {
            #expect(Secrets.containsCredential(credential), "\(credential.prefix(8))")
            #expect(Secrets.containsCredential("export KEY=\(credential)\n"), "\(credential.prefix(8))")
        }
    }

    @Test func ordinaryTextIsNotASecret() {
        let ordinary = [
            "Meeting notes: Q4 planning",
            UUID().uuidString,
            String(repeating: "3f9a", count: 16), // a SHA-256 in hex
            "https://example.com/path?q=1",
            "risk-assessment-document-final", // 'sk-' inside a word
            "https://shop.example/sk-hynix-platinum-p41-2tb-ssd", // a slug
            "<div class=\"sk-loading-spinner-container-wide\">", // a CSS class
            "sk-" + String(repeating: "abc1", count: 10), // no capitals
            "git rebase --onto main feature~3 feature",
        ]
        for string in ordinary {
            #expect(!Secrets.containsCredential(string), "\(string)")
        }
    }

    @Test func passwordAppsMakeAnyCopyASecret() {
        let password = text("correct horse battery staple")
        #expect(Secrets.isSecret(password, frontmostBundleID: "com.apple.keychainaccess"))
        #expect(Secrets.isSecret(password, frontmostBundleID: "com.apple.Passwords"))
        #expect(!Secrets.isSecret(password, frontmostBundleID: "com.apple.Notes"))
        #expect(!Secrets.isSecret(password, frontmostBundleID: nil))
    }

    @Test func theCopysOwnSourceWinsOverTheFrontmostApp() {
        let marked = content(
            typed(TypeName.plainText, "correct horse battery staple"),
            typed(Secrets.sourceType, "com.bitwarden.desktop")
        )
        #expect(Secrets.isSecret(marked, frontmostBundleID: "com.apple.Notes"))
        let fromNotes = content(
            typed(TypeName.plainText, "correct horse battery staple"),
            typed(Secrets.sourceType, "com.apple.Notes")
        )
        #expect(!Secrets.isSecret(fromNotes, frontmostBundleID: "com.apple.keychainaccess"))
    }

    @Test func credentialsInTextMakeASecret() {
        #expect(Secrets.isSecret(text("token: \(fakeGitHubToken)"), frontmostBundleID: nil))
    }
}

@Suite struct SecretMaskTests {
    @Test func credentialKeepsItsPrefixAndLastFour() {
        #expect(Secrets.mask(fakeAnthropicKey) == "sk-ant-" + Secrets.dots + "Q4fZ")
        #expect(Secrets.mask(fakeGitHubToken) == "ghp_" + Secrets.dots + "WXYZ")
        #expect(Secrets.mask(fakeAWSKey) == "AKIA" + Secrets.dots + "MNOP")
    }

    @Test func twoKeysOfOneKindCanBeToldApart() {
        #expect(Secrets.mask(fakeAnthropicKey) != Secrets.mask(otherAnthropicKey))
    }

    @Test func aVariableNameBeforeTheCredentialStays() {
        #expect(Secrets.mask("export GH_TOKEN=\(fakeGitHubToken)") == "export GH_TOKEN=ghp_" + Secrets.dots + "WXYZ")
        #expect(Secrets.mask("api_key: \"\(fakeAnthropicKey)\";") == "api_key: \"sk-ant-" + Secrets.dots + "Q4fZ\";")
    }

    @Test func otherTextBesideTheCredentialIsHidden() {
        // An AWS key ID is usually followed by its secret key.
        #expect(Secrets.mask("\(fakeAWSKey) wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
            == "AKIA" + Secrets.dots + "MNOP " + Secrets.dots)
        #expect(Secrets.mask("export GH_TOKEN=\(fakeGitHubToken) DB_PASSWORD=hunter2")
            == "export GH_TOKEN=ghp_" + Secrets.dots + "WXYZ " + Secrets.dots)
        #expect(Secrets.mask("password=hunter2 token=\(fakeGitHubToken)")
            == Secrets.dots + " ghp_" + Secrets.dots + "WXYZ")
    }

    @Test func privateKeyHeaderStaysButAOneLineKeyDoesNot() {
        #expect(Secrets.mask("-----BEGIN OPENSSH PRIVATE KEY-----") == "-----BEGIN OPENSSH PRIVATE KEY-----")
        let oneLine = fakePrivateKey.replacingOccurrences(of: "\n", with: " ")
        #expect(Secrets.containsCredential(oneLine))
        #expect(!Secrets.mask(oneLine).contains("b3BlbnNzaC1rZXktdjEAAAAA"))
    }

    @Test func pgpPrivateKeyIsASecret() {
        #expect(Secrets.containsCredential("-----BEGIN PGP " + "PRIVATE KEY BLOCK-----\nlQOYBF..."))
        #expect(!Secrets.containsCredential("-----BEGIN PGP PUBLIC KEY BLOCK-----\nmQENBF..."))
    }

    @Test func passwordsShowNothing() {
        #expect(Secrets.mask("hunter2") == Secrets.dots)
        #expect(Secrets.mask("correct horse battery staple") == Secrets.dots)
        #expect(Secrets.mask("sixteen-chars-pw") == Secrets.dots)
    }

    @Test func aPasswordRowShowsAndSearchesNoneOfIt() {
        var item = makeItem(text("correct horse battery staple"))
        item.expiresAt = at(600)
        let row = RowPresentation(item)
        #expect(row.title == Secrets.dots)
        #expect(!row.matches("cor"))
        #expect(!row.matches("ple"))
        #expect(row.matches("secret"))
    }
}

@MainActor @Suite struct SecretRowTests {
    @Test func rowIsMaskedAndSearchesOnlyWhatShows() {
        var item = makeItem(text(fakeAnthropicKey))
        item.expiresAt = at(600)
        let row = RowPresentation(item)
        #expect(row.title == "sk-ant-" + Secrets.dots + "Q4fZ")
        #expect(row.matches("q4fz"))
        #expect(row.matches("secret"))
        #expect(!row.matches("xxxxxxxx"))
        #expect(!row.matches("api03"))
    }

    @Test func copyingAgainAsASecretMasksTheRowAlreadyShown() {
        let store = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))
        let model = PanelModel(store: store, now: { at(2) })
        let password = "correct horse battery staple"
        let plain = store.add(text(password), sourceApp: "Terminal", now: at(0))
        #expect(model.rows.map(\.presentation.title) == [password])

        // The same text again, this time with a password app in front.
        let secret = store.add(text(password), sourceApp: "Keychain Access", secret: true, now: at(1))
        #expect(secret.id == plain.id)
        #expect(model.rows.count == 1)
        #expect(model.rows[0].presentation.title == Secrets.dots)
        #expect(!model.rows[0].presentation.searchText.contains("correct"))
        #expect(model.rows[0].expiresIn != nil)
        model.query = "horse"
        #expect(model.rows.isEmpty)
    }

    @Test func panelShowsTimeLeft() {
        let store = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))
        store.add(text("plain"), sourceApp: nil, now: at(0))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: true, now: at(0))
        let model = PanelModel(store: store, now: { at(61) })
        model.open()
        #expect(model.rows.map(\.expiresIn) == ["9 min", nil])
    }

    @Test func remainingTimeRoundsUp() {
        #expect(remainingString(until: at(600), now: at(0)) == "10 min")
        #expect(remainingString(until: at(600), now: at(541)) == "1 min")
        #expect(remainingString(until: at(600), now: at(599)) == "1 min")
    }
}

/// The app in front, which a test changes as the user switches apps. On
/// the main actor, so the monitor's closures can read it while the test
/// changes it.
@MainActor final class FrontmostApp {
    private(set) var app: SourceApp

    init(_ name: String, _ bundleID: String) {
        app = SourceApp(name: name, bundleID: bundleID)
    }

    /// Brings another app to the front and tells the monitor, as the
    /// workspace's activation notification does.
    func switchTo(_ name: String, _ bundleID: String, monitor: ClipboardMonitor) {
        app = SourceApp(name: name, bundleID: bundleID)
        monitor.appDidActivate(app)
    }
}

@MainActor @Suite struct SecretMonitorTests {
    let pasteboard = FakePasteboard()
    let store = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))

    func makeMonitor(_ front: FrontmostApp) -> ClipboardMonitor {
        ClipboardMonitor(
            pasteboard: pasteboard, store: store,
            sourceApp: { front.app.name }, sourceBundleID: { front.app.bundleID }, now: { at(0) }
        )
    }

    @Test func aSecretIsPastedMarkedAsConcealed() {
        let front = FrontmostApp("Passwords", "com.apple.Passwords")
        let monitor = makeMonitor(front)
        let styled = content(typed(TypeName.plainText, "hunter2-but-longer"), typed(TypeName.rtf, "{rtf}"))
        pasteboard.copy(styled)
        monitor.tick()
        monitor.paste(store.items[0], plainText: false)
        monitor.paste(store.items[0], plainText: true)
        front.switchTo("Notes", "com.apple.Notes", monitor: monitor)
        monitor.tick()
        pasteboard.copy(text("plain"))
        monitor.tick()
        #expect(store.items.map(\.isSecret) == [false, true])
        monitor.paste(store.items[0], plainText: false)
        #expect(pasteboard.written == [
            styled.marked(TypeName.concealed),
            text("hunter2-but-longer").marked(TypeName.concealed),
            text("plain"),
        ])
    }

    @Test func monitorMarksCopiesFromPasswordApps() {
        let front = FrontmostApp("Keychain Access", "com.apple.keychainaccess")
        let monitor = makeMonitor(front)
        pasteboard.copy(text("correct horse battery staple"))
        monitor.tick()
        front.switchTo("Notes", "com.apple.Notes", monitor: monitor)
        monitor.tick()
        pasteboard.copy(text("shopping list"))
        monitor.tick()
        #expect(store.items.map(\.isSecret) == [false, true])
        #expect(store.items.map(\.sourceApp) == ["Notes", "Keychain Access"])
    }

    @Test func aPasswordCopiedJustBeforeSwitchingAwayIsASecret() {
        let front = FrontmostApp("Passwords", "com.apple.Passwords")
        let monitor = makeMonitor(front)
        pasteboard.copy(text("correct horse battery staple"))
        // Cmd+Tab before the next poll.
        front.switchTo("Safari", "com.apple.Safari", monitor: monitor)
        monitor.tick()
        #expect(store.items.count == 1)
        #expect(store.items[0].isSecret)
        #expect(store.items[0].sourceApp == "Passwords")
    }

    @Test func aCopySeenOnlyAfterLeavingAPasswordAppIsASecret() {
        let front = FrontmostApp("Passwords", "com.apple.Passwords")
        let monitor = makeMonitor(front)
        front.switchTo("Safari", "com.apple.Safari", monitor: monitor)
        // The password app's copy lands after the switch was handled.
        pasteboard.copy(text("correct horse battery staple"))
        monitor.tick()
        #expect(store.items.map(\.isSecret) == [true])
        // From the next poll on, Safari's copies are its own.
        pasteboard.copy(text("shopping list"))
        monitor.tick()
        #expect(store.items.map(\.isSecret) == [false, true])
    }

    @Test func aCopyMadeBeforeSwitchingToAPasswordAppIsNotASecret() {
        let front = FrontmostApp("Notes", "com.apple.Notes")
        let monitor = makeMonitor(front)
        pasteboard.copy(text("shopping list"))
        front.switchTo("Passwords", "com.apple.Passwords", monitor: monitor)
        monitor.tick()
        #expect(store.items.map(\.isSecret) == [false])
        #expect(store.items[0].sourceApp == "Notes")
    }

    @Test func aSwitchWhilePausedRecordsNothing() {
        let front = FrontmostApp("Passwords", "com.apple.Passwords")
        let monitor = makeMonitor(front)
        monitor.isPaused = true
        pasteboard.copy(text("correct horse battery staple"))
        front.switchTo("Safari", "com.apple.Safari", monitor: monitor)
        monitor.isPaused = false
        monitor.tick()
        #expect(store.items.isEmpty)
    }
}
