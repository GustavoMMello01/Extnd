import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct HomeView: View {
    @ObservedObject var session: SharingSession
    @State private var preferredAddress: String?
    @State private var webRTC = false

    private var selectedAddress: String? {
        if let preferredAddress, session.addresses.contains(preferredAddress) {
            return preferredAddress
        }
        return session.addresses.first
    }

    private var addressSelection: Binding<String?> {
        Binding(get: { selectedAddress }, set: { preferredAddress = $0 })
    }

    private func makeQRCode(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let image = filter.outputImage else { return nil }
        return CIContext().createCGImage(image, from: image.extent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Extnd", systemImage: "display")
                .font(.largeTitle.bold())

            if let url = session.url {
                if session.isWebRTC {
                    Text("Copy this address to start the WebRTC relay. See the experiment README.")
                } else {
                    Text("Connect your iPad to the same network as your Mac, then scan the QR code or open the address in Safari.")
                }
                if !session.isWebRTC, let qrImage = makeQRCode(for: url) {
                    Image(decorative: qrImage, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 156, height: 156)
                        .padding(12)
                        .background(.white)
                        .accessibilityLabel("QR code for the extended display")
                }
                Text(url.absoluteString)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Extended display address")
                HStack {
                    Button("Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Button("Stop Streaming") {
                        Task { await session.stop() }
                    }
                }
                Text("Drag a window onto the Extnd display. You can arrange it in Displays in System Settings.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Use your iPad as an extended display for your Mac over your local network.")
                if session.addresses.isEmpty {
                    Text("Connect your Mac and iPad to the same network to continue.")
                } else {
                    Picker("Mac IP Address", selection: addressSelection) {
                        ForEach(session.addresses, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .fixedSize()
                    .disabled(session.isBusy)
                }
                Toggle("WebRTC Test (H.264)", isOn: $webRTC)
                    .disabled(session.isBusy)
                HStack {
                    Button("Start Extended Display") {
                        guard let address = selectedAddress else { return }
                        Task { await session.start(address: address, webRTC: webRTC) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isBusy || selectedAddress == nil)
                    Button("Refresh Network") { session.refreshAddresses() }
                        .disabled(session.isBusy)
                    if session.isBusy { ProgressView().controlSize(.small) }
                }
            }

            if let message = session.message {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(minWidth: 520, minHeight: 300, alignment: .leading)
        .onAppear { session.refreshAddresses() }
    }
}
