import CoreMedia
import Foundation
import XCTest
@testable import Extnd

final class WebSocketJPEGTests: XCTestCase {
    @MainActor
    func testWebSocketJPEGConfiguresFullResolutionAt60FPS() {
        let mode = StreamingMode.webSocketJPEG
        let configuration = mode.captureConfiguration(showsCursor: true)
        XCTAssertEqual(mode.transport, .webSocket)
        XCTAssertEqual(configuration.width, 1024)
        XCTAssertEqual(configuration.height, 768)
        XCTAssertEqual(configuration.minimumFrameInterval, CMTime(value: 1, timescale: 60))
    }

    @MainActor
    func testWebSocketViewerReceivesLatestJPEGOnRequest() async throws {
        let server = try LocalScreenServer(address: "127.0.0.1", transport: .webSocket)
        defer { server.stop() }
        let ready = expectation(description: "HTTP and WebSocket listeners are ready")
        var viewerURL: URL?
        server.onReady = { url in
            viewerURL = url
            ready.fulfill()
        }
        server.start()
        await fulfillment(of: [ready], timeout: 5)
        let viewer = try XCTUnwrap(viewerURL)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (page, _) = try await session.data(from: viewer)
        let html = String(decoding: page, as: UTF8.self)
        XCTAssertFalse(html.contains("stream-frame"))
        let portStart = try XCTUnwrap(html.range(of: #"data-websocket-port=""#)?.upperBound)
        let port = try XCTUnwrap(Int(html[portStart...].prefix(while: { $0.isNumber })))
        let endpoint = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(port)/"))
        var request = URLRequest(url: endpoint)
        request.setValue("http://127.0.0.1:\(try XCTUnwrap(viewer.port))", forHTTPHeaderField: "Origin")
        request.setValue(viewer.lastPathComponent, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let socket = session.webSocketTask(with: request)
        socket.resume()
        let deadline = Task {
            try await Task.sleep(for: .seconds(5))
            socket.cancel()
        }
        defer {
            deadline.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }

        let first = Data([0xFF, 0xD8, 0x01, 0xFF, 0xD9])
        let latest = Data([0xFF, 0xD8, 0x03, 0xFF, 0xD9])
        server.update(frame: first)
        try await socket.send(.string("next"))
        guard case .data(let firstReceived) = try await socket.receive() else {
            return XCTFail("Expected a binary JPEG frame")
        }
        XCTAssertEqual(firstReceived, first)

        server.update(frame: Data([0xFF, 0xD8, 0x02, 0xFF, 0xD9]))
        server.update(frame: latest)
        try await socket.send(.string("next"))
        guard case .data(let latestReceived) = try await socket.receive() else {
            return XCTFail("Expected a binary JPEG frame")
        }
        XCTAssertEqual(latestReceived, latest)
    }
}
