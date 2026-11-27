import Combine
import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit

enum StreamingMode: String, CaseIterable {
    case mjpeg
    case webRTC30
    case webRTC60
    case webRTC60Balanced
    case webRTC60Compact
    case webSocketJPEG

    var title: String {
        switch self {
        case .mjpeg: "MJPEG"
        case .webRTC30: "WebRTC 30 fps"
        case .webRTC60, .webRTC60Balanced, .webRTC60Compact: "WebRTC 60 fps (\(width) × \(height))"
        case .webSocketJPEG: "WebSocket JPEG 60 fps (Experimental)"
        }
    }

    var transport: LocalScreenServer.Transport {
        switch self {
        case .mjpeg: .mjpeg
        case .webRTC30, .webRTC60, .webRTC60Balanced, .webRTC60Compact: .webRTC
        case .webSocketJPEG: .webSocket
        }
    }

    var usesWebRTC: Bool { transport == .webRTC }
    private var resolution: (width: Int, height: Int) {
        switch self {
        case .mjpeg, .webRTC30, .webSocketJPEG: (1024, 768)
        case .webRTC60: (768, 576)
        case .webRTC60Balanced: (704, 528)
        case .webRTC60Compact: (640, 480)
        }
    }

    var width: Int { resolution.width }
    var height: Int { resolution.height }

    var framesPerSecond: Int32 {
        switch self {
        case .mjpeg, .webRTC30: 30
        case .webRTC60, .webRTC60Balanced, .webRTC60Compact, .webSocketJPEG: 60
        }
    }

    func captureConfiguration(showsCursor: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: framesPerSecond)
        configuration.queueDepth = 3
        configuration.showsCursor = showsCursor
        if usesWebRTC {
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        return configuration
    }
}

@MainActor
final class SharingSession: ObservableObject {
    @Published private(set) var addresses = LocalScreenServer.localAddresses()
    @Published private(set) var url: URL?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?
    @Published var showsStatistics = false {
        didSet { server?.showsStatistics = showsStatistics }
    }

    @Published var showsTiming = false {
        didSet { server?.showsTiming = showsTiming }
    }
    @Published private(set) var usesWebRTC = false

    @Published private(set) var supportsFastCursor = false
    @Published var fastCursorEnabled = false {
        didSet { updateCursorMode() }
    }

    private var cursor: FastCursor?
    private var cursorUpdate: Task<Void, Never>?
    private var mode: StreamingMode?
    private var display: ExtndVirtualDisplay?
    private var server: LocalScreenServer?
    private var stream: SCStream?
    private var relay: Process?
    private var relayTimeout: Task<Void, Never>?
    private let captureQueue = DispatchQueue(label: "io.extnd.capture", qos: .userInitiated)

    func refreshAddresses() {
        addresses = LocalScreenServer.localAddresses()
    }

    func start(address: String, mode: StreamingMode, fastCursor: Bool, limitBitratePeaks: Bool) async {
        guard !isBusy, server == nil else { return }
        message = nil
        guard LocalScreenServer.localAddresses().contains(address) else {
            refreshAddresses()
            message = "The network address changed. Select an address and try again."
            return
        }
        let relayExecutable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/extnd-webrtc")
        if mode.usesWebRTC, !FileManager.default.isExecutableFile(atPath: relayExecutable.path) {
            message = "The WebRTC relay is missing. Rebuild Extnd in Xcode."
            return
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            message = "Allow screen recording in System Settings, then reopen Extnd."
            return
        }

        isBusy = true
        defer { if server == nil { isBusy = false } }
        do {
            guard let display = ExtndVirtualDisplay.make() else { throw SetupError.displayUnavailable }
            self.display = display
            let source = try await findDisplay(withID: display.displayID)
            guard CGDisplayIsInMirrorSet(display.displayID) == 0 else { throw SetupError.displayMirrored }
            let server = try LocalScreenServer(address: address, transport: mode.transport)
            let encoder = try mode.usesWebRTC ? H264Encoder(
                width: Int32(mode.width), height: Int32(mode.height), framesPerSecond: mode.framesPerSecond,
                limitBitratePeaks: limitBitratePeaks
            ) { [weak server] frame in
                Task { @MainActor in server?.update(h264: frame) }
            } : nil
            let output = ScreenCapture(encoder: encoder) { [weak server] frame in
                Task { @MainActor in server?.update(frame: frame) }
            } onFailure: { [weak self, weak server] error in
                Task { @MainActor in
                    guard let self, let server, self.server === server else { return }
                    await self.stop(message: "Screen capture stopped. \(error)")
                }
            }
            let filter = SCContentFilter(display: source, excludingWindows: [])
            let configuration = mode.captureConfiguration(showsCursor: true)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
            self.stream = stream
            self.output = output
            self.server = server
            self.mode = mode
            usesWebRTC = mode.usesWebRTC
            server.showsTiming = showsTiming
            if let encoder {
                server.peakLimitStatus = encoder.peakLimitStatus
                if encoder.peakLimitStatus == .unavailable {
                    message = "The encoder did not accept the bitrate peak limit. Streaming with the standard settings."
                }
            }
            supportsFastCursor = mode.usesWebRTC && fastCursor
            fastCursorEnabled = supportsFastCursor
            let displayID = display.displayID
            server.onCursorPort = { [weak self, weak server] port in
                guard let self, let server, self.server === server, self.supportsFastCursor, self.cursor == nil else { return }
                let cursor = FastCursor(port: port)
                self.cursor = cursor
                cursor.start(displayID: displayID)
            }
            server.onCursorReady = { [weak self, weak server] ready in
                guard let self, let server, self.server === server, let cursor = self.cursor else { return }
                cursor.viewerReady = ready
                self.updateCursorMode()
            }
            server.showsStatistics = showsStatistics
            if let encoder {
                server.onKeyFrameRequest = { [weak encoder] in encoder?.requestKeyFrame() }
            }
            server.onViewerReady = { [weak self, weak server] url in
                guard let self, let server, self.server === server, self.relay != nil, self.url == nil else { return }
                self.relayTimeout?.cancel()
                self.relayTimeout = nil
                self.url = url
                self.isBusy = false
            }
            server.onReady = { [weak self, weak server] source in
                guard let self, let server, self.server === server else { return }
                if mode.usesWebRTC {
                    self.startRelay(at: relayExecutable, source: source)
                } else {
                    self.url = source
                    self.isBusy = false
                }
            }
            server.onFailure = { [weak self, weak server] error in
                Task { @MainActor in
                    guard let self, let server, self.server === server else { return }
                    await self.stop(message: "Local network connection failed. \(error)")
                }
            }
            server.start()
        } catch {
            display = nil
            message = error.localizedDescription
        }
    }

