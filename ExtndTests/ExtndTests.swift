import CoreMedia
import CoreVideo
import Foundation
import Network
import XCTest
@testable import Extnd

final class ExtndTests: XCTestCase {
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

extension ExtndTests {
    @MainActor
    private func verifyViewerIcons(session: URLSession, viewer: URL, html: String) async throws {
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

    @MainActor
    func testServerRequiresSessionURLAndReturnsLatestFrame() async throws {
        let server = try LocalScreenServer(address: "127.0.0.1")
        defer { server.stop() }
        let ready = expectation(description: "HTTP listener is ready")
        var sessionURL: URL?
        server.onReady = { url in
            sessionURL = url
            ready.fulfill()
        }
        server.start()
        await fulfillment(of: [ready], timeout: 5)
        let url = try XCTUnwrap(sessionURL)
        let frameURL = url.appendingPathComponent("frame.jpg")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let (page, pageResponse) = try await session.data(from: url)
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        let html = String(decoding: page, as: UTF8.self)
        XCTAssertTrue(html.contains(#"lang="en""#))
        XCTAssertTrue(html.contains("screen.mjpeg"))
        XCTAssertTrue(html.contains("frame.jpg"))
        XCTAssertTrue(html.contains(#"id="stream-frame""#))
        try await verifyViewerIcons(session: session, viewer: url, html: html)

        let (_, missingFrame) = try await session.data(from: frameURL)
        XCTAssertEqual((missingFrame as? HTTPURLResponse)?.statusCode, 503)

        let sample = Data([0xFF, 0xD8, 0xFF, 0xD9])
        server.update(frame: sample)
        let (frame, frameResponse) = try await session.data(from: frameURL)
        XCTAssertEqual(frame, sample)
        XCTAssertEqual((frameResponse as? HTTPURLResponse)?.mimeType, "image/jpeg")
        XCTAssertEqual((frameResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")

        let statsURL = url.appendingPathComponent("stats")
        let (hiddenStats, _) = try await session.data(from: statsURL)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: hiddenStats) as? [String: Bool],
                       ["enabled": false, "blackBorder": true])

        server.showsBlackBorder = false
        let (borderOff, _) = try await session.data(from: statsURL)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: borderOff) as? [String: Bool],
                       ["enabled": false, "blackBorder": false])
        server.showsBlackBorder = true

        server.showsStatistics = true
        let (shownStats, statsResponse) = try await session.data(from: statsURL)
        XCTAssertEqual((statsResponse as? HTTPURLResponse)?.mimeType, "application/json")
        let stats = try XCTUnwrap(JSONSerialization.jsonObject(with: shownStats) as? [String: Any])
        XCTAssertEqual(stats["enabled"] as? Bool, true)
        XCTAssertEqual(stats["codec"] as? String, "MJPEG")
        XCTAssertEqual(stats["frames"] as? Int, 1)
        XCTAssertEqual(stats["encodedBytes"] as? Int, sample.count)

        server.showsStatistics = false
        let (disabledStats, _) = try await session.data(from: statsURL)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: disabledStats) as? [String: Bool],
                       ["enabled": false, "blackBorder": true])

        let wrongURL = url.deletingLastPathComponent().appendingPathComponent("wrong/frame.jpg")
        let (_, denied) = try await session.data(from: wrongURL)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 404)
    }
}

extension ExtndTests {
    @MainActor
    func testStreamSendsMultipleFramesOnOneConnection() async throws {
        let server = try LocalScreenServer(address: "127.0.0.1")
        defer { server.stop() }
        let ready = expectation(description: "HTTP listener is ready")
        var sessionURL: URL?
        server.onReady = { url in
            sessionURL = url
            ready.fulfill()
        }
        server.start()
        await fulfillment(of: [ready], timeout: 5)
        let url = try XCTUnwrap(sessionURL)
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16(try XCTUnwrap(url.port))))
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        connection.start(queue: .main)
        let deadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            connection.cancel()
        }
        defer {
            deadline.cancel()
            connection.cancel()
        }

        let path = url.appendingPathComponent("screen.mjpeg").path
        connection.send(content: Data("GET \(path) HTTP/1.0\r\n\r\n".utf8), completion: .idempotent)

        let first = Data([0xFF, 0xD8, 0x12, 0x34, 0xFF, 0xD9])
        let second = Data([0xFF, 0xD8, 0x56, 0x78, 0xFF, 0xD9])
        var received = Data()
        server.update(frame: first)
        try await receive(first, on: connection, into: &received)
        server.update(frame: second)
        try await receive(second, on: connection, into: &received)

        let headers = String(decoding: received.prefix(256), as: UTF8.self)
        XCTAssertTrue(headers.hasPrefix("HTTP/1.0 200 OK"))
        XCTAssertTrue(headers.contains("multipart/x-mixed-replace; boundary=extnd-frame"))
        XCTAssertTrue(headers.contains("Content-Length: 6"))
    }

    @MainActor
    private func receive(_ marker: Data, on connection: NWConnection, into data: inout Data) async throws {
        while data.range(of: marker) == nil {
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { bytes, _, _, error in
                    if let bytes, !bytes.isEmpty {
                        continuation.resume(returning: bytes)
                    } else {
                        continuation.resume(throwing: error.map { $0 as any Error } ?? URLError(.networkConnectionLost))
                    }
                }
            }
            data.append(chunk)
        }
    }
}

