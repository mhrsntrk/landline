import XCTest
@testable import Landline

/// The key bar's catalog, its stored layout, and the settings file it lives in.
final class KeyBarLayoutTests: XCTestCase {

    // MARK: Catalog

    /// Ids are permanent: they are what `settings.json` holds. A rename would
    /// silently empty an existing user's bar.
    func testCatalogIdsAreUniqueAndStable() {
        let ids = KeyBarCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate catalog id")
        for id in ["esc", "tab", "ctrl", "alt", "leader",
                   "arrow.left", "arrow.down", "arrow.up", "arrow.right",
                   "sym.tilde", "sym.pipe", "sym.slash", "sym.hyphen"] {
            XCTAssertNotNil(KeyBarCatalog.entry(id: id), "\(id) is in the default layout")
        }
    }

    /// The catalog the brief asks for, present and sending the right bytes.
    func testCatalogCoversTheKeysAShellNeeds() {
        assertSends("esc", [0x1b])
        assertSends("tab", [0x09])
        assertSends("delete", [0x1b, 0x5b, 0x33, 0x7e])
        assertSends("home", [0x1b, 0x5b, 0x48])
        assertSends("end", [0x1b, 0x5b, 0x46])
        assertSends("pageup", [0x1b, 0x5b, 0x35, 0x7e])
        assertSends("pagedown", [0x1b, 0x5b, 0x36, 0x7e])

        assertSends("arrow.up", [0x1b, 0x5b, 0x41])
        assertSends("arrow.down", [0x1b, 0x5b, 0x42])
        assertSends("arrow.right", [0x1b, 0x5b, 0x43])
        assertSends("arrow.left", [0x1b, 0x5b, 0x44])

        assertSends("ctrl.c", [0x03])
        assertSends("ctrl.d", [0x04])
        assertSends("ctrl.z", [0x1a])
        assertSends("ctrl.l", [0x0c])
        assertSends("ctrl.r", [0x12])

        XCTAssertEqual(KeyBarCatalog.entry(id: "ctrl")?.action, .latchCtrl)
        XCTAssertEqual(KeyBarCatalog.entry(id: "alt")?.action, .latchAlt)
        XCTAssertEqual(KeyBarCatalog.entry(id: "leader")?.action, .latchLeader)
    }

    /// Every punctuation mark the brief lists, each sending itself.
    func testPunctuationIsComplete() {
        let expected = "~|/-_=+:;'\"`$&*()[]{}<>"
        let punctuation = KeyBarCatalog.groups.first { $0.id == "PUNCTUATION" }
        let labels = (punctuation?.entries ?? []).map(\.label).joined()
        XCTAssertEqual(labels.count, expected.count)
        for character in expected {
            XCTAssertTrue(labels.contains(character), "\(character) is missing from the catalog")
        }
        for entry in punctuation?.entries ?? [] {
            XCTAssertEqual(entry.action, .send(Array(entry.label.utf8)),
                           "\(entry.label) must send itself")
        }
    }

    private func assertSends(_ id: String, _ bytes: [UInt8],
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let entry = KeyBarCatalog.entry(id: id) else {
            return XCTFail("no catalog entry \(id)", file: file, line: line)
        }
        XCTAssertEqual(entry.action, .send(bytes), file: file, line: line)
    }

    // MARK: Default layout

    /// The default row is today's bar plus the leader, so an existing user
    /// opening this build sees no regression.
    func testDefaultLayoutIsTodaysRowPlusTheLeader() {
        let ids = KeyBarKey.defaultLayout.map(\.catalogID)
        XCTAssertEqual(ids, ["esc", "tab", "ctrl", "alt", "leader",
                             "arrow.left", "arrow.down", "arrow.up", "arrow.right",
                             "sym.tilde", "sym.pipe", "sym.slash", "sym.hyphen"])
        XCTAssertEqual(KeyBarKey.defaultLayout.compactMap(\.resolved).count,
                       KeyBarKey.defaultLayout.count,
                       "every default key must resolve")
    }

