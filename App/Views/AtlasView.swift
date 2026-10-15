import SwiftUI
import UniformTypeIdentifiers
import ChronoscopeCore

private enum AtlasTab: Hashable {
    case walk, bridge, events
}

struct AtlasView: View {
    @Bindable var model: AtlasModel
    @State private var tab = AtlasTab.walk
    @State private var detail: AtlasEvent?
    @State private var corpusOpen = false
    @State private var importOpen = false
    @State private var importAfterCorpus = false
    @State private var footerHeight: CGFloat = 224

    var body: some View {
        Group {
            if model.loading {
                ProgressView("Opening the event atlas…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.error {
                ContentUnavailableView {
                    Label("Atlas unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        Task {
                            if model.catalog != nil { model.error = nil; model.refresh() }
                            else { await model.load() }
                        }
                    }.buttonStyle(.glassProminent)
                    Button("Import catalog") { importOpen = true }.buttonStyle(.glass)
                }
            } else {
                TabView(selection: $tab) {
                    Tab("Walk", systemImage: "move.3d", value: AtlasTab.walk) {
                        NavigationStack { map }
                    }
                    Tab("7 Degrees", systemImage: "point.3.connected.trianglepath.dotted", value: AtlasTab.bridge) {
                        NavigationStack {
                            BridgeView(model: model) { id in model.select(id); tab = .walk }
                        }
                    }
                    Tab("Search", systemImage: "magnifyingglass", value: AtlasTab.events, role: .search) {
                        NavigationStack { index }
                    }
                }
            }
        }
        .background(AtlasTheme.ink)
        .sheet(item: $detail) { event in
            NavigationStack { EventDetailView(event: event, model: model) }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $corpusOpen, onDismiss: {
            if importAfterCorpus { importAfterCorpus = false; importOpen = true }
        }) {
            NavigationStack {
                CorpusView(model: model) { importAfterCorpus = true; corpusOpen = false }
            }.presentationDragIndicator(.visible)
        }
        .fileImporter(isPresented: $importOpen, allowedContentTypes: [.json, .database, .data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    let allowed = url.startAccessingSecurityScopedResource()
                    defer { if allowed { url.stopAccessingSecurityScopedResource() } }
                    await model.load(url: url)
                }
            case .failure(let error): model.error = error.localizedDescription
            }
        }
    }

    private var map: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 600
            ZStack(alignment: .bottom) {
                SpatialAtlasView(
                    nodes: spatialNodes, links: spatialLinks,
                    focusID: model.selectedID,
                    spaceTitle: model.geographical ? "EARTH + TIME" : "MEANING SPACE",
                    minimumViewportHeight: 0,
                    controlsBottomInset: footerHeight + 10
                ) { model.select($0) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                GlassEffectContainer(spacing: 8) {
                    if compact && geometry.size.width > 600 {
                        HStack(alignment: .bottom, spacing: 12) {
                            if let selected = model.selected {
                                selectedInspector(selected, compact: true)
                                    .frame(width: min(260, geometry.size.width * 0.32))
                            }
                            TimelineControl(model: model, compact: true)
                        }
                    } else {
                        VStack(spacing: 10) {
                            if let selected = model.selected { selectedInspector(selected, compact: compact) }
                            TimelineControl(model: model, compact: compact)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
            }
        }
        .background(AtlasTheme.ink)
        .navigationTitle("Chronoscope")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Return one step", systemImage: "arrow.uturn.backward") { model.goBack() }
                        .disabled(model.trail.count < 2)
                    Section("Recent walk") {
                        ForEach(Array(model.trail.suffix(8).enumerated()), id: \.offset) { _, id in
                            Button(model.event(id)?.title ?? id) { model.select(id) }
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .accessibilityLabel("Walk history")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Layout", selection: $model.geographical) {
                        Text("Meaning space").tag(false)
                        Text("Earth coordinates").tag(true)
                    }
                    Toggle("Suggested connections", isOn: $model.semanticLinks)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Map options")
                Button { corpusOpen = true } label: {
                    Image(systemName: "externaldrive.badge.checkmark")
                }
                .accessibilityLabel("Corpus and sources")
            }
        }
        .onChange(of: model.semanticLinks) { model.refresh() }
    }

    private func selectedInspector(_ selected: AtlasEvent, compact: Bool) -> some View {
        Button { detail = selected } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(AtlasTheme.category(selected.category))
                    .frame(width: 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected.title).font(.headline).foregroundStyle(.primary).lineLimit(compact ? 1 : 2)
                    Text(selected.dateLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if !model.selectedIsInWindow {
                        Label("Outside the current view", systemImage: "pin.fill")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16).padding(.vertical, compact ? 10 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect(cornerRadius: 24))
            .atlasGlass(interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(selected.title), \(selected.dateLabel)")
        .accessibilityValue(model.selectedIsInWindow ? "" : "Pinned event outside this time window or category")
        .accessibilityHint("Opens the event, source, and its connections")
    }

    private var spatialNodes: [SpatialNode] {
        model.visible.map {
            SpatialNode(id: $0.id, title: $0.title, position: model.position($0),
                        color: AtlasTheme.category($0.category).opacity($0.id == model.selectedID && !model.selectedIsInWindow ? 0.4 : 1),
                        emphasized: $0.id == model.selectedID && model.selectedIsInWindow)
        }
    }

    private var spatialLinks: [SpatialLink] {
        guard let selectedID = model.selectedID else { return [] }
        let visibleIDs = Set(model.visible.map(\.id))
        return model.neighbors.filter { visibleIDs.contains($0.event.id) }.map {
            SpatialLink(source: selectedID, target: $0.event.id, color: $0.semantic ? AtlasTheme.violet : AtlasTheme.cyan, isSemantic: $0.semantic)
        }
    }

    private var index: some View {
        List {
            Section("Time window") {
                Picker("Category", selection: $model.category) {
                    ForEach(model.categories, id: \.self) { Text($0).tag($0) }
                }
                Text("\(model.windowCount.formatted()) events · \(model.matches.count.formatted()) shown")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section("Events") {
                ForEach(model.matches) { event in
                    Button { model.select(event.id); tab = .walk } label: {
                        HStack(spacing: 12) {
                            EventRow(event: event)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if model.matches.isEmpty { ContentUnavailableView.search(text: model.query) }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(AtlasTheme.ink)
        .navigationTitle("Events")
        .searchable(text: $model.query, prompt: "Search events")
        .onChange(of: model.query) { model.refresh() }
        .onChange(of: model.category) { model.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { corpusOpen = true } label: { Image(systemName: "externaldrive") }
                    .accessibilityLabel("Corpus and sources")
            }
        }
    }
}

struct EventRow: View {
    let event: AtlasEvent
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(AtlasTheme.category(event.category)).frame(width: 8, height: 8).padding(.top, 6)
            VStack(alignment: .leading, spacing: 5) {
                Text(event.title).font(.headline).foregroundStyle(.primary)
                Text(event.dateLabel).font(.system(.caption, design: .monospaced)).foregroundStyle(AtlasTheme.cyan)
                Text(event.summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }.padding(.vertical, 6)
    }
}

struct EventDetailView: View {
    let event: AtlasEvent
    @Bindable var model: AtlasModel
    @Environment(\.dismiss) private var dismiss
    @State private var expandedSummary = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    AtlasBadge(text: event.category, color: AtlasTheme.category(event.category))
                    Text(event.title).font(.title2.weight(.bold))
                    Text(event.dateLabel).font(.subheadline).foregroundStyle(.secondary)
                    Text(event.summary).font(.body).lineLimit(expandedSummary ? nil : 6).textSelection(.enabled)
                    if event.summary.count > 350 {
                        Button(expandedSummary ? "Show less" : "Read more") { expandedSummary.toggle() }
                            .frame(minHeight: 44)
                    }
                    HStack {
                        AtlasBadge(text: "\(event.precision.capitalized) precision", color: .secondary)
                        if event.hasLocation { AtlasBadge(text: "Located", color: AtlasTheme.cyan) }
                    }
                }.padding(.vertical, 6)
                if let url = event.sourceURL {
                    Link(destination: url) { Label("Read source and revision", systemImage: "arrow.up.right.square") }
                        .frame(minHeight: 44)
                }
            }
            if let provenance = event.provenance {
                Section("Source passage") {
                    LabeledContent("Extraction", value: provenance.method == "datedProse" ? "Dated article prose" : provenance.method)
                    LabeledContent("Article", value: provenance.articleTitle)
                    if !provenance.section.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        LabeledContent("Section", value: provenance.section)
                    }
                    Text("“\(provenance.quote)”")
                        .font(.body)
                        .textSelection(.enabled)
                        .accessibilityLabel("Quoted source sentence: \(provenance.quote)")
                    LabeledContent("Date in text", value: provenance.dateText)
                    Text(dateAttribution(provenance))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if let uncertainty = provenance.uncertainty, !uncertainty.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Label(uncertainty, systemImage: "questionmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                    Text("Page \(provenance.pageID) · revision \(provenance.revisionID)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            Section {
                ForEach(model.neighbors) { neighbor in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(neighbor.event.title).font(.headline)
                        AtlasBadge(text: neighbor.semantic ? "Suggested similarity" : "Documented connection",
                                   color: neighbor.semantic ? AtlasTheme.violet : AtlasTheme.cyan)
                        Text(neighbor.label).font(.subheadline)
                        Text(neighbor.explanation).font(.subheadline).foregroundStyle(.secondary)
                        if neighbor.semantic {
                            Text("Cosine similarity: \(neighbor.score, specifier: "%.3f")")
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(AtlasTheme.violet)
                        }
                        if let url = AtlasEdge.evidenceURL(from: neighbor.evidence) {
                            Link("Inspect evidence", destination: url).frame(minHeight: 44)
                        }
                        Button("Walk to this event", systemImage: "figure.walk") {
                            model.select(neighbor.event.id); dismiss()
                        }.buttonStyle(.bordered).controlSize(.large)
                    }.padding(.vertical, 6)
                }
                if model.neighbors.isEmpty {
                    Text("No connections in this catalog. A larger corpus may reveal more.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Explore connections")
            } footer: {
                Text("Solid connections come from recorded links and statements. Dotted connections suggest similar meaning.")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden).background(AtlasTheme.ink)
        .navigationTitle("Event").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private func dateAttribution(_ provenance: AtlasEventProvenance) -> String {
        if provenance.dateBasis == "sectionYear" {
            return "The year was inferred from the article’s section heading."
        }
        if provenance.dateBasis == "articleYear" {
            return "The year comes from the calendar-year article title."
        }
        if provenance.dateBasis == "articleDay" {
            return "The day and month come from the article title; the year comes from the source passage."
        }
        if provenance.dateBasis == "explicit" && provenance.confidence == "explicitDate" {
            return "The date is written explicitly in the quoted passage."
        }
        return "Date basis: \(provenance.dateBasis). Extraction confidence: \(provenance.confidence)."
    }
}
