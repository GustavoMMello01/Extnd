import Foundation
import VideoToolbox
import os

struct H264Frame: Sendable {
    let bytes: Data
    let timestamp: UInt32
    let isKeyFrame: Bool

    var wireData: Data {
        var header = [UInt32(bytes.count).bigEndian, timestamp.bigEndian]
        var packet = header.withUnsafeMutableBytes { Data($0) }
        packet.append(bytes)
        return packet
    }
}

final class H264Encoder {
    private let needsKeyFrame = OSAllocatedUnfairLock(initialState: false)
    private let session: VTCompressionSession
    private let onFrame: @Sendable (H264Frame) -> Void

    init(
        width: Int32, height: Int32, framesPerSecond: Int32 = 30,
        onFrame: @escaping @Sendable (H264Frame) -> Void
    ) throws {
        var encoder: VTCompressionSession?
        try Self.check(VTCompressionSessionCreate(
            allocator: nil, width: width, height: height,
            codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &encoder
        ))
        guard let encoder else { throw EncodingError(status: -1) }
        do {
            try Self.check(VTSessionSetProperties(encoder, propertyDictionary: [
                kVTCompressionPropertyKey_RealTime: true,
                kVTCompressionPropertyKey_AllowFrameReordering: false,
                kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_Baseline_3_1,
                kVTCompressionPropertyKey_ExpectedFrameRate: framesPerSecond,
                kVTCompressionPropertyKey_MaxKeyFrameInterval: 30,
                kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 30.0 / Double(framesPerSecond),
                kVTCompressionPropertyKey_AverageBitRate: 2_000_000
            ] as CFDictionary))
            // Some encoder implementations do not support a frame delay limit.
            let frameDelay = framesPerSecond == 60 ? 0 : 1
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: frameDelay as CFNumber)
            try Self.check(VTCompressionSessionPrepareToEncodeFrames(encoder))
        } catch {
            VTCompressionSessionInvalidate(encoder)
            throw error
        }
        session = encoder
        self.onFrame = onFrame
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    func requestKeyFrame() {
        needsKeyFrame.withLock { $0 = true }
    }

    func encode(_ image: CVPixelBuffer, at time: CMTime) {
        let forceKeyFrame = needsKeyFrame.withLock { pending in
            defer { pending = false }
            return pending
        }
        let frameProperties = forceKeyFrame ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: image, presentationTimeStamp: time,
            duration: .invalid, frameProperties: frameProperties, infoFlagsOut: nil
        ) { [onFrame] status, _, sample in
            guard status == noErr, let sample, let frame = Self.makeFrame(sample) else { return }
            onFrame(frame)
        }
    }

    private static func makeFrame(_ sample: CMSampleBuffer) -> H264Frame? {
        guard let format = sample.formatDescription, let block = sample.dataBuffer else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let isKeyFrame = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool != true
        let startCode: [UInt8] = [0, 0, 0, 1]
        var annexB = Data()
        var parameterCount = 0
        var lengthField: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &parameterCount, nalUnitHeaderLengthOut: &lengthField
        ) == noErr, lengthField == 4 else { return nil }

        if isKeyFrame {
            for index in 0..<parameterCount {
                var pointer: UnsafePointer<UInt8>?
                var count = 0
                guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &count, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
                ) == noErr, let pointer else { return nil }
                annexB.append(contentsOf: startCode)
                annexB.append(pointer, count: count)
            }
        }

        var bytes = Data(count: CMBlockBufferGetDataLength(block))
        guard !bytes.isEmpty, bytes.withUnsafeMutableBytes({ destination in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: destination.count,
                                       destination: destination.baseAddress!)
        }) == noErr else { return nil }
        var offset = 0
        while offset + 4 <= bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                Int(UInt32(bigEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            offset += 4
            guard count > 0, count <= bytes.count - offset else { return nil }
            annexB.append(contentsOf: startCode)
            annexB.append(bytes[offset..<(offset + count)])
            offset += count
        }
        let rtpTime = CMTimeConvertScale(sample.presentationTimeStamp, timescale: 90_000, method: .default)
        guard offset == bytes.count, rtpTime.isNumeric, !annexB.isEmpty else { return nil }
        return H264Frame(bytes: annexB, timestamp: UInt32(truncatingIfNeeded: rtpTime.value), isKeyFrame: isKeyFrame)
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw EncodingError(status: status) }
    }

    private struct EncodingError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Could not initialize the H.264 encoder (\(status))." }
    }
}
