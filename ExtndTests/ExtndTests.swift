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

    func testMinimumSupportedMacOSVersion() {
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String,
            "14.0"
        )
    }
}

extension ExtndTests {
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

        let (_, missingFrame) = try await session.data(from: frameURL)
        XCTAssertEqual((missingFrame as? HTTPURLResponse)?.statusCode, 503)

        let sample = Data([0xFF, 0xD8, 0xFF, 0xD9])
        server.update(frame: sample)
        let (frame, frameResponse) = try await session.data(from: frameURL)
        XCTAssertEqual(frame, sample)
        XCTAssertEqual((frameResponse as? HTTPURLResponse)?.mimeType, "image/jpeg")
        XCTAssertEqual((frameResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")

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
        let ready = expectation(description: "VideoToolbox returned an H.264 key frame")
        let encoder = try H264Encoder(width: 1024, height: 768) { frame in
            XCTAssertTrue(frame.isKeyFrame)
            XCTAssertEqual(frame.bytes.prefix(4), Data([0, 0, 0, 1]))
            XCTAssertEqual(frame.bytes.dropFirst(4).first.map { $0 & 0x1F }, 7)
            XCTAssertEqual(frame.timestamp, 90_000)
            ready.fulfill()
        }
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(
            nil, 1024, 768, kCVPixelFormatType_32BGRA, nil, &buffer
        ), kCVReturnSuccess)
        let image = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(image, [])
        if let address = CVPixelBufferGetBaseAddress(image) {
            memset(address, 0, CVPixelBufferGetDataSize(image))
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        encoder.encode(image, at: CMTime(value: 1, timescale: 1))
        await fulfillment(of: [ready], timeout: 5)
        withExtendedLifetime(encoder) {}
    }
}