    // The stream's delegate is weak. Keep the output until capture has stopped.
    private var output: ScreenCapture?

    func stop(message: String? = nil) async {
        guard let server else { return }
        isBusy = true
        defer { isBusy = false }
        self.server = nil
        cursorUpdate?.cancel()
        cursorUpdate = nil
        cursor?.stop()
        cursor = nil
        mode = nil
        usesWebRTC = false
        showsTiming = false
        supportsFastCursor = false
        fastCursorEnabled = false
        url = nil
        showsStatistics = false
        relayTimeout?.cancel()
        relayTimeout = nil
        let process = relay
        relay = nil
        if let process, process.isRunning { process.terminate() }
        server.stop()
        if let stream { try? await stream.stopCapture() }
        stream = nil
        output = nil
        display = nil
        self.message = message
    }

    private func updateCursorMode() {
        guard cursorUpdate == nil, let cursor, let stream, let mode else { return }
        cursorUpdate = Task { [weak self, weak cursor, weak stream] in
            guard let self, let cursor, let stream else { return }
            defer {
                if self.cursor === cursor { self.cursorUpdate = nil }
            }
            while !Task.isCancelled {
                let useOverlay = cursor.viewerReady && self.fastCursorEnabled
                guard useOverlay != cursor.hidesVideoCursor else { return }
                do {
                    try await stream.updateConfiguration(mode.captureConfiguration(showsCursor: !useOverlay))
                    guard self.cursor === cursor, !Task.isCancelled else { return }
                    cursor.hidesVideoCursor = useOverlay
                    self.server?.onKeyFrameRequest?()
                } catch {
                    guard self.cursor === cursor, !Task.isCancelled else { return }
                    self.message = "Could not switch the cursor mode. \(error.localizedDescription)"
                    return
                }
            }
        }
    }

    private func startRelay(at executable: URL, source: URL) {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-managed", "-source", source.absoluteString] + (supportsFastCursor ? ["-fast-cursor"] : [])
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard let self, self.relay === process else { return }
                await self.stop(message: "The WebRTC relay stopped (exit code \(process.terminationStatus)).")
            }
        }
        do {
            try process.run()
            relay = process
            relayTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                guard let self, self.relay === process, self.url == nil else { return }
                await self.stop(message: "The WebRTC relay did not start. Try starting a new session.")
            }
        } catch {
            Task { await stop(message: "Could not start the WebRTC relay. \(error.localizedDescription)") }
        }
    }

    private func findDisplay(withID id: CGDirectDisplayID) async throws -> SCDisplay {
        for _ in 0..<25 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let display = content.displays.first(where: { $0.displayID == id }) {
                return display
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SetupError.displayUnavailable
    }

    private enum SetupError: LocalizedError {
        case displayUnavailable, displayMirrored

        var errorDescription: String? {
            switch self {
            case .displayUnavailable:
                "macOS could not make the Extnd virtual display available."
            case .displayMirrored:
                "The Extnd display is mirrored. In Displays in System Settings, select Extended Display and try again."
            }
        }
    }
}
