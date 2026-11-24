import CoreImage
import Foundation
import ImageIO
import ScreenCaptureKit

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let onFrame: @Sendable (Data) -> Void
    private let onFailure: @Sendable (String) -> Void

    init(onFrame: @escaping @Sendable (Data) -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        self.onFrame = onFrame
        self.onFailure = onFailure
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = buffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        if let jpeg = context.jpegRepresentation(
            of: image,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.55]
        ) {
            onFrame(jpeg)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onFailure(error.localizedDescription)
    }
}
