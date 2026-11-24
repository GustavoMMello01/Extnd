import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct HomeView: View {
    @ObservedObject var session: SharingSession
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("streamingMode") private var mode: StreamingMode = .mjpeg
    @State private var preferredAddress: String?
    @State private var showsAdvanced = false
    @State private var fastCursor = false
    @State private var limitBitratePeaks = false
    @State private var copiedAddress = false

    private var palette: ExtndPalette { ExtndPalette(dark: colorScheme == .dark) }

    private var selectedAddress: String? {
        if let preferredAddress, session.addresses.contains(preferredAddress) {
            return preferredAddress
        }
        return session.addresses.first
    }

    private var addressSelection: Binding<String?> {
        Binding(get: { selectedAddress }, set: { preferredAddress = $0 })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let url = session.url {
                    connectionPanel(url: url)
                    sessionControls
                } else {
                    setupPanel
                    if mode.usesWebRTC { advancedOptions }
                }

                if let message = session.message {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .foregroundStyle(palette.notice)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(palette.notice.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }

                if session.url == nil { startButton }
            }
            .frame(maxWidth: 600, alignment: .leading)
            .padding(.horizontal, 30)
            .padding(.top, 28)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(palette.text)
        .tint(palette.accent)
        .background {
            palette.background
                .overlay(alignment: .topTrailing) {
                    RadialGradient(
                        colors: [palette.accent.opacity(0.12), .clear],
                        center: .topTrailing, startRadius: 0, endRadius: 330
                    )
                    .allowsHitTesting(false)
                }
                .ignoresSafeArea()
        }
        .frame(minWidth: 490, minHeight: 420)
        .onAppear { session.refreshAddresses() }
        .onChange(of: session.url) { _, _ in copiedAddress = false }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "display")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(palette.accent)
                .frame(width: 52, height: 52)
                .background(palette.selection, in: RoundedRectangle(cornerRadius: 15))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Extnd")
                    .font(.system(size: 31, weight: .semibold))
                    .tracking(-1.2)
                    .accessibilityAddTraits(.isHeader)
                Text("Your iPad as a second display")
                    .font(.callout)
                    .foregroundStyle(palette.secondary)
            }
        }
        .padding(.bottom, 6)
    }

    private var setupPanel: some View {
        panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: "wifi")
                        .foregroundStyle(palette.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Local network").font(.headline)
                        if session.addresses.isEmpty {
                            Text("Connect your Mac and iPad to the same network.")
                                .font(.caption)
                                .foregroundStyle(palette.secondary)
                        }
                    }
                    Spacer()
                    if session.addresses.count > 1 {
                        Picker("Mac IP address", selection: addressSelection) {
                            ForEach(session.addresses, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } else if let selectedAddress {
                        Text(selectedAddress)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(palette.secondary)
                            .accessibilityLabel("Mac IP address: \(selectedAddress)")
                    }
                    Button {
                        session.refreshAddresses()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .frame(width: 30, height: 30)
                            .background(palette.inset, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh network")
                    .help("Refresh network")
                }

                Rectangle()
                    .fill(palette.line)
                    .frame(height: 1)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 9) {
                    Text("Streaming mode")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 8) {
                        ForEach(StreamingMode.allCases, id: \.self) { choice in
                            modeButton(choice)
                        }
                    }
                }
            }
        }
        .disabled(session.isBusy)
    }

    private func modeButton(_ choice: StreamingMode) -> some View {
        let selected = mode == choice
        return Button {
            mode = choice
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(choice.title).font(.system(size: 12, weight: .semibold))
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(palette.accent)
                            .accessibilityHidden(true)
                    }
                }
                Text(modeDescription(choice))
                    .font(.caption2)
                    .foregroundStyle(palette.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 57, alignment: .leading)
            .padding(.horizontal, 10)
            .background(selected ? palette.selection : palette.inset, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? palette.accent.opacity(0.65) : palette.line, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.title)
        .accessibilityHint(modeDescription(choice))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func modeDescription(_ choice: StreamingMode) -> String {
        switch choice {
        case .mjpeg: "Compatibility"
        case .webRTC30: "Sharper text"
        case .webRTC60: "Smoother motion"
        }
    }

    private var advancedOptions: some View {
        panel {
            DisclosureGroup(isExpanded: $showsAdvanced) {
                VStack(alignment: .leading, spacing: 10) {
                    setting("Experimental Fast Cursor", isOn: $fastCursor)
                    setting("Reduce Bitrate Peaks (Experimental)", isOn: $limitBitratePeaks)
                }
                .font(.callout)
                .padding(.top, 11)
            } label: {
                Label("Advanced options", systemImage: "slider.horizontal.3")
                    .font(.callout.weight(.medium))
            }
        }
        .disabled(session.isBusy)
    }

    private var startButton: some View {
        Button {
            guard let address = selectedAddress else { return }
            Task {
                await session.start(
                    address: address, mode: mode, fastCursor: fastCursor,
                    limitBitratePeaks: limitBitratePeaks
                )
            }
        } label: {
            HStack(spacing: 9) {
                if session.isBusy {
                    ProgressView().controlSize(.small)
                    Text("Starting…")
                } else {
                    Text("Start Extended Display")
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(ExtndPrimaryStyle(palette: palette))
        .keyboardShortcut(.defaultAction)
        .disabled(session.isBusy || selectedAddress == nil)
    }

    private func connectionPanel(url: URL) -> some View {
        panel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 18) {
                    if let qrImage = makeQRCode(for: url) {
                        Image(decorative: qrImage, scale: 1)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 132, height: 132)
                            .padding(12)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("QR code for the extended display")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect your iPad")
                            .font(.system(size: 21, weight: .semibold))
                            .tracking(-0.4)
                            .accessibilityAddTraits(.isHeader)
                        Text("Scan the QR code or open the address in Safari on the same network.")
                            .font(.callout)
                            .foregroundStyle(palette.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button {
                            NSPasteboard.general.clearContents()
                            copiedAddress = NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        } label: {
                            Label(copiedAddress ? "Address Copied" : "Copy Address",
                                  systemImage: copiedAddress ? "checkmark" : "doc.on.doc")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(palette.accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text(url.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(palette.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Extended display address: \(url.absoluteString)")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(palette.inset, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            panel {
                VStack(alignment: .leading, spacing: 10) {
                    setting("Show Streaming Stats on iPad", isOn: $session.showsStatistics)
                    if session.usesWebRTC && session.showsStatistics {
                        setting("Show Timing Details on iPad", isOn: $session.showsTiming)
                    }
                    if session.supportsFastCursor {
                        setting("Experimental Fast Cursor", isOn: $session.fastCursorEnabled)
                    }
                }
                .font(.callout)
            }

            HStack(spacing: 12) {
                Label("Drag a Mac window onto the Extnd display.", systemImage: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    Task { await session.stop() }
                } label: {
                    Label("Stop Streaming", systemImage: "stop.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(palette.notice)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(palette.notice.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func setting(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(title).accessibilityHidden(true)
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(palette.line, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }

    private func makeQRCode(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let image = filter.outputImage else { return nil }
        return CIContext().createCGImage(image, from: image.extent)
    }
}

private struct ExtndPalette {
    let background: Color
    let surface: Color
    let inset: Color
    let line: Color
    let text: Color
    let secondary: Color
    let accent: Color
    let selection: Color
    let onAccent: Color
    let notice: Color

    init(dark: Bool) {
        background = Color(extndHex: dark ? 0x101817 : 0xEFF4F0)
        surface = Color(extndHex: dark ? 0x192421 : 0xFCFEFC)
        inset = Color(extndHex: dark ? 0x131E1B : 0xF0F5F1)
        line = Color(extndHex: dark ? 0x33433C : 0xD5E1DA)
        text = Color(extndHex: dark ? 0xF0F6F2 : 0x15251F)
        secondary = Color(extndHex: dark ? 0xABBCB3 : 0x52665C)
        accent = Color(extndHex: dark ? 0xA3EDC6 : 0x146347)
        selection = Color(extndHex: dark ? 0x254438 : 0xE0F2E8)
        onAccent = Color(extndHex: dark ? 0x10291D : 0xFFFFFF)
        notice = Color(extndHex: dark ? 0xFFB8A8 : 0x8D382A)
    }
}

private struct ExtndPrimaryStyle: ButtonStyle {
    let palette: ExtndPalette
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isEnabled ? palette.onAccent : palette.secondary)
            .background(
                isEnabled ? palette.accent.opacity(configuration.isPressed ? 0.78 : 1) : palette.inset,
                in: RoundedRectangle(cornerRadius: 11)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11))
    }
}

private extension Color {
    init(extndHex value: UInt32) {
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
