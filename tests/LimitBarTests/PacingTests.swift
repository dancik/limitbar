import XCTest
@testable import LimitBar

final class PacingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func window(minutes: Int? = 300, used: Double? = 60, remaining: Double = 10_800) -> Window {
        Window(label: "Test", short: "5h", used: used, resetsAt: now.addingTimeInterval(remaining), durationMinutes: minutes)
    }

    func testFiveHourPacing() throws {
        let pace = try XCTUnwrap(window().pacing(at: now))
        XCTAssertEqual(pace.elapsedFraction, 0.4, accuracy: 0.00001)
        XCTAssertEqual(pace.difference, 20, accuracy: 0.00001)
        XCTAssertEqual(pace.summary, "20 pp over pace")
        XCTAssertEqual(pace.remainingText, "3h 0m left")
    }

    func testWeeklyPacing() throws {
        let pace = try XCTUnwrap(window(minutes: 10_080, used: 30, remaining: 302_400).pacing(at: now))
        XCTAssertEqual(pace.elapsedFraction, 0.5, accuracy: 0.00001)
        XCTAssertEqual(pace.summary, "20 pp under pace")
        XCTAssertFalse(pace.isOverPace)
        XCTAssertEqual(pace.remainingText, "3d 12h left")
    }

    func testStartEndAndInvalidReset() throws {
        XCTAssertEqual(try XCTUnwrap(window(used: 0, remaining: 18_000).pacing(at: now)).summary, "On pace")
        XCTAssertNil(window(remaining: 0).pacing(at: now))
        XCTAssertNil(window(remaining: -1).pacing(at: now))
        XCTAssertNil(window(remaining: 18_001).pacing(at: now))
        var missing = window()
        missing.resetsAt = nil
        XCTAssertNil(missing.pacing(at: now))
    }

    func testUnsupportedAndMissingDurations() {
        for duration in [nil, 60, 0, -1, 43_200] as [Int?] {
            XCTAssertNil(window(minutes: duration, remaining: 60).pacing(at: now))
        }
    }

    func testUnknownOrInvalidUsage() {
        for used in [nil, -1, 101, .infinity, .nan] as [Double?] {
            XCTAssertNil(window(used: used).pacing(at: now))
        }
    }

    func testTimeAdvancesWithoutNewReading() throws {
        let w = window()
        XCTAssertEqual(try XCTUnwrap(w.pacing(at: now.addingTimeInterval(3600))).summary, "On pace")
        XCTAssertEqual(try XCTUnwrap(w.pacing(at: now.addingTimeInterval(7200))).summary, "20 pp under pace")
    }

    func testRoundingAndCountdown() throws {
        let pace = try XCTUnwrap(window(used: 40.4).pacing(at: now))
        XCTAssertEqual(pace.summary, "On pace")
        XCTAssertFalse(pace.isOverPace)
        XCTAssertEqual(try XCTUnwrap(window(remaining: 1).pacing(at: now)).remainingText, "1m left")
    }

    func testOldCacheStillDecodesWithoutInventingDuration() throws {
        let data = Data(#"{"label":"Week","short":"w","used":30}"#.utf8)
        let old = try JSONDecoder().decode(Window.self, from: data)
        XCTAssertNil(old.durationMinutes)
        XCTAssertNil(old.pacing(at: now))
        let current = window(minutes: 10_080)
        XCTAssertEqual(try JSONDecoder().decode(Window.self, from: JSONEncoder().encode(current)), current)
    }
}
