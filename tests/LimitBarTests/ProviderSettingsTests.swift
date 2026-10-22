import XCTest
@testable import LimitBar

final class ProviderSettingsTests: XCTestCase {
    private var suite: String!
    private var preferences: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "LimitBarTests.\(UUID().uuidString)"
        preferences = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        preferences.removePersistentDomain(forName: suite)
        preferences = nil
        super.tearDown()
    }

    private func store() -> Store {
        Store(previewSnapshots: [
            .claude: Snapshot(vendor: .claude), .codex: Snapshot(vendor: .codex),
            .grok: .status(.grok, .signedOut), .gemini: .status(.gemini, .missing)
        ], preferences: preferences)
    }

    func testAllProvidersEnabledByDefault() {
        let store = store()
        XCTAssertEqual(store.enabled, Vendor.allCases)
        XCTAssertEqual(store.installed, [.claude, .codex, .grok])
    }

    func testHiddenProvidersDisappearAndStayHiddenAfterRestart() {
        let original = store()
        original.setEnabled(.grok, false)
        original.setEnabled(.gemini, false)
        XCTAssertEqual(original.enabled, [.claude, .codex])
        XCTAssertEqual(original.installed, [.claude, .codex])
        let restored = store()
        XCTAssertEqual(restored.enabled, [.claude, .codex])
        XCTAssertEqual(restored.hiddenVendors, [.gemini, .grok])
    }

    func testHiddenProvidersCannotBePolledEvenOnForcedRefresh() {
        let store = store()
        store.setEnabled(.grok, false)
        XCTAssertFalse(store.shouldPoll(.grok, force: true, olderThan: nil))
        XCTAssertFalse(store.shouldPoll(.grok, force: false, olderThan: 0))
        store.setEnabled(.grok, true)
        XCTAssertTrue(store.shouldPoll(.grok, force: true, olderThan: nil))
        XCTAssertEqual(store.installed, [.claude, .codex, .grok])
    }

    func testAllProvidersCanBeHiddenAndOneRestored() {
        let store = store()
        for vendor in Vendor.allCases { store.setEnabled(vendor, false) }
        XCTAssertTrue(store.enabled.isEmpty)
        XCTAssertTrue(store.installed.isEmpty)
        XCTAssertFalse(store.visibleBusy)
        let restored = self.store()
        XCTAssertTrue(restored.enabled.isEmpty)
        restored.setEnabled(.codex, true)
        XCTAssertEqual(restored.enabled, [.codex])
        XCTAssertEqual(restored.installed, [.codex])
    }

    func testUnknownStoredProvidersAreIgnored() {
        preferences.set(["grok", "future-provider"], forKey: "hiddenProviders")
        let store = store()
        XCTAssertEqual(store.hiddenVendors, [.grok])
        XCTAssertEqual(store.enabled, [.claude, .gemini, .codex])
    }

    func testRepeatedSelectionDoesNotToggleOtherProviders() {
        let store = store()
        store.setEnabled(.grok, false)
        store.setEnabled(.grok, false)
        store.setEnabled(.claude, true)
        XCTAssertEqual(self.store().hiddenVendors, [.grok])
    }
}
