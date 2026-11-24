import CoreImage
import Foundation
import ImageIO
import ScreenCaptureKit

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let encoder: H264Encoder?
    private let onFrame: @Sendable (Data) -> Void
    private let onFailure: @Sendable (String) -> Void

    init(encoder: H264Encoder?, onFrame: @escaping @Sendable (Data) -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        self.encoder = encoder
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = buffer.imageBuffer else { return }
        if let encoder {
            encoder.encode(pixels, at: buffer.presentationTimeStamp, captureAgeMs: Self.captureAge(of: buffer))
            return
        }
        let image = CIImage(cvPixelBuffer: pixels)
        if let jpeg = context.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.55]
        ) {
            onFrame(jpeg)
        }
    }

    private static func captureAge(of buffer: CMSampleBuffer) -> Double? {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        guard let displayTime = attachments?.first?[.displayTime] as? UInt64, displayTime != 0 else { return nil }
        let display = CMClockMakeHostTimeFromSystemUnits(displayTime)
        let arrival = CMClockGetTime(CMClockGetHostTimeClock())
        let milliseconds = CMTimeSubtract(arrival, display).seconds * 1_000
        return milliseconds.isFinite && milliseconds >= 0 ? milliseconds : nil
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onFailure(error.localizedDescription)
    }
}
