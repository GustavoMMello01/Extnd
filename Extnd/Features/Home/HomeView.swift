import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

struct HomeView: View {
    @ObservedObject var session: SharingSession
    @AppStorage("streamingMode") private var mode: StreamingMode = .mjpeg
    @AppStorage("blackViewerBorder") private var blackBorder = true
    @State private var preferredAddress: String?
    @State private var showsAdvanced = false
    @State private var fastCursor = false
    @State private var limitBitratePeaks = false
    @State private var copiedAddress = false

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
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let url = session.url {
                        connectionView(url: url)
                        Divider()
                        viewerSettings
                    } else {
                        setupView
                        Divider()
                        setting("Black border on iPad", isOn: $blackBorder)
                        if mode.usesWebRTC { advancedSettings }
                    }

                    if let message = session.message {
                        Label(message, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 22)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            Divider()
            footer
        }
        .frame(minWidth: 500, minHeight: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { session.refreshAddresses() }
        .onChange(of: blackBorder, initial: true) { _, value in session.showsBlackBorder = value }
        .onChange(of: session.url) { _, _ in copiedAddress = false }
    }

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading("Set Up Display", detail: "Connect your iPad to the same network as this Mac.")

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("Mac IP address")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if session.addresses.count > 1 {
                            Picker("Mac IP address", selection: addressSelection) {
                                ForEach(session.addresses, id: \.self) { Text($0).tag(Optional($0)) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        } else if let selectedAddress {
                            Text(selectedAddress).font(.system(.body, design: .monospaced))
                        } else {
                            Text("Unavailable").foregroundStyle(.secondary)
                        }

                        Button {
                            session.refreshAddresses()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("Refresh network")
                        .help("Refresh network")
                    }
                }

                GridRow {
                    Text("Streaming mode")
                        .foregroundStyle(.secondary)
                    Picker("Streaming mode", selection: $mode) {
                        ForEach(StreamingMode.allCases, id: \.self) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }
            .disabled(session.isBusy)
        }
    }

    private var advancedSettings: some View {
        DisclosureGroup("Advanced Options", isExpanded: $showsAdvanced) {
            VStack(spacing: 10) {
                setting("Experimental Fast Cursor", isOn: $fastCursor)
                setting("Reduce Bitrate Peaks (Experimental)", isOn: $limitBitratePeaks)
            }
            .padding(.top, 10)
        }
        .disabled(session.isBusy)
    }

    private func connectionView(url: URL) -> some View {
        HStack(spacing: 20) {
            if let qrImage = makeQRCode(for: url) {
                Image(decorative: qrImage, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 132, height: 132)
                    .padding(10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 1)
                    }
                    .accessibilityLabel("QR code for the extended display")
            }

            VStack(alignment: .leading, spacing: 9) {
                heading("Connect Your iPad", detail: "Scan the QR code or open the address in Safari.")

                Text(url.absoluteString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .accessibilityLabel("Extended display address: \(url.absoluteString)")

                Button(copiedAddress ? "Address Copied" : "Copy Address") {
                    NSPasteboard.general.clearContents()
                    copiedAddress = NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var viewerSettings: some View {
        VStack(spacing: 11) {
            setting("Black border on iPad", isOn: $blackBorder)
            setting("Show Streaming Stats on iPad", isOn: $session.showsStatistics)
            if session.usesWebRTC && session.showsStatistics {
                setting("Show Timing Details on iPad", isOn: $session.showsTiming)
            }
            if session.supportsFastCursor {
                setting("Experimental Fast Cursor", isOn: $session.fastCursorEnabled)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if session.url != nil {
                Text("Drag a window onto the Extnd display.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop Streaming") {
                    Task { await session.stop() }
                }
            } else {
                Spacer()
                if session.isBusy { ProgressView().controlSize(.small) }
                Button(session.isBusy ? "Starting…" : "Start Extended Display") {
                    guard let address = selectedAddress else { return }
                    Task {
                        await session.start(
                            address: address, mode: mode, fastCursor: fastCursor,
                            limitBitratePeaks: limitBitratePeaks
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(session.isBusy || selectedAddress == nil)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 12)
    }

    private func heading(_ title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

    private func makeQRCode(for url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let image = filter.outputImage else { return nil }
        return CIContext().createCGImage(image, from: image.extent)
    }
}
