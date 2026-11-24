import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit

@MainActor
final class SharingSession: ObservableObject {
    @Published private(set) var addresses = LocalScreenServer.localAddresses()
    @Published private(set) var url: URL?
    @Published private(set) var isBusy = false
    @Published private(set) var message: String?

    private var display: ExtndVirtualDisplay?
    private var server: LocalScreenServer?
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "io.extnd.capture", qos: .userInitiated)

    func refreshAddresses() {
        addresses = LocalScreenServer.localAddresses()
    }

    func start(address: String) async {
        guard !isBusy, server == nil else { return }
        message = nil
        guard LocalScreenServer.localAddresses().contains(address) else {
            refreshAddresses()
            message = "O endereço de rede mudou. Selecione um endereço e tente novamente."
            return
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            message = "Permita a gravação da tela nos Ajustes do Sistema e reabra o Extnd."
            return
        }

        isBusy = true
        defer { isBusy = false }
        do {
            guard let display = ExtndVirtualDisplay.make() else { throw SetupError.displayUnavailable }
            self.display = display
            let source = try await findDisplay(withID: display.displayID)
            guard CGDisplayIsInMirrorSet(display.displayID) == 0 else { throw SetupError.displayMirrored }
            let server = try LocalScreenServer(address: address)
            let output = ScreenCapture { [weak server] frame in
                Task { @MainActor in server?.update(frame: frame) }
            } onFailure: { [weak self, weak server] error in
                Task { @MainActor in
                    guard let self, let server, self.server === server else { return }
                    await self.stop(message: "Captura interrompida. \(error)")
                }
            }
            let filter = SCContentFilter(display: source, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = 1024
            configuration.height = 768
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 3
            configuration.showsCursor = true
            let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: captureQueue)
            try await stream.startCapture()
            self.stream = stream
            self.output = output
            self.server = server
            server.onReady = { [weak self, weak server] url in
                guard let self, let server, self.server === server else { return }
                self.url = url
            }
            server.onFailure = { [weak self, weak server] error in
                Task { @MainActor in
                    guard let self, let server, self.server === server else { return }
                    await self.stop(message: "Falha na rede local. \(error)")
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
        url = nil
        server.stop()
        if let stream { try? await stream.stopCapture() }
        stream = nil
        output = nil
        display = nil
        self.message = message
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
                "O macOS não disponibilizou a tela virtual do Extnd."
            case .displayMirrored:
                "A tela do Extnd apareceu em modo espelhado. Em Monitores, escolha a opção de tela estendida e tente novamente."
            }
        }
    }
}
