import SwiftUI

@main
struct ChronoscopeApp: App {
    @State private var atlas = AtlasModel()
    var body: some Scene {
        WindowGroup {
            AtlasView(model: atlas)
                .preferredColorScheme(.dark)
                .tint(AtlasTheme.lime)
                .task {
                    #if DEBUG
                    let arguments = ProcessInfo.processInfo.arguments
                    if let index = arguments.firstIndex(of: "--import-atlas"), arguments.indices.contains(index + 1) {
                        await atlas.load(url: URL(fileURLWithPath: arguments[index + 1]))
                        await recordDeploymentReceipt()
                        return
                    }
                    #endif
                    await atlas.load()
                    await recordDeploymentReceipt()
                }
        }
        #if os(macOS)
        .defaultSize(width: 1440, height: 940)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Return to previous event") { atlas.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
            }
        }
        #endif
    }

    private func recordDeploymentReceipt() async {
        await CatalogDeploymentReceipt.recordIfRequested(
            displayedEvents: atlas.totalEventCount,
            displayedEdges: atlas.totalEdgeCount,
            embeddingModel: atlas.storeSummary?.embeddingModel ?? atlas.catalog?.embeddingModel ?? "",
            importedName: atlas.importedName)
    }
}