extension ExtndTests {
    @MainActor
    func testH264EncoderProducesAnAnnexBKeyFrame() async throws {
        try await verifyH264KeyFrame(mode: .webRTC30)
    }

    @MainActor
    func testH264EncoderProducesAKeyFrameIn60FPSMode() async throws {
        try await verifyH264KeyFrame(mode: .webRTC60)
    }

    @MainActor
    func testH264PeakLimitKeepsTheEncoderUsable() async throws {
        try await verifyH264KeyFrame(mode: .webRTC60, limitBitratePeaks: true)
    }

    @MainActor
    private func verifyH264KeyFrame(mode: StreamingMode, limitBitratePeaks: Bool = false) async throws {
        let ready = expectation(description: "VideoToolbox returned an H.264 key frame")
        let encoder = try H264Encoder(
            width: Int32(mode.width), height: Int32(mode.height), framesPerSecond: mode.framesPerSecond,
            limitBitratePeaks: limitBitratePeaks
        ) { frame in
            XCTAssertTrue(frame.isKeyFrame)
            XCTAssertEqual(frame.bytes.prefix(4), Data([0, 0, 0, 1]))
            XCTAssertEqual(frame.bytes.dropFirst(4).first.map { $0 & 0x1F }, 7)
            XCTAssertEqual(frame.timestamp, 90_000)
            XCTAssertGreaterThanOrEqual(frame.encodingMs, 0)
            XCTAssertEqual(frame.captureAgeMs, 2.0)
            ready.fulfill()
        }
        XCTAssertEqual(encoder.peakLimitStatus == .off, !limitBitratePeaks)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            nil, mode.width, mode.height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &buffer
        ), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(image) {
            if let address = CVPixelBufferGetBaseAddressOfPlane(image, plane) {
                let size = CVPixelBufferGetBytesPerRowOfPlane(image, plane) * CVPixelBufferGetHeightOfPlane(image, plane)
                memset(address, plane == 0 ? 16 : 128, size)
            }
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        encoder.encode(image, at: CMTime(value: 1, timescale: 1), captureAgeMs: 2.0)
        await fulfillment(of: [ready], timeout: 5)
        withExtendedLifetime(encoder) {}
    }
}

extension ExtndTests {
    @MainActor
    func testBundledRelayRegistersAnOpenViewerAndAcceptsKeyFrameRequests() async throws {
        let server = try LocalScreenServer(address: "127.0.0.1", webRTC: true)
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

extension ExtndTests {
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

extension ExtndTests {
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
