import Foundation
import Testing
import ClipboardCore

@MainActor @Suite struct PanelModelTests {
    let store = HistoryStore(storage: ItemStorage(root: temporaryRoot(), cipher: testCipher))

    /// Adds items so that the last name given ends up newest (row 1).
    func makeModel(_ names: String..., apps: [String: String] = [:]) -> PanelModel {
        for (index, name) in names.enumerated() {
            store.add(text(name), sourceApp: apps[name] ?? "Notes", now: at(Double(index)))
        }
        let model = PanelModel(store: store, now: { at(600) })
        model.open()
        return model
    }

    func titles(_ model: PanelModel) -> [String] {
        model.rows.map(\.presentation.title)
    }

    @Test func anExpiredSecretLeavesTheSelectionInItsPlace() {
        let model = makeModel("a", "b")
        store.add(text("hunter2-but-longer"), sourceApp: "Passwords", secret: true, now: at(1))
        store.add(text("c"), sourceApp: "Notes", now: at(500))
        model.open()
        // c, secret, b, a
        model.moveSelection(by: 1)
        #expect(model.selectionIsSecret)
        store.expireSecrets(now: at(1000))
        #expect(titles(model) == ["c", "b", "a"])
        #expect(model.selectedItem?.content == text("b"))
    }

    @Test func notASecretShowsTheSelectedSecretInFull() {
        let model = makeModel("a")
        store.add(text("hunter2-but-longer"), sourceApp: "Passwords", secret: true, now: at(500))
        model.open()
        #expect(model.selectionIsSecret)
        #expect(titles(model) == [Secrets.dots, "a"])
        let id = model.selectedID
        model.keepSelectedAsOrdinary()
        #expect(!model.selectionIsSecret)
        #expect(model.selectedID == id)
        #expect(titles(model) == ["hunter2-but-longer", "a"])
    }

    @Test func openSelectsNewest() {
        let model = makeModel("a", "b", "c")
        #expect(titles(model) == ["c", "b", "a"])
        #expect(model.selectedID == model.rows[0].id)
        #expect(model.selectedItem?.content == text("c"))
        #expect(model.rows[0].sourceApp == "Notes")
        #expect(model.rows[0].age == "9 min")
    }

    @Test func openResetsQuerySelectionAndNotice() {
        let model = makeModel("a", "b", "c")
        model.query = "a"
        model.warning = "not saved"
        model.notice = "something"
        model.noticeLink = URL(string: "https://example.com")
        model.open()
        #expect(model.query == "")
        #expect(model.notice == nil)
        #expect(model.noticeLink == nil)
        // A warning is about something that lasts, and stays.
        #expect(model.warning == "not saved")
        #expect(titles(model) == ["c", "b", "a"])
        #expect(model.selectedID == model.rows[0].id)
    }

    @Test func countLabels() {
        let model = makeModel("apple", "banana", "cherry")
        #expect(model.countLabel == "3 items")
        model.query = "an"
        #expect(model.countLabel == "1 of 3")
        store.archiveAll(now: at(5))
        model.open()
        #expect(model.countLabel == "0 items")
        store.add(text("only"), sourceApp: nil, now: at(9))
        #expect(model.countLabel == "1 item")
    }

    @Test func moveSelectionClamps() {
        let model = makeModel("a", "b", "c")
        model.moveSelection(by: -1)
        #expect(model.selectedID == model.rows[0].id)
        model.moveSelection(by: 1)
        #expect(model.selectedID == model.rows[1].id)
        model.moveSelection(by: 5)
        #expect(model.selectedID == model.rows[2].id)
    }

    @Test func visibleItemOnlyForVisibleRows() {
        let model = makeModel("apple", "banana")
        let banana = model.rows[0].id
        #expect(model.visibleItem(banana)?.content == text("banana"))
        model.query = "apple"
        #expect(model.visibleItem(banana) == nil)
    }

    @Test func selectPicksAVisibleRowOnly() {
        let model = makeModel("apple", "banana", "cherry")
        model.select(model.rows[2].id)
        #expect(model.selectedItem?.content == text("apple"))

        let hidden = model.rows[1].id // banana
        model.query = "apple"
        model.select(hidden)
        #expect(model.selectedItem?.content == text("apple"))
    }

