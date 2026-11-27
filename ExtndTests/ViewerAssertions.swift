import Foundation
import XCTest

@MainActor
func verifyViewerIcons(session: URLSession, viewer: URL, html: String) async throws {
    for name in ["favicon", "apple-touch-icon"] {
        let file = name + ".png"
        XCTAssertTrue(html.contains("href=\"" + file + "\""))
        let (data, response) = try await session.data(from: viewer.appendingPathComponent(file))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(response.mimeType, "image/png")
        let resource = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "png"))
        XCTAssertEqual(data, try Data(contentsOf: resource))
    }
}