    // MARK: Resolution

    func testCustomKeyResolvesToItsBytes() {
        let key = KeyBarKey(label: "\u{2190}\u{2190}", sequence: "\\e[1;5D")
        let resolved = key.resolved
        XCTAssertEqual(resolved?.action, .send([0x1b, 0x5b, 0x31, 0x3b, 0x35, 0x44]))
        XCTAssertEqual(resolved?.label, "\u{2190}\u{2190}")
        XCTAssertEqual(key.settingsDetail, "1B 5B 31 3B 35 44")
    }

    /// A slot that cannot be drawn is dropped from the rendered bar rather than
    /// offered to a thumb as a key that does nothing.
    func testUnresolvableKeysAreDroppedFromTheBar() {
        XCTAssertNil(KeyBarKey(catalogID: "sym.fromTheFuture").resolved,
                     "an id this build has never heard of")
        XCTAssertNil(KeyBarKey(label: "X", sequence: "\\q").resolved,
                     "a sequence that no longer parses")
        XCTAssertNil(KeyBarKey(label: "  ", sequence: "^A").resolved,
                     "a key with no label has nothing to print")
        XCTAssertEqual(KeyBarKey(label: "X", sequence: "\\q").settingsDetail, "UNRESOLVED")
    }

    func testLatchKeysReportThemselvesAsLatches() {
        XCTAssertEqual(KeyBarKey(catalogID: "leader").settingsDetail, "LATCHES")
        XCTAssertEqual(KeyBarKey(catalogID: "esc").settingsDetail, "1B")
        XCTAssertEqual(KeyBarKey(catalogID: "leader").settingsName, "leader")
    }

    // MARK: Settings document

    func testRoundTrip() throws {
        var settings = AppSettings()
        settings.keyBar = [
            KeyBarKey(catalogID: "esc"),
            KeyBarKey(label: "^W", sequence: "\\x17"),
            KeyBarKey(catalogID: "leader"),
        ]
        let decoded = try AppSettings.decode(from: AppSettings.encode(settings))
        XCTAssertEqual(decoded, settings)
        XCTAssertEqual(decoded.keyBar[1].label, "^W")
        XCTAssertEqual(decoded.keyBar[1].sequence, "\\x17")
        XCTAssertEqual(decoded.keyBar[1].resolved?.action, .send([0x17]))
        XCTAssertEqual(decoded.keyBar.map(\.id), settings.keyBar.map(\.id),
                       "slot identity survives, so a reorder is not a rebuild")
    }

    /// A settings file written before the setting existed is the default row.
    func testMissingKeyBarDecodesToTheDefaultLayout() throws {
        let decoded = try AppSettings.decode(from: Data("{}".utf8))
        XCTAssertEqual(decoded.keyBar.map(\.catalogID), KeyBarKey.defaultLayout.map(\.catalogID))
    }

    /// An *explicitly* empty bar is a choice the user made, not a missing file,
    /// and must not be quietly refilled on the next launch.
    func testExplicitlyEmptyKeyBarIsKept() throws {
        let decoded = try AppSettings.decode(from: Data(#"{"keyBar":[]}"#.utf8))
        XCTAssertTrue(decoded.keyBar.isEmpty)
    }

    /// Same tolerance rule as `Host`: a document written by a newer build must
    /// not make this one refuse to read its settings.
    func testPartialKeyDecodes() throws {
        let document = #"{"keyBar":[{"catalogID":"esc"},{"label":"X","sequence":"^A"},{}]}"#
        let decoded = try AppSettings.decode(from: Data(document.utf8))
        XCTAssertEqual(decoded.keyBar.count, 3)
        XCTAssertEqual(decoded.keyBar[0].catalogID, "esc")
        XCTAssertEqual(decoded.keyBar[1].resolved?.action, .send([0x01]))
        XCTAssertNil(decoded.keyBar[2].resolved, "a slot with neither is dropped from the bar")
    }

    // MARK: Store

    private func makeStore() -> SettingsStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString).json")
        return SettingsStore(fileURL: url)
    }

