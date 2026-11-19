import Foundation
import Testing
import ClipboardCore

// Made-up credentials, built from pieces so that secret scanners never
// see anything that looks like a real one in the source.
let fakeAnthropicKey = "sk-ant-" + "api03-" + String(repeating: "x", count: 30) + "Q4fZ"
let otherAnthropicKey = "sk-ant-" + "api03-" + String(repeating: "x", count: 30) + "m81K"
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

    @Test func clearingOnlySecretsKeepsThePreviousArchive() {
        let store = makeStore()
        store.add(text("plain"), sourceApp: nil, now: at(0))
        store.archiveAll(now: at(1))
        store.add(text(fakeAnthropicKey), sourceApp: nil, secret: true, now: at(2))
        #expect(store.archiveAll(now: at(3)) == 0)
        #expect(store.items.isEmpty)
        #expect(store.archiveSummary == ArchiveSummary(count: 1, archivedAt: at(1)))
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
        for credential in [fakeAnthropicKey, fakeGitHubToken, fakeAWSKey, fakeSlackToken, fakeJWT, fakePrivateKey] {
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

    @Test func monitorMarksCopiesFromPasswordApps() {
        let pasteboard = FakePasteboard()
        let store = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))
        var frontmost = "com.apple.keychainaccess"
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard, store: store, sourceApp: { "Keychain Access" },
            sourceBundleID: { frontmost }, now: { at(0) }
        )
        pasteboard.copy(text("correct horse battery staple"))
        monitor.tick()
        frontmost = "com.apple.Notes"
        pasteboard.copy(text("shopping list"))
        monitor.tick()
        #expect(store.items.map(\.isSecret) == [false, true])
    }
}
