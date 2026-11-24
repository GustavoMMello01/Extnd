import SwiftUI

struct HomeView: View {
    @State private var showsProjectInfo = false

    var body: some View {
        ContentUnavailableView {
            Label("Extnd", systemImage: "display")
        } description: {
            Text("Use seu iPad como segunda tela do Mac. O suporte à conexão chegará em uma etapa futura.")
        } actions: {
            Button("Sobre esta versão") {
                showsProjectInfo = true
            }
        }
        .frame(minWidth: 440, minHeight: 320)
        .sheet(isPresented: $showsProjectInfo) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Sobre esta versão")
                    .font(.title2.bold())
                Text("Extnd está na fase inicial. Esta versão abre no Mac e apresenta o projeto.")
                Button("Fechar") {
                    showsProjectInfo = false
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(24)
            .frame(width: 360, alignment: .leading)
        }
    }
}
