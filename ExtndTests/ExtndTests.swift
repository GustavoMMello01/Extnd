import Foundation
import XCTest

final class ExtndTests: XCTestCase {
    func testHostBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "io.extnd.Extnd")
    }

    func testMinimumSupportedMacOSVersion() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
            "14.0"
        )
    }
}
