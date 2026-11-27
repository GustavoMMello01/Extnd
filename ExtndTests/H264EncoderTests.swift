import CoreMedia
import CoreVideo
import Foundation
import XCTest
@testable import Extnd

final class H264EncoderTests: XCTestCase {
    @MainActor
    func testH264EncoderProducesAnAnnexBKeyFrame() async throws {
        try await verifyH264KeyFrame(mode: .webRTC30)
    }

    @MainActor
    func testH264EncoderProducesAKeyFrameIn60FPSMode() async throws {
        try await verifyH264KeyFrame(mode: .webRTC60)
    }

    @MainActor
    func testCompact60FPSModeConfiguresCaptureAndProducesAKeyFrame() async throws {
        let mode = StreamingMode.webRTC60Compact
        let configuration = mode.captureConfiguration(showsCursor: true)
        XCTAssertTrue(mode.usesWebRTC)
        XCTAssertEqual(configuration.width, 640)
        XCTAssertEqual(configuration.height, 480)
        XCTAssertEqual(configuration.minimumFrameInterval, CMTime(value: 1, timescale: 60))
        try await verifyH264KeyFrame(mode: mode)
    }

    @MainActor
    func testBalanced60FPSModeConfiguresCaptureAndProducesAKeyFrame() async throws {
        let mode = StreamingMode.webRTC60Balanced
        let configuration = mode.captureConfiguration(showsCursor: true)
        XCTAssertTrue(mode.usesWebRTC)
        XCTAssertEqual(configuration.width, 704)
        XCTAssertEqual(configuration.height, 528)
        XCTAssertEqual(configuration.minimumFrameInterval, CMTime(value: 1, timescale: 60))
        try await verifyH264KeyFrame(mode: mode)
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
