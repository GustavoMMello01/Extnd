import Foundation
import XCTest

final class AppBundleTests: XCTestCase {
    func testHostBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "io.extnd.Extnd")
    }

    func testBundledMacIcon() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
        XCTAssertNotNil(Bundle.main.url(forResource: "Assets", withExtension: "car"))
        XCTAssertNotNil(Bundle.main.url(forResource: "AppIcon", withExtension: "icns"))
    }

    func testMinimumSupportedMacOSVersion() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
            "14.0"
        )
    }
}
