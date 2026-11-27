import Foundation
import XCTest
@testable import Extnd

final class WebRTCRelayTests: XCTestCase {
    @MainActor
    func testBundledRelayRegistersAnOpenViewerAndAcceptsKeyFrameRequests() async throws {
        let server = try LocalScreenServer(address: "127.0.0.1", transport: .webRTC)
        defer { server.stop() }
        let listening = expectation(description: "Capture server is listening")
        let registered = expectation(description: "Bundled relay reported its viewer")
        var sourceURL: URL?
        var viewerURL: URL?
        server.onReady = { url in
            sourceURL = url
            listening.fulfill()
        }
        server.onViewerReady = { url in
            viewerURL = url
            registered.fulfill()
        }
        server.start()
        await fulfillment(of: [listening], timeout: 5)

        let source = try XCTUnwrap(sourceURL)
        let relay = Process()
        relay.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/extnd-webrtc")
        relay.arguments = ["-managed", "-source", source.absoluteString]
        try relay.run()
        defer { if relay.isRunning { relay.terminate() } }
        await fulfillment(of: [registered], timeout: 8)

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let viewer = try XCTUnwrap(viewerURL)
        let (page, response) = try await session.data(from: viewer)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let html = String(decoding: page, as: UTF8.self)
        XCTAssertTrue(html.contains("Start WebRTC"))
        XCTAssertFalse(html.contains("stream-frame"))
        try await verifyViewerIcons(session: session, viewer: viewer, html: html)

        let keyFrame = expectation(description: "Capture server requested a key frame")
        server.onKeyFrameRequest = { keyFrame.fulfill() }
        var request = URLRequest(url: source.appendingPathComponent("keyframe"))
        request.httpMethod = "POST"
        let (_, keyFrameResponse) = try await session.data(for: request)
        XCTAssertEqual((keyFrameResponse as? HTTPURLResponse)?.statusCode, 204)
        await fulfillment(of: [keyFrame], timeout: 2)
    }
}
