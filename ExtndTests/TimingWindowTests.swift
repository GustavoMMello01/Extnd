import XCTest
@testable import Extnd

final class TimingWindowTests: XCTestCase {
    func testTimingWindowReportsRecentPercentiles() throws {
        var timing = TimingWindow()
        let now: UInt64 = 10_000_000_000
        timing.record(1000, at: now - 5_000_000_000)
        timing.record(-1, at: now)
        for value in 1...20 { timing.record(Double(value), at: now) }

        let summary = try XCTUnwrap(timing.summarize(at: now))
        XCTAssertEqual(summary.samples, 20)
        XCTAssertEqual(summary.p50, 10)
        XCTAssertEqual(summary.p95, 19)
        XCTAssertNil(timing.summarize(at: now + 5_000_000_000))
    }
}
