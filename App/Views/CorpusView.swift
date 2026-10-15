import SwiftUI

struct CorpusView: View {
    @Bindable var model: AtlasModel
    let onImport: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Your installed collection", systemImage: "externaldrive.badge.checkmark")
                        .font(.title2.weight(.semibold))
                    Text("Coverage and evidence for the atlas on this device.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                LabeledContent("Events", value: model.totalEventCount.formatted())
                LabeledContent("Indexed connections", value: model.totalEdgeCount.formatted())
                VStack(alignment: .leading, spacing: 5) {
                    Text("Collection").font(.subheadline).foregroundStyle(.secondary)
                    Text(model.importedName ?? "Bundled Wikimedia collection").font(.body)
                }
                .padding(.vertical, 4)
            }

            if let catalog = model.catalog {
                Section("Coverage") {
                    Text(catalog.coverage).font(.subheadline)
                    if !catalog.generatedAt.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Catalog date").font(.subheadline).foregroundStyle(.secondary)
                            Text(catalogDate(catalog.generatedAt)).font(.body)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }

            Section("Meaning and evidence") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Meaning space", systemImage: "sparkles").font(.headline)
                    Text(model.catalog?.embeddingModel ?? "No embedding model loaded")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("Each event vector places its summary in meaning space. Similarity finds related topics; it does not explain a historical cause.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                VStack(alignment: .leading, spacing: 10) {
                    Label("Sourced connections", systemImage: "link").font(.headline)
                    Text("A documented link means the source connects the topics, with its direction preserved. Open a connection’s evidence to inspect the source.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Section {
                Button(action: onImport) {
                    Label("Import a collection", systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .modifier(CorpusImportStyle())
                .listRowBackground(Color.clear)
                .accessibilityHint("Choose a JSON catalog or SQLite index in Files.")
                Text("Choose a JSON catalog or SQLite index. Large indexes are queried on disk.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("The desktop tools can build a larger index from Wikipedia. Import the exported file when it is ready to update this device’s collection.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                Text("Add more history")
            }

            Section("Dates and locations") {
                Text("The atlas contains dated records extracted from Wikimedia, with coverage stated above. Only records with known dates appear on the timeline. Missing coordinates remain in meaning space.")
                    .font(.subheadline)
                Text("Historical dates use a proleptic Gregorian timeline. Source calendar conversions and uncertainty qualifiers are not yet modeled; displayed precision comes from the source record.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                sourceLink("Wikipedia articles · CC BY-SA", systemImage: "doc.text",
                           url: "https://en.wikipedia.org/wiki/Wikipedia:Copyrights")
                sourceLink("Wikidata structured facts · CC0", systemImage: "point.3.connected.trianglepath.dotted",
                           url: "https://www.wikidata.org/wiki/Wikidata:Licensing")
                sourceLink("Official Wikimedia downloads", systemImage: "arrow.down.circle",
                           url: "https://dumps.wikimedia.org/")
            } header: {
                Text("Sources & attribution")
            } footer: {
                Text("Article summaries are adapted from Wikipedia. Each event links to its source; revision identifiers are kept when available. Wikimedia content retains its original license.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AtlasTheme.ink)
        .navigationTitle("Corpus & sources")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .frame(minHeight: 44)
                    .accessibilityLabel("Close corpus and sources")
            }
        }
    }

    private func sourceLink(_ title: String, systemImage: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 12) {
                Label(title, systemImage: systemImage)
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right").font(.footnote)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
        }
        .accessibilityHint("Open the Wikimedia source website.")
    }

    private func catalogDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractionalDate = formatter.date(from: value)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractionalDate ?? formatter.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct CorpusImportStyle: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glassProminent)
                .tint(AtlasTheme.lime).foregroundStyle(AtlasTheme.ink)
                .controlSize(.large).buttonBorderShape(.capsule)
        } else {
            content.buttonStyle(.borderedProminent)
                .tint(AtlasTheme.lime).foregroundStyle(AtlasTheme.ink)
                .controlSize(.large).buttonBorderShape(.capsule)
        }
    }
}