    @Test func queryFiltersAndSelectsFirstMatch() {
        let model = makeModel("apple pie", "banana", "apple tart")
        model.moveSelection(by: 1)
        model.query = "apple"
        #expect(titles(model) == ["apple tart", "apple pie"])
        #expect(model.selectedID == model.rows[0].id)
    }

    @Test func queryMatchesSourceApp() {
        let model = makeModel("one", "two", apps: ["one": "Xcode"])
        model.query = "xcode"
        #expect(titles(model) == ["one"])
    }

    @Test func rowsAreRenumberedWhenFiltered() {
        let model = makeModel("apple pie", "banana", "apple tart")
        #expect(model.rows.map(\.number) == [1, 2, 3])
        model.query = "apple"
        #expect(model.rows.map(\.number) == [1, 2])
    }

    @Test func tenthRowHasNoNumber() {
        for index in 0..<11 {
            store.add(text("item \(index)"), sourceApp: nil, now: at(Double(index)))
        }
        let model = PanelModel(store: store, now: { at(600) })
        model.open()
        #expect(model.rows[8].number == 9)
        #expect(model.rows[9].number == nil)
        #expect(model.rows[10].number == nil)
    }

    @Test func quickNumber() {
        let model = makeModel("a", "b", "c")
        #expect(model.item(quickNumber: 1)?.content == text("c"))
        #expect(model.item(quickNumber: 3)?.content == text("a"))
        #expect(model.item(quickNumber: 0) == nil)
        #expect(model.item(quickNumber: 4) == nil)
        #expect(model.item(quickNumber: 10) == nil)
        model.query = "a"
        #expect(model.item(quickNumber: 1)?.content == text("a"))
    }

    @Test func deleteSelectedMovesToNext() {
        let model = makeModel("a", "b", "c")
        model.moveSelection(by: 1)
        model.deleteSelected()
        #expect(titles(model) == ["c", "a"])
        #expect(model.selectedItem?.content == text("a"))
        #expect(store.items.count == 2)
    }

    @Test func deleteLastMovesToPrevious() {
        let model = makeModel("a", "b", "c")
        model.moveSelection(by: 2)
        model.deleteSelected()
        #expect(model.selectedItem?.content == text("b"))
    }

    @Test func deleteOnlyItemLeavesNoSelection() {
        let model = makeModel("a")
        model.deleteSelected()
        #expect(model.rows.isEmpty)
        #expect(model.selectedID == nil)
        #expect(model.selectedItem == nil)
        model.deleteSelected()
        model.moveSelection(by: 1)
        #expect(model.selectedID == nil)
    }

    @Test func escapeClearsQueryThenCloses() {
        let model = makeModel("a", "b")
        model.query = "a"
        #expect(model.escape() == .clearedQuery)
        #expect(model.query == "")
        #expect(titles(model) == ["b", "a"])
        #expect(model.escape() == .close)
    }

    @Test func selectedItemIsNilWhenNoMatches() {
        let model = makeModel("a", "b")
        model.query = "zzz"
        #expect(model.rows.isEmpty)
        #expect(model.selectedItem == nil)
        #expect(model.countLabel == "0 of 2")
    }

    @Test func storeChangeKeepsSelection() {
        let model = makeModel("a", "b", "c")
        model.moveSelection(by: 1)
        let selected = model.selectedID
        store.add(text("new"), sourceApp: "Safari", now: at(500))
        #expect(titles(model) == ["new", "c", "b", "a"])
        #expect(model.selectedID == selected)
        #expect(model.selectedItem?.content == text("b"))
    }

    @Test func storeChangeThatRemovesSelectionSelectsTheRowInItsPlace() {
        let model = makeModel("a", "b", "c")
        model.moveSelection(by: 1)
        store.remove(model.selectedID!)
        #expect(model.selectedItem?.content == text("a"))
        // The last row gone: the one before it.
        store.remove(model.selectedID!)
        #expect(model.selectedItem?.content == text("c"))
    }

    @Test func unknownSourceAppIsEmpty() {
        store.add(text("x"), sourceApp: nil, now: at(0))
        let model = PanelModel(store: store, now: { at(0) })
        model.open()
        #expect(model.rows[0].sourceApp == "")
        #expect(model.rows[0].age == "now")
    }
}
