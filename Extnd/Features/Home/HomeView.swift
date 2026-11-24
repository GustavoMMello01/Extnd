import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct HomeView: View {
    @ObservedObject var session: SharingSession
    @State private var preferredAddress: String?

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
                Text("Escaneie o código com a câmera do iPad ou abra o endereço no Safari. Use a mesma rede do Mac.")
                if let qrImage = makeQRCode(for: url) {
                    Image(decorative: qrImage, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 156, height: 156)
                        .padding(12)
                        .background(.white)
                        .accessibilityLabel("Código QR do endereço da tela estendida")
                }
                Text(url.absoluteString)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Endereço da tela estendida")
                HStack {
                    Button("Copiar endereço") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Button("Parar transmissão") {
                        Task { await session.stop() }
                    }
                }
                Text("Arraste uma janela para a tela Extnd. Use Ajustes do Sistema → Monitores para posicioná-la.")
                    .foregroundStyle(.secondary)
            } else {
                Text("Use seu iPad como tela estendida do Mac pela rede local.")
                if session.addresses.isEmpty {
                    Text("Conecte o Mac à rede Wi-Fi ou Ethernet do iPad para continuar.")
                } else {
                    Picker("Endereço do Mac", selection: addressSelection) {
                        ForEach(session.addresses, id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    .fixedSize()
                    .disabled(session.isBusy)
                }
                HStack {
                    Button("Iniciar tela estendida") {
                        guard let address = selectedAddress else { return }
                        Task { await session.start(address: address) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isBusy || selectedAddress == nil)
                    Button("Atualizar rede") { session.refreshAddresses() }
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
