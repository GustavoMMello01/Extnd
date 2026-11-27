import CoreGraphics
import Foundation
import XCTest
@testable import Extnd

final class FastCursorTests: XCTestCase {
    func testFastCursorPacketsNormalizeCoordinatesAndHideOutsideDisplay() {
        let bounds = CGRect(x: -1024, y: 40, width: 1024, height: 768)
        let inside = FastCursor.Position(point: CGPoint(x: -512, y: 424), bounds: bounds, active: true)
        XCTAssertEqual(inside.packet(sequence: 0x01020304), Data([3, 1, 2, 3, 4, 127, 255, 127, 255]))

        let outside = FastCursor.Position(point: CGPoint(x: 20, y: 424), bounds: bounds, active: true)
        XCTAssertEqual(outside.packet(sequence: 9), Data([1, 0, 0, 0, 9, 0, 0, 0, 0]))

        let disabled = FastCursor.Position(point: CGPoint(x: -512, y: 424), bounds: bounds, active: false)
        XCTAssertEqual(disabled.packet(sequence: 10).first, 2)
    }
}