    func testStoreStartsAtTheDefaultRow() {
        let store = makeStore()
        XCTAssertEqual(store.keyBar.map(\.catalogID), KeyBarKey.defaultLayout.map(\.catalogID))
        XCTAssertTrue(store.isDefaultKeyBar)
        XCTAssertEqual(store.resolvedKeyBar.count, 13)
    }

    func testStorePersistsAcrossInstances() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("settings-\(UUID().uuidString).json")
        let first = SettingsStore(fileURL: url)
        first.append(KeyBarKey(label: "GS", sequence: "git status\\n"))
        XCTAssertFalse(first.isDefaultKeyBar)

        let second = SettingsStore(fileURL: url)
        XCTAssertEqual(second.keyBar.count, 14)
        XCTAssertEqual(second.keyBar.last?.label, "GS")
        XCTAssertEqual(second.keyBar.last?.resolved?.action,
                       .send(Array("git status".utf8) + [0x0a]))
        try? FileManager.default.removeItem(at: url)
    }

    func testReorderAndRemove() {
        let store = makeStore()
        let original = store.keyBar.map(\.catalogID)

        let second = store.keyBar[1].id
        store.nudge(id: second, by: -1)
        XCTAssertEqual(store.keyBar[0].catalogID, original[1])
        XCTAssertEqual(store.keyBar[1].catalogID, original[0])

        // A nudge off either end is a no-op, not a crash.
        store.nudge(id: store.keyBar[0].id, by: -1)
        XCTAssertEqual(store.keyBar[0].catalogID, original[1])
        store.nudge(id: store.keyBar[store.keyBar.count - 1].id, by: 1)
        XCTAssertEqual(store.keyBar.count, original.count)

        store.remove(id: second)
        XCTAssertEqual(store.keyBar.count, original.count - 1)
        XCTAssertFalse(store.keyBar.contains { $0.id == second })
    }

    func testDragMove() {
        let store = makeStore()
        let original = store.keyBar.map(\.catalogID)
        store.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(store.keyBar.map(\.catalogID),
                       [original[1], original[2], original[0]] + original.dropFirst(3))
    }

    func testResetRestoresTheDefaultRow() {
        let store = makeStore()
        store.append(KeyBarKey(catalogID: "ctrl.c"))
        store.remove(id: store.keyBar[0].id)
        XCTAssertFalse(store.isDefaultKeyBar)

        store.resetKeyBar()
        XCTAssertTrue(store.isDefaultKeyBar)
        XCTAssertEqual(store.keyBar.map(\.catalogID), KeyBarKey.defaultLayout.map(\.catalogID))
    }

    func testReplaceEditsACustomKeyInPlace() {
        let store = makeStore()
        store.append(KeyBarKey(label: "X", sequence: "^A"))
        guard var key = store.keyBar.last else { return XCTFail("nothing appended") }
        let position = store.keyBar.count - 1
        key.sequence = "^B"
        store.replace(key)
        XCTAssertEqual(store.keyBar[position].resolved?.action, .send([0x02]))
        XCTAssertEqual(store.keyBar.count, 14, "editing does not append a second key")
    }

    /// Unresolvable slots stay in the file and stay out of the bar, so a
    /// downgrade followed by an upgrade does not quietly delete a row.
    func testUnresolvableSlotsAreKeptInStorageButNotDrawn() {
        let store = makeStore()
        store.append(KeyBarKey(catalogID: "sym.fromTheFuture"))
        XCTAssertEqual(store.keyBar.count, 14)
        XCTAssertEqual(store.resolvedKeyBar.count, 13)
    }
}
